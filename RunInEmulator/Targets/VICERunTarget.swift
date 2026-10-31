import Foundation
import AppKit

// MARK: - VICERunTarget

/// Runs a PRG in VICE (x64sc, x128 or xpet) and provides full debugger access
/// via the VICE remote text monitor protocol.
///
/// Absorbs:
///   - `BuildManager.launchVICE()` and `launchVICEWithDiskSupport()`
///   - `BuildManager.stopVICE()` / `viceProcess` / `isVICERunning`
///   - `BuildManager.buildMonitorCommands()`
///   - `VICEMonitorClient` (TCP connection + read loop)
///   - `VICEResponseParser` (from VICEEmulatorTarget.swift)
///
/// After this file is in place, delete all of the above from their
/// original locations and remove `VICEEmulatorTarget.swift`.
@MainActor
final class VICERunTarget: NSObject, @MainActor DebuggableTarget {

    // MARK: - RunTargetProtocol Conformance

    let runTarget: RunTarget
    var onLog:      ((String, MessageType) -> Void)?
    var onDidStart: (() -> Void)?
    var onDidStop:  (() -> Void)?

    // MARK: - DebuggableTarget Conformance

    var onBreakpoint: ((UInt16) -> Void)?
    /// VICE's text monitor has no illegal-opcode/JAM event, so this is never
    /// invoked for VICE targets. Declared to satisfy DebuggableTarget.
    var onJam:        ((UInt16) -> Void)?
    var onPause:      ((RegisterState) -> Void)?
    var onConsoleOutput: ((String) -> Void)?

    // MARK: - Configuration

    /// Resolved from BuildConfiguration at launch time.
    private let binaryPath:     String
    private let buildConfig:    BuildConfiguration

    // MARK: - Process

    private var process:        Process?
    private var processTermObs: NSObjectProtocol?

    private(set) var isRunning: Bool = false

    // MARK: - Monitor Connection

    private nonisolated(unsafe) var monitorClient: VICEMonitorClient?
    private let monitorHost =   "127.0.0.1"
    private let monitorPort:    UInt32 = 6510
    private let connectTimeout: TimeInterval = 8.0

    // MARK: - State

    /// Written on `responseQueue` by `routeLine`, read on whichever thread
    /// calls `registers`. Guarded so the read can't tear a half-updated value.
    private nonisolated let registerLock = NSLock()
    private nonisolated(unsafe) var _cachedRegisters = RegisterState()
    private nonisolated var cachedRegisters: RegisterState {
        get { registerLock.lock(); defer { registerLock.unlock() }; return _cachedRegisters }
        set { registerLock.lock(); _cachedRegisters = newValue; registerLock.unlock() }
    }
    private var breakpointMap: [UInt16: Int] = [:]     // addr → VICE checkpoint number
    private var watchpointMap: [UInt16: Int] = [:]     // addr → VICE checkpoint number
    /// `break`/`watch` commands still waiting for their reply, so a second
    /// request for the same address doesn't set a duplicate.
    private var pendingCheckpoints: Set<String> = []
    private var pendingDebugOptions: DebugOptions?
    /// True when this run's `debug.mon` sets the breakpoints, before the
    /// program starts. The monitor connection then only learns their numbers.
    private var monitorFileSetsBreakpoints = false

    // MARK: - Monitor Command Queue
    //
    // VICE answers one command at a time, and its reply carries nothing that
    // names the command it answers. So commands go out one at a time, each
    // only once the previous reply has ended, and every reply line goes to the
    // command in flight. Where a reply ends depends on where VICE is:
    //
    //   in the monitor   reply, prompt
    //   running          the prompt VICE prints on entering the monitor (it
    //                    stops for every command), reply, prompt
    //
    // `x`, `g` and `reset` leave the monitor and print nothing, so they are
    // done once sent. A stop VICE makes by itself (a breakpoint, a step that
    // finishes late) ends with a prompt while nothing is in flight.
    // Everything here is touched on `responseQueue` only.

