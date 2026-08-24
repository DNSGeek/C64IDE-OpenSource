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
    private var breakpointMap: [UInt16: Int] = [:]     // addr → VICE BP number
    private var pendingDebugOptions: DebugOptions?

    // MARK: - Response Routing

    private nonisolated let responseQueue = DispatchQueue(label: "vc64ide.vice.response", qos: .userInitiated)
    private nonisolated(unsafe) var pendingRequest: VICEPendingRequest?
    private let responseTimeout: TimeInterval = 2.0

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
        pendingDebugOptions = nil
    }

    // MARK: - EmulatorTarget

    func pause()  { sendRaw("") }        // empty → VICE enters monitor
    func resume() { sendRaw("x") }       // x = exit monitor / continue
    func reset()  { sendRaw("reset") }

    func readMemory(from start: UInt16, to end: UInt16) -> Data {
        let cmd  = String(format: "m %04x %04x", start, end)
        let bytes: [UInt8] = synchronousRequest(kind: .memory, command: cmd) { lines in
            VICEResponseParser.parseMemoryDump(lines: lines, start: start, end: end)
        } ?? []
        return Data(bytes)
    }

    func writeByte(_ value: UInt8, to address: UInt16) {
        sendRaw(String(format: "> %04x %02x", address, value))
    }

    func disassemble(count: Int, from address: UInt16) -> [String] {
        let end  = address &+ UInt16(count * 3)
        let cmd  = String(format: "d %04x %04x", address, end)
        return synchronousRequest(kind: .disassemble, command: cmd) { lines in
            Array(lines.filter { VICEResponseParser.isDisassemblyLine($0) }.prefix(count))
        } ?? []
    }

    // VICERunTarget manages its own window — no Metal texture.
    func updateTexture(device: MTLDevice) -> MTLTexture? { nil }

    // MARK: - DebuggableTarget

    var registers: RegisterState {
        synchronousRequest(kind: .registers, command: "r") { lines in
            lines.compactMap { RegisterState.parse($0) }.first
        } ?? cachedRegisters
    }

    func stepInto()  { sendRaw("z"); requestRegisters() }
    func stepOver()  { sendRaw("n"); requestRegisters() }
    func stepCycle() { sendRaw("z"); requestRegisters() }   // VICE: no single-cycle step

    /// Runs to the return from the current subroutine. `ret`, not `n` — `n`
    /// is step-over, which made Step Out and Step Over the same button.
    func finishLine() { sendRaw("ret"); requestRegisters() }

    /// Sets the program counter to `address` and resumes execution from
    /// there (VICE monitor `g`). The remote monitor accepts this whether
    /// the machine is paused in the monitor or running.
    func goto(address: UInt16) {
        sendRaw(String(format: "g %04x", address))
    }

    func setBreakpoint(at address: UInt16) {
        guard breakpointMap[address] == nil else { return }
        sendRaw(String(format: "break %04x", address))
        // Refresh map after VICE has processed the command.
        // VICE processes monitor commands sequentially; 0.1s provides margin.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.refreshBreakpointMap()
        }
    }

    func deleteBreakpoint(at address: UInt16) {
        // The map only tracks breakpoints set via setBreakpoint(at:).
        // Breakpoints created by the debug.mon file or a console command
        // won't be in it, so on a miss, re-list before giving up.
        if breakpointMap[address] == nil { refreshBreakpointMap() }
        guard let num = breakpointMap[address] else { return }
        sendRaw("delete \(num)")
        breakpointMap.removeValue(forKey: address)
    }

    func deleteAllBreakpoints() {
        sendRaw("delete")
        breakpointMap.removeAll()
    }

    func hasBreakpoint(at address: UInt16) -> Bool {
        breakpointMap[address] != nil
    }

    func setWatchpoint(at address: UInt16) {
        sendRaw(String(format: "watch %04x", address))
    }

    func deleteWatchpoint(at address: UInt16) {
        // Find the watchpoint's guard number and delete by number.
        // VICE watch list: "WATCH: N  C:$XXXX  ..."
        // We don't cache these separately — just re-list and delete by number.
        sendRaw(String(format: "watch delete %04x", address))
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

            DispatchQueue.main.async {
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
            self.responseQueue.async { self.pendingRequest = nil }
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

        // Set entry breakpoint then continue — program will stop there.
        setBreakpoint(at: dbg.entryPoint)
        for bp in dbg.breakpoints where bp != dbg.entryPoint {
            setBreakpoint(at: bp)
        }
        resume()
        log(String(format: "Breakpoints set. Waiting for $%04X…", dbg.entryPoint), .info)
    }

    /// Fire-and-forget register request. The response router parses the
    /// reply into `cachedRegisters` and fires `onPause`, so callers on the
    /// main thread get a refresh without blocking on a round trip.
    func requestRegisters() {
        monitorClient?.send("r")
    }

    private func refreshBreakpointMap() {
        let map: [UInt16: Int]? = synchronousRequest(kind: .breakpointList, command: "break") { lines in
            VICEResponseParser.parseBreakpointList(lines: lines)
        }
        if let map = map { breakpointMap = map }
    }

    // MARK: - Private — Send

    /// Send a raw command string to the VICE monitor. Used by the debugger
    /// console's free-entry command field.
    func sendRawMonitorCommand(_ command: String) {
        sendRaw(command)
    }

    private func sendRaw(_ command: String) {
        monitorClient?.send(command)
    }

    // MARK: - Private — Synchronous Request

    /// Sends a command to the VICE monitor and blocks the caller until a
    /// matching response arrives. Must be called on a thread that can safely
    /// wait, as it synchronously blocks until `responseTimeout` is reached.
    private func synchronousRequest<T>(
        kind:    VICEPendingRequest.Kind,
        command: String,
        transform: @escaping ([String]) -> T?
    ) -> T? {
        guard monitorClient != nil else { return nil }

        let semaphore = DispatchSemaphore(value: 0)
        var result: T?

        responseQueue.async { [weak self] in
            guard let self = self else { semaphore.signal(); return }
            // A request already in flight would be orphaned by the assignment
            // below and leave its caller waiting out the full timeout. Close
            // it out with whatever it collected so that caller returns now.
            if let stale = self.pendingRequest { stale.cont(stale.lines) }
            self.pendingRequest = VICEPendingRequest(kind: kind) { lines in
                result = transform(lines)
                semaphore.signal()
            }
            self.monitorClient?.send(command)
        }

        if semaphore.wait(timeout: .now() + responseTimeout) == .timedOut {
            responseQueue.async { [weak self] in self?.pendingRequest = nil }
        }
        return result
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

        guard var req = pendingRequest else { return }
        req.lines.append(line)

        if isTerminalLine(line, for: req.kind) {
            pendingRequest = nil
            req.cont(req.lines)
        } else {
            pendingRequest = req
        }
    }

    private nonisolated func isTerminalLine(_ line: String, for kind: VICEPendingRequest.Kind) -> Bool {
        switch kind {
        case .registers:     return line.hasPrefix(".;")
        case .memory,
             .disassemble,
             .breakpointList,
             .generic:       return VICEResponseParser.isPromptLine(line)
        }
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

// MARK: - VICEPendingRequest

private struct VICEPendingRequest {

    enum Kind {
        case registers
        case memory
        case disassemble
        case breakpointList
        case generic
    }

    let kind:  Kind
    let cont:  ([String]) -> Void
    var lines: [String] = []
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

    static func parseBreakpointList(lines: [String]) -> [UInt16: Int] {
        var map: [UInt16: Int] = [:]
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.uppercased().hasPrefix("BREAK:") else { continue }
            let after = t.dropFirst("BREAK:".count).trimmingCharacters(in: .whitespaces)
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