    private nonisolated let responseQueue = DispatchQueue(label: "vc64ide.vice.response", qos: .userInitiated)
    private nonisolated(unsafe) var commandQueue: [MonitorCommand] = []
    private nonisolated(unsafe) var inFlight: MonitorCommand?
    private nonisolated(unsafe) var machineState: MonitorState = .unknown
    private nonisolated(unsafe) var nextCommandID = 0
    /// A reply normally takes milliseconds. Past this the command is given up,
    /// so a reply that never comes (a `ret` whose routine doesn't return)
    /// can't hold up the commands behind it.
    private nonisolated let commandTimeout: TimeInterval = 1.5
    /// How long a blocking request waits, its time in the queue included.
    private let responseTimeout: TimeInterval = 3.0

    // MARK: - Init

    init(emulator: RunTarget, config: BuildConfiguration) {
        precondition(emulator == .viceX64sc || emulator == .viceX128
                     || emulator == .viceXpet || emulator == .viceXvic,
                     "VICERunTarget only handles .viceX64sc, .viceX128, .viceXpet or .viceXvic")
        self.runTarget   = emulator
        self.buildConfig = config
        switch emulator {
        case .viceX128: self.binaryPath = config.x128Path
        case .viceXpet: self.binaryPath = config.xpetPath
        case .viceXvic: self.binaryPath = config.xvicPath
        default:        self.binaryPath = config.vicePath
        }
        super.init()
    }

    // MARK: - RunTargetProtocol

    func run(options: RunOptions) throws {
        stop()  // terminate any previous instance

        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            throw RunTargetError.binaryNotFound(binaryPath)
        }

        pendingDebugOptions = options.debugOptions
        let args = buildArguments(options: options)

        log("Launching \(runTarget.displayName): \(options.prgURL.lastPathComponent)", .info)
        log("\(runTarget.displayName) args: \(args.joined(separator: " "))", .plain)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = args
        proc.currentDirectoryURL = options.prgURL.deletingLastPathComponent()

        // Silence stdout; surface stderr in the build log.
        proc.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        proc.standardError = stderrPipe
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return }
            DispatchQueue.main.async { self?.log("\(self?.runTarget.displayName ?? "VICE"): \(text)", .plain) }
        }

        processTermObs = NotificationCenter.default.addObserver(
            forName: Process.didTerminateNotification,
            object: proc,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleTermination() }
        }

        try proc.run()
        process  = proc
        isRunning = true

        log("\(runTarget.displayName) running (PID \(proc.processIdentifier))", .success)
        onDidStart?()

        // If we need the monitor, connect now.
        if options.debugOptions != nil {
            connectMonitor(afterDelay: 0.5)
        }
    }

    func stop() {
        monitorClient?.disconnect()
        monitorClient = nil

        if let obs = processTermObs {
            NotificationCenter.default.removeObserver(obs)
            processTermObs = nil
        }
        if let proc = process, proc.isRunning {
            proc.terminate()
            log("\(runTarget.displayName) terminated.", .info)
        }
        process  = nil
        isRunning = false
        breakpointMap.removeAll()
        watchpointMap.removeAll()
        pendingCheckpoints.removeAll()
        pendingDebugOptions = nil
        monitorFileSetsBreakpoints = false
    }

    // MARK: - EmulatorTarget

    /// `r`, not an empty line: VICE stops for any command, and an empty line
    /// typed while it is already in the monitor repeats the last command,
    /// which made Pause take a step after a step. The register reply also
    /// refreshes the debugger through `onPause`.
    func pause()  { requestRegisters() }
    func resume() { enqueue("x", reply: .none) }
    func reset()  { enqueue("reset", reply: .none) }

    // The requests below are the IDE's own: if VICE had to stop for one, it
    // is resumed afterwards (resumesRun), so reading memory or editing a
    // breakpoint doesn't pause a running program.

    func readMemory(from start: UInt16, to end: UInt16) -> Data {
        let cmd  = String(format: "m %04x %04x", start, end)
        let bytes: [UInt8] = synchronousRequest(cmd, resumesRun: true) { lines in
            VICEResponseParser.parseMemoryDump(lines: lines, start: start, end: end)
        } ?? []
        return Data(bytes)
    }

    func writeByte(_ value: UInt8, to address: UInt16) {
        enqueue(String(format: "> %04x %02x", address, value), resumesRun: true)
    }

    func disassemble(count: Int, from address: UInt16) -> [String] {
        let end  = address &+ UInt16(count * 3)
        let cmd  = String(format: "d %04x %04x", address, end)
        return synchronousRequest(cmd, resumesRun: true) { lines in
            Array(lines.filter { VICEResponseParser.isDisassemblyLine($0) }.prefix(count))
        } ?? []
    }

    // VICERunTarget manages its own window — no Metal texture.
    func updateTexture(device: MTLDevice) -> MTLTexture? { nil }

    // MARK: - DebuggableTarget

    var registers: RegisterState {
        synchronousRequest("r") { lines in
            lines.compactMap { RegisterState.parse($0) }.first
        } ?? cachedRegisters
    }

    func stepInto()  { enqueue("z"); requestRegisters() }
    func stepOver()  { enqueue("n"); requestRegisters() }
    func stepCycle() { enqueue("z"); requestRegisters() }   // VICE: no single-cycle step

    /// Runs to the return from the current subroutine. `ret`, not `n` — `n`
    /// is step-over, which made Step Out and Step Over the same button.
    func finishLine() { enqueue("ret"); requestRegisters() }

    /// Sets the program counter to `address` and resumes execution from
    /// there (VICE monitor `g`). The remote monitor accepts this whether
    /// the machine is paused in the monitor or running.
    func goto(address: UInt16) {
        enqueue(String(format: "g %04x", address), reply: .none)
    }

    func setBreakpoint(at address: UInt16) {
        guard breakpointMap[address] == nil else { return }
        setCheckpoint(String(format: "break %04x", address), at: address, prefix: "BREAK:") {
            $0.breakpointMap[address] = $1
        }
    }

    func deleteBreakpoint(at address: UInt16) {
        // The map only tracks breakpoints set via setBreakpoint(at:) and the
        // ones debug.mon set. A breakpoint typed into the console won't be in
        // it, so on a miss, re-list before giving up.
        if breakpointMap[address] == nil { refreshBreakpointMap() }
        guard let num = breakpointMap[address] else { return }
        enqueue("delete \(num)", resumesRun: true)
        breakpointMap.removeValue(forKey: address)
    }

    /// VICE's `delete` removes every checkpoint, watchpoints included.
    func deleteAllBreakpoints() {
        enqueue("delete", resumesRun: true)
        breakpointMap.removeAll()
        watchpointMap.removeAll()
    }

    func hasBreakpoint(at address: UInt16) -> Bool {
        breakpointMap[address] != nil
    }

    func setWatchpoint(at address: UInt16) {
        guard watchpointMap[address] == nil else { return }
        setCheckpoint(String(format: "watch %04x", address), at: address, prefix: "WATCH:") {
            $0.watchpointMap[address] = $1
        }
    }

    /// VICE deletes a watchpoint by its checkpoint number, like a breakpoint;
    /// the `watch delete <addr>` sent before is a syntax error.
    func deleteWatchpoint(at address: UInt16) {
        guard let num = watchpointMap[address] else { return }
        enqueue("delete \(num)", resumesRun: true)
        watchpointMap.removeValue(forKey: address)
    }

    func hasWatchpoint(at address: UInt16) -> Bool {
        watchpointMap[address] != nil
    }

    /// Sends `command` (`break`/`watch` at `address`) and records the
    /// checkpoint number VICE answers with ("BREAK: 3  C:$0810 ...").
    private func setCheckpoint(_ command: String, at address: UInt16, prefix: String,
                               record: @escaping (VICERunTarget, Int) -> Void) {
        guard !pendingCheckpoints.contains(command) else { return }
        pendingCheckpoints.insert(command)
        enqueue(command, resumesRun: true) { [weak self] reply in
            let num = VICEResponseParser.parseCheckpoints(lines: reply.lines, prefix: prefix)[address]
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pendingCheckpoints.remove(command)
                    if let num { record(self, num) }
                }
            }
        }
    }

    // MARK: - Private — Argument Building

    private func buildArguments(options: RunOptions) -> [String] {
        var args: [String] = []

        // ── Autostart / disk mount ─────────────────────────
        if let plan = options.diskPlan, plan.hasMounts {
            args += EmulatorMountAdapter.viceArguments(for: plan, autoRun: options.autoRun)
        } else {
            args += ["-autostart", options.prgURL.path,
                     "-autostartprgmode", "1"]
        }

        // ── Remote monitor ─────────────────────────────────
        if options.debugOptions != nil {
            args += ["-remotemonitor",
                     "-remotemonitoraddress", "\(monitorHost):\(monitorPort)"]
        }

        // ── Monitor commands file ──────────────────────────
        if let dbg = options.debugOptions {
            if let monFile = writeMonitorCommandsFile(options: options, debugOptions: dbg) {
                args += ["-moncommands", monFile.path]
                log("Loaded debug symbols: \(monFile.lastPathComponent)", .info)
            }
        }

        // ── ROM overrides ──────────────────────────────────
        // These are the C64 ROM images from Preferences; handing a C64 KERNAL
        // to a VIC-20 or PET produces a machine that won't boot, so they apply
        // to the C64 emulator only.
        if runTarget == .viceX64sc {
            if !buildConfig.viceKernalROM.isEmpty  { args += ["-kernal",  buildConfig.viceKernalROM] }
            if !buildConfig.viceBasicROM.isEmpty   { args += ["-basic",   buildConfig.viceBasicROM]  }
            if !buildConfig.viceChargenROM.isEmpty { args += ["-chargen", buildConfig.viceChargenROM] }

            // -model values are C64 model names (c64c, drean, jap…), which the
            // other emulator binaries reject.
            if !buildConfig.viceC64Model.isEmpty { args += ["-model", buildConfig.viceC64Model] }
        }

        // ── VIC-20 memory expansion & Super Expander ───────
        if runTarget == .viceXvic {
            args += vic20Arguments(prgURL: options.prgURL)
        }

        // ── Video standard ─────────────────────────────────
        args.append(buildConfig.viceVideoStandard == "ntsc" ? "-ntsc" : "-pal")

        // ── Extra user args ────────────────────────────────
        args += buildConfig.viceExtraArgs

        return args
    }

    /// VIC-20 launch arguments: RAM expansion matched to the program's load
    /// address, plus the Super Expander cartridge when one is configured.
    ///
    /// On the VIC-20 the BASIC start address *is* the memory configuration —
    /// $1001 unexpanded, $0401 with the 3K block (what the Super Expander
    /// provides), $1201 with 8K or more. The expansion is always passed
    /// explicitly, including `none`, because xvic otherwise inherits whatever
    /// was last saved in the user's `vicerc`, which would relocate BASIC out
    /// from under the program.
    private func vic20Arguments(prgURL: URL) -> [String] {
        var args: [String] = []

        let loadAddress = Self.prgLoadAddress(of: prgURL)
        switch loadAddress {
        case 0x0401: args += ["-memory", "3k"]
        case 0x1001: args += ["-memory", "none"]
        case 0x1201: args += ["-memory", "8k"]
        default:
            if let addr = loadAddress {
                log(String(format: "VIC-20: unrecognised load address $%04X — "
                         + "leaving memory expansion as configured in VICE.", addr), .warning)
            }
        }

        let seROM = buildConfig.xvicSuperExpanderROM
        if !seROM.isEmpty {
            if FileManager.default.fileExists(atPath: seROM) {
                args += ["-cartse", seROM]
            } else {
                log("Super Expander ROM not found at \(seROM) — launching without it.", .warning)
            }
        } else if loadAddress == 0x0401 {
            log("No Super Expander cartridge ROM set (Preferences → VIC-20). "
              + "The program will load, but Super Expander keywords will fail with ?SYNTAX ERROR.",
                .warning)
        }

        return args
    }

    /// Reads the 2-byte little-endian load address from a PRG header.
    private static func prgLoadAddress(of url: URL) -> UInt16? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 2), header.count == 2 else { return nil }
        return UInt16(header[0]) | (UInt16(header[1]) << 8)
    }

    /// Writes the `.mon` commands file containing entry breakpoint + symbol labels.
    /// Returns the file URL on success, nil if writing fails.
    private func writeMonitorCommandsFile(options: RunOptions, debugOptions: DebugOptions) -> URL? {
        var lines: [String] = []

        // Entry-point breakpoint.
        lines.append(String(format: "break %04x", debugOptions.entryPoint))

        // Additional editor breakpoints.
        for bp in debugOptions.breakpoints where bp != debugOptions.entryPoint {
            lines.append(String(format: "break %04x", bp))
        }

        // Symbol labels from debug info.
        // VICE monitor uses `al` (alias) to create persistent labels for addresses.
        if let dbg = debugOptions.debugInfo {
            for sym in dbg.symbols where !sym.name.hasPrefix("@") {
                lines.append(String(format: "al C:%04x .%@", sym.address, sym.name))
            }
        }

        let content = lines.joined(separator: "\n") + "\n"
        let monFile = options.prgURL
            .deletingLastPathComponent()
            .appendingPathComponent("debug.mon")

        do {
            try content.write(to: monFile, atomically: true, encoding: .utf8)
            monitorFileSetsBreakpoints = true
            return monFile
        } catch {
            log("Warning: could not write debug.mon: \(error.localizedDescription)", .warning)
            return nil
        }
    }

    // MARK: - Private — Process Lifecycle

    private func handleTermination() {
        let code = process?.terminationStatus ?? 0
        isRunning = false
        monitorClient?.disconnect()
        monitorClient = nil
        process = nil

        if code != 0 {
            log("\(runTarget.displayName) exited with error (code \(code))", .error)
        } else {
            log("\(runTarget.displayName) exited normally.", .info)
        }
        onDidStop?()
    }

    // MARK: - Private — Monitor Connection

    private func connectMonitor(afterDelay delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.attemptMonitorConnect(retries: 20)
        }
    }

    private func attemptMonitorConnect(retries: Int) {
        guard isRunning, monitorClient == nil else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let client = VICEMonitorClient(host: self.monitorHost, port: self.monitorPort)
            let ok = client.connect()

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if ok {
                    self.setupMonitorClient(client)
                    self.onMonitorConnected()
                } else if retries > 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        self?.attemptMonitorConnect(retries: retries - 1)
                    }
                } else {
                    self.log("Could not connect to \(self.runTarget.displayName) monitor after multiple attempts.", .error)
                }
            }
        }
    }

    private func setupMonitorClient(_ client: VICEMonitorClient) {
        client.onConnectionChanged = { [weak self] up in
            guard let self = self, !up else { return }
            self.responseQueue.async { self.dropCommands() }
        }
        client.onResponse = { [weak self] line in
            self?.responseQueue.async { self?.routeLine(line) }
        }
        client.onBreakpoint = { [weak self] line in
            self?.handleBreakpointLine(line)
        }
        monitorClient = client
    }

    private func onMonitorConnected() {
        log("Connected to \(runTarget.displayName) monitor.", .success)
        guard let dbg = pendingDebugOptions else { return }

        if monitorFileSetsBreakpoints {
            // debug.mon set the breakpoints before the program started;
            // setting them again here made VICE hold each one twice. List
            // them to learn their numbers instead. The listing resumes VICE
            // if it stopped for it. If VICE was already stopped, the program
            // reached a breakpoint before the IDE was listening.
            enqueue("break", resumesRun: true) { [weak self] reply in
                let map = VICEResponseParser.parseBreakpointList(lines: reply.lines)
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.breakpointMap = map
                        if !reply.interruptedRun { self.reportStopAtConnect() }
                    }
                }
            }
        } else {
            setBreakpoint(at: dbg.entryPoint)
            for bp in dbg.breakpoints where bp != dbg.entryPoint {
                setBreakpoint(at: bp)
            }
        }
        // No resume() here. VICE stops for every command, and the old
        // `break`-list refresh that followed setBreakpoint went out after
        // this resume, so the program sat stopped in the boot code for good.
        log(String(format: "Breakpoints set. Waiting for $%04X…", dbg.entryPoint), .info)
    }

    /// VICE was already stopped when the monitor connected. Ask where, and
    /// report it if that is a breakpoint: the IDE missed VICE's announcement.
    private func reportStopAtConnect() {
        enqueue("r") { [weak self] reply in
            guard let pc = reply.lines.compactMap({ RegisterState.parse($0) }).first?.pc else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.breakpointMap[pc] != nil else { return }
                    self.onBreakpoint?(pc)
                }
            }
        }
    }

    /// Non-blocking register request. The response router parses the reply
    /// into `cachedRegisters` and fires `onPause`, so callers on the main
    /// thread get a refresh without waiting on a round trip.
    func requestRegisters() {
        enqueue("r")
    }

    private func refreshBreakpointMap() {
        let map: [UInt16: Int]? = synchronousRequest("break", resumesRun: true) { lines in
            VICEResponseParser.parseBreakpointList(lines: lines)
        }
        if let map = map { breakpointMap = map }
    }

    // MARK: - Private — Send

    /// Send a raw command string to the VICE monitor. Used by the debugger
    /// console's free-entry command field. The reply goes to
    /// `onConsoleOutput`, prompts left out. Unlike the IDE's own requests, a
    /// typed command leaves VICE wherever it put it, as VICE's own monitor
    /// does: `m` stops a running program until `x`.
    func sendRawMonitorCommand(_ command: String) {
        let word = command.split(separator: " ").first?.lowercased() ?? ""
        let leavesMonitor = ["x", "exit", "g", "goto", "reset", "quit"].contains(word)
        enqueue(command, reply: leavesMonitor ? .none : .lines) { [weak self] reply in
            let lines = reply.lines.filter { !VICEResponseParser.isPromptLine($0) }
            guard !lines.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { lines.forEach { self?.onConsoleOutput?($0) } }
            }
        }
    }

    /// Queues a command and blocks the caller until its reply has arrived.
    /// Must be called on a thread that can safely wait, as it blocks until
    /// `responseTimeout` is reached.
    private func synchronousRequest<T>(
        _ command:  String,
        resumesRun: Bool = false,
        transform:  @escaping ([String]) -> T?
    ) -> T? {
        guard monitorClient != nil else { return nil }

        let semaphore = DispatchSemaphore(value: 0)
        var result: T?

        enqueue(command, resumesRun: resumesRun) { reply in
            result = transform(reply.lines)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + responseTimeout)
        return result
    }

    // MARK: - Private — Command Queue

    /// Queues a monitor command (see "Monitor Command Queue" above).
    /// `reply: .none` is for the commands that leave the monitor and print
    /// nothing. `resumesRun` lets VICE run on after the reply if it stopped
    /// for the command and not at a checkpoint meanwhile. `done` runs on
    /// `responseQueue`.
    private nonisolated func enqueue(_ text: String,
                                     reply: MonitorCommand.Reply = .lines,
                                     resumesRun: Bool = false,
                                     done: ((MonitorReply) -> Void)? = nil) {
        responseQueue.async { [weak self] in
            guard let self, self.monitorClient != nil else {
                done?(MonitorReply(lines: [], interruptedRun: false))
                return
            }
            self.nextCommandID += 1
            self.commandQueue.append(MonitorCommand(id: self.nextCommandID, text: text, reply: reply,
                                                    resumesRun: resumesRun, done: done))
            self.sendNextCommand()
        }
    }

    private nonisolated func sendNextCommand() {
        guard inFlight == nil, !commandQueue.isEmpty else { return }
        var command = commandQueue.removeFirst()
        command.startedIn = machineState
        monitorClient?.send(command.text)

        if command.reply == .none {
            machineState = .running
            command.done?(MonitorReply(lines: [], interruptedRun: false))
            sendNextCommand()
            return
        }

        inFlight = command
        let id = command.id
        responseQueue.asyncAfter(deadline: .now() + commandTimeout) { [weak self] in
            guard let self, let stuck = self.inFlight, stuck.id == id else { return }
            // Give up on it. Anything VICE still prints for it arrives with
            // nothing in flight, so it can't be taken for the next reply.
            self.inFlight = nil
            let lastWasPrompt = stuck.lines.last.map(VICEResponseParser.isPromptLine) ?? false
            self.machineState = lastWasPrompt ? .inMonitor : .unknown
            stuck.done?(MonitorReply(lines: stuck.lines, interruptedRun: false))
            self.sendNextCommand()
        }
    }

    private nonisolated func complete(_ command: MonitorCommand) {
        inFlight = nil
        machineState = .inMonitor
        let interrupted = command.interruptedRun
        command.done?(MonitorReply(lines: command.lines, interruptedRun: interrupted))

        if command.resumesRun, interrupted,
           !command.lines.contains(where: VICEResponseParser.isCheckpointHit) {
            // VICE only stopped to answer: let it run on, before anything
            // else queued meanwhile.
            nextCommandID += 1
            commandQueue.insert(MonitorCommand(id: nextCommandID, text: "x", reply: .none), at: 0)
        }
        sendNextCommand()
    }

    /// The connection is gone: finish every command with what it has.
    private nonisolated func dropCommands() {
        let dropped = (inFlight.map { [$0] } ?? []) + commandQueue
        inFlight = nil
        commandQueue = []
        machineState = .unknown
        dropped.forEach { $0.done?(MonitorReply(lines: $0.lines, interruptedRun: false)) }
    }

    // MARK: - Private — Response Routing

    /// Called on `responseQueue` for every line from the VICE monitor.
    private nonisolated func routeLine(_ line: String) {
        // Always opportunistically parse register state.
        if let state = RegisterState.parse(line) {
            cachedRegisters = state
            Task { @MainActor [weak self] in
                self?.onPause?(state)
            }
        }

        let isPrompt = VICEResponseParser.isPromptLine(line)
        guard var command = inFlight else {
            // VICE stopped by itself: a breakpoint or watchpoint, or a step
            // that finished after its command was given up.
            if isPrompt { machineState = .inMonitor }
            return
        }
        command.lines.append(line)
        inFlight = command
        guard isPrompt else { return }

        let ended: Bool
        switch command.startedIn {
        case .inMonitor:
            ended = true
        case .running:
            ended = command.lines.filter(VICEResponseParser.isPromptLine).count >= 2
        case .unknown:
            // The entry prompt, if any, comes before the reply.
            ended = command.lines.contains { !VICEResponseParser.isPromptLine($0) }
        }
        if ended { complete(command) }
    }

    /// Called on the monitor client's read thread, like `routeLine`, so it
    /// must not touch main-actor state — it parses and hops to main.
    private nonisolated func handleBreakpointLine(_ line: String) {
        guard let pc = VICEResponseParser.parseBreakpointPC(line) else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onBreakpoint?(pc) }
        }
    }

    // MARK: - Private — Logging

    private func log(_ message: String, _ type: MessageType) {
        DispatchQueue.main.async { [weak self] in
            self?.onLog?(message, type)
        }
    }
}

// MARK: - Monitor Commands

/// Where VICE is, as far as its replies so far tell.
private enum MonitorState { case unknown, inMonitor, running }

private struct MonitorReply {
    let lines: [String]
    /// VICE was running when the command arrived, and stopped to answer it.
    let interruptedRun: Bool
}

private struct MonitorCommand {
    enum Reply { case none, lines }

    let id:   Int
    let text: String
    var reply:      Reply = .lines
    var resumesRun: Bool  = false
    var done:       ((MonitorReply) -> Void)?

    /// Set when the command is sent.
    var startedIn: MonitorState = .unknown
    var lines: [String] = []

    var interruptedRun: Bool {
        switch startedIn {
        case .running:   return true
        case .inMonitor: return false
        case .unknown:   return lines.first.map(VICEResponseParser.isPromptLine) ?? false
        }
    }
}

// MARK: - VICEResponseParser

/// Stateless helpers for parsing VICE monitor text output.
/// Moved here from VICEEmulatorTarget.swift — delete that file's copy.
enum VICEResponseParser {

    static func isPromptLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        // VICE prompt format: (C:$xxxx) or (A:$xxxx)
        return t.hasPrefix("(") && t.hasSuffix(")") && t.contains(":$")
    }

    static func isDisassemblyLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        // VICE disassembly format: .xxxx: 00 00 00 ...
        return t.hasPrefix(".") && t.contains(":") && t.count > 10
    }

    static func parseMemoryDump(lines: [String], start: UInt16, end: UInt16) -> [UInt8] {
        guard end >= start else { return [] }
        let count  = Int(end) - Int(start) + 1
        var result = [UInt8](repeating: 0, count: count)

        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix(">"),
                  let colonRange = t.range(of: ":"),
                  let spaceIdx   = t[colonRange.upperBound...].firstIndex(of: " ")
            else { continue }

            let addrHex = String(t[colonRange.upperBound..<spaceIdx])
            guard let lineAddr = UInt16(addrHex, radix: 16) else { continue }

            let parts = String(t[spaceIdx...])
                .split(separator: " ", omittingEmptySubsequences: true)
            for (i, part) in parts.enumerated() {
                guard part.count == 2, let byte = UInt8(part, radix: 16) else { break }
                let offset = Int(lineAddr) + i - Int(start)
                if offset >= 0 && offset < count { result[offset] = byte }
            }
        }
        return result
    }

    /// True only for VICE's "the CPU stopped here" announcement, which looks
    /// like `#1 (Stop on  exec 0810)   0810` (watchpoints alike).
    ///
    /// Deliberately does *not* match `BREAK: 1  C:$0810  (Stop on exec)` —
    /// that's a row of `break`'s breakpoint *listing*. Treating those as hits
    /// made every breakpoint refresh fire a phantom breakpoint event for each
    /// breakpoint that existed.
    static func isCheckpointHit(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("#") && t.contains("(Stop")
    }

    static func parseBreakpointList(lines: [String]) -> [UInt16: Int] {
        parseCheckpoints(lines: lines, prefix: "BREAK:")
    }

    /// Address → checkpoint number from the rows VICE prints when it lists
    /// or sets checkpoints: `BREAK: 1  C:$0810  (Stop on exec)`, or with
    /// `prefix` "WATCH:" `WATCH: 3  C:$0400  (Stop on load store)`.
    static func parseCheckpoints(lines: [String], prefix: String) -> [UInt16: Int] {
        var map: [UInt16: Int] = [:]
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.uppercased().hasPrefix(prefix) else { continue }
            let after = t.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            let numStr = after.prefix(while: { $0.isNumber })
            guard let num = Int(numStr), let pc = parseBreakpointPC(t) else { continue }
            map[pc] = num
        }
        return map
    }

    /// Extracts the PC from either of VICE's two checkpoint renderings:
    ///
    ///   listing  `BREAK: 1  C:$0810  (Stop on exec)`
    ///            (printf `"BREAK: "` + `"%d  %s:$%04x"` + `"  (Stop on"`)
    ///   hit      `#1 (Stop on  exec 0810)  17/$011, 25/$19`
    ///            (printf `"#%d (%s %5s %04x) "` + `" %3u/$%03x, %3u/$%02x"`)
    ///
    /// The hit form has no `C:$`, and its address is glued to the closing
    /// paren — so the old "find a bare 4-character hex token" scan never
    /// matched it, and breakpoint hits went unreported. Read the last field
    /// inside the parentheses instead.
    static func parseBreakpointPC(_ line: String) -> UInt16? {
        if let r = line.range(of: "C:$") {
            let s = line[r.upperBound...]
            let e = s.firstIndex(where: { !$0.isHexDigit }) ?? s.endIndex
            if let pc = UInt16(String(s[..<e]), radix: 16) { return pc }
        }
        if let open = line.firstIndex(of: "("),
           let close = line[open...].firstIndex(of: ")") {
            let inside = line[line.index(after: open)..<close]
            if let field = inside.split(separator: " ").last,
               field.count == 4,
               let pc = UInt16(field, radix: 16) {
                return pc
            }
        }
        return nil
    }
}

// MARK: - RunTargetError

enum RunTargetError: LocalizedError {
    case binaryNotFound(String)
    case networkUnreachable(String)
    case monitorTimeout

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let path):    return "Emulator not found at: \(path)"
        case .networkUnreachable(let msg): return "Network error: \(msg)"
        case .monitorTimeout:              return "Monitor did not respond in time"
        }
    }
}

