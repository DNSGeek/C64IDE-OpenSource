import Foundation
import AppKit
import Metal
import MetalKit
import QuartzCore

// MARK: - String Helper

private extension String {
    /// Returns `self` if non-empty, else `nil`. Useful for translating empty
    /// "unset" strings from the config into explicit `nil` for the bridge.
    var nonEmptyOrNil: String? { isEmpty ? nil : self }
}

// MARK: - VC64RunTarget

/// Runs a PRG inside the embedded VirtualC64 library and provides full
/// debugger access via the `VC64Bridge` C++ API.
///
/// Also owns the emulator window (`NSWindow` + `MTKView` render loop).
/// The window is created lazily on the first `run()` call and reused across
/// runs. It is hidden when `stop()` is called and shown again on the
/// next `run()`.
final class VC64RunTarget: NSObject, @MainActor DebuggableTarget {

    // MARK: - RunTargetProtocol Conformance

    let runTarget: RunTarget = .vc64
    var onLog:      ((String, MessageType) -> Void)?
    var onDidStart: (() -> Void)?
    var onDidStop:  (() -> Void)?

    // MARK: - DebuggableTarget Conformance

    var onBreakpoint: ((UInt16) -> Void)?
    var onJam:        ((UInt16) -> Void)?
    var onPause:      ((RegisterState) -> Void)?

    // MARK: - State

    private(set) var isRunning: Bool = false

    // MARK: - Core Objects

    /// Internal so `VC64EmulatorWindowController` and `VC64Renderer` can call `wakeUp()`.
    let bridge = VC64Bridge()
    private var windowController: VC64EmulatorWindowController?
    private let config: BuildConfiguration?

    /// Audio output engine. Drives an `AVAudioSourceNode` that pulls SID
    /// samples from the bridge on a real-time render thread. Started in
    /// `run()` after the bridge launches, stopped in `stop()`.
    private lazy var audioEngine = VC64AudioEngine(bridge: bridge)

    /// Video standard for this run, derived from the build configuration.
    /// Used by the renderer to pick the correct visible-area UV crop.
    var videoStandard: VC64VideoStandard {
        VC64VideoStandard.from(config)
    }

    /// True until the bridge has been launched for the first time. Used to
    /// decide how long to wait before sending keystrokes — a cold boot
    /// (~1.5s) versus subsequent runs against an already-running emulator.
    private var isFirstLaunch: Bool = true

    // MARK: - Init

    /// - Parameter config: Build configuration. Used to locate the user's
    ///   KERNAL / BASIC / Character ROM files. Pass `nil` only for tests that
    ///   tolerate the bridge falling back to the embedded MEGA65 OpenROMs.
    init(config: BuildConfiguration? = nil) {
        self.config = config
        super.init()
        bridge.delegate = self
    }

    deinit {
        // VC64Bridge.h: "Halt the emulator thread. Call before releasing
        // this object." Without this, releasing the bridge leaves the VCCore
        // thread alive (or worse, tears the object down under it). stop()
        // only pauses the core; the thread itself dies here.
        bridge.halt()
    }

    // MARK: - RunTargetProtocol

    @MainActor func run(options: RunOptions) throws {
        // Launch the bridge if this is the first run.
        if !bridge.isReady {
            // Read ROM paths from the build configuration. Empty string means
            // the user hasn't configured that ROM; pass `nil` to the bridge so
            // it falls back to the embedded MEGA65 OpenROMs for that slot.
            //
            // The same fields are used by VICE — they describe the user's
            // physical ROM dumps, which are emulator-agnostic.
            let kernalPath = config?.viceKernalROM.nonEmptyOrNil
            let basicPath  = config?.viceBasicROM.nonEmptyOrNil
            let charPath   = config?.viceChargenROM.nonEmptyOrNil

            if kernalPath == nil && basicPath == nil && charPath == nil {
                log("⚠ No C64 ROMs configured. Using built-in OpenROMs (less accurate). "
                  + "Set ROM paths in Preferences → C64 ROMs for the real Commodore ROMs.",
                    .warning)
            } else if kernalPath == nil || basicPath == nil || charPath == nil {
                log("⚠ Partial ROM configuration. KERNAL/BASIC/Character ROMs should all be "
                  + "set together. Configure missing ROMs in Preferences → C64 ROMs.",
                    .warning)
            }

            try bridge.launch(
                withKernalROM: kernalPath,
                basicROM: basicPath,
                charROM:  charPath
            )

            // Configure the machine's video standard BEFORE first power-on
            // so it boots directly in the standard the config asked for.
            bridge.setVideoStandard(videoStandard.bridgeStandard)

            bridge.powerOn()
            bridge.run()
        } else {
            // Warm run: re-sync in case the user flipped PAL/NTSC in
            // preferences since the last run. VCCore applies the VICII
            // revision change on the fly.
            bridge.setVideoStandard(videoStandard.bridgeStandard)
        }

        // Start audio output. Safe to call on every run() — the engine is
        // idempotent and will reuse its existing AVAudioEngine if already
        // configured. Audio production in VCCore is gated on the emulator
        // being in RUN state, so we have to do this after bridge.run().
        audioEngine.start()

        // Show or create the emulator window. Sync the renderer's crop to
        // the machine's ACTUAL standard (queried from the bridge, not the
        // config) so the crop can never disagree with the emulated output.
        let wc = emulatorWindowController()
        wc.syncVideoStandard(VC64VideoStandard(bridge: bridge.videoStandard()))
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        // Restart the vsync render loop (a no-op on the very first run, where
        // the display link is already running; required after stop() paused it).
        wc.resumeRendering()

        // Set up debug options before loading the PRG.
        if let dbg = options.debugOptions {
            bridge.deleteAllBreakpoints()
            bridge.setBreakpointAt(dbg.entryPoint)
            for bp in dbg.breakpoints where bp != dbg.entryPoint {
                bridge.setBreakpointAt(bp)
            }
        }

        // Load the PRG.
        if let plan = options.diskPlan, plan.hasMounts, let _ = plan.primaryDisk {
            // Disk mode: mount images then let the C64 LOAD from the primary disk.
            for disk in plan.disks {
                let driveNum = disk.driveNumber  // already 8 or 9
                try? bridge.insertDisk(disk.imageURL.path,
                                  driveNumber: driveNum,
                                  writeProtect: false)
            }
            // Type LOAD"<name>",8,1 + RETURN into the keyboard buffer.
            // Defer the keystrokes until BASIC is ready (see inject-mode
            // comment below). On a warm emulator this is near-instant.
            //
            // CHARACTER ENCODING WARNING:
            // VCCore's C64Key::translate(char) treats UPPERCASE ASCII as
            // shifted keys, which on the C64 (in default uppercase mode)
            // produces graphics characters, NOT letters. To type the
            // letters L-O-A-D-R-U-N, we send LOWERCASE ASCII — which maps
            // to the unshifted keys that produce uppercase letters on
            // screen (the C64 boots in uppercase/graphics mode).
            // Also: '\n' (not '\r') maps to RETURN.
            let loadName = plan.bootProgramName?.lowercased() ?? "*"
            let loadCmd  = "load\"\(loadName)\",8,1\n"
            let bootDelay: TimeInterval = isFirstLaunch ? 2.0 : 0.1
            DispatchQueue.main.asyncAfter(deadline: .now() + bootDelay) { [weak self] in
                guard let self else { return }
                self.bridge.autoType(loadCmd)
                if options.autoRun {
                    // The 1541 takes its time. We don't know exactly when
                    // LOAD finishes — VC1541 emulation is real-time. Queue
                    // RUN well after the LOAD completes; autoType will
                    // buffer it if BASIC isn't yet at READY.
                    //
                    // A more robust path is to set a breakpoint at $A483
                    // and fire RUN from onBreakpoint, but autoType's buffer
                    // tolerates being early.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                        self?.bridge.autoType("run\n")
                    }
                }
            }
        } else {
            // Inject mode: flash PRG directly into RAM after boot completes.
            //
            // ⚠ TIMING: VCCore's flash() writes bytes to $0801 and updates
            // $2D/$2E (VARTAB / end-of-program pointer). But if we flash
            // BEFORE the kernal has finished booting, the boot routine
            // clears RAM and resets $2B–$2E to an empty program, wiping
            // our work. So we have to defer flash() until BASIC is at the
            // READY prompt.
            //
            // ENCODING: VCCore maps uppercase ASCII to Shift+key, which
            // on the C64 produces graphics characters, not letters. Send
            // LOWERCASE to get letters. Send '\n' (not '\r') for RETURN.
            //
            // LEADING NEWLINE: prefixing the command with "\n" types an
            // empty BASIC line (silently ignored at READY) which ensures
            // the keyboard scanner has serviced at least one full press/
            // release cycle before our real command. This prevents the
            // first character of the command from being dropped, which
            // happens occasionally during cold boot.
            let prgPath = options.prgURL.path
            let autoRun = options.autoRun
            let delay: TimeInterval = isFirstLaunch ? 2.5 : 0.1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                do {
                    try self.bridge.flashPRG(prgPath)
                    if autoRun {
                        // Give flash a beat to settle, then type RUN. The
                        // 0.2s delay isn't strictly necessary on a quiet
                        // C64 but provides margin against any in-flight
                        // BASIC state.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                            self?.bridge.autoType("\nrun\n")
                        }
                    }
                } catch {
                    self.log("✗ Flash failed: \(error.localizedDescription)", .error)
                }
            }
        }

        isRunning = true
        // Cold-boot delay only applies on the very first launch. After that,
        // the emulator stays up between runs (we just flash a new PRG into
        // a live machine) so keystrokes can fire almost immediately.
        isFirstLaunch = false
        log("VirtualC64 running: \(options.prgURL.lastPathComponent)", .success)
        onDidStart?()
    }

    @MainActor func stop() {
        bridge.pause()
        // Pause audio output too. Keep the engine configured for fast restart
        // on the next run() - full shutdown only happens at deinit.
        audioEngine.stop()
        // Stop the vsync render loop while the window is hidden. Without this
        // the CVDisplayLink keeps firing at ~60Hz against an invisible window,
        // waking the bridge and encoding a full Metal frame every vsync.
        windowController?.pauseRendering()
        windowController?.window?.orderOut(nil)
        isRunning = false
        onDidStop?()
        log("VirtualC64 stopped.", .info)
    }

    // MARK: - EmulatorTarget

    func pause()   { bridge.pause();      audioEngine.stop() }
    func resume()  { bridge.run();        audioEngine.start() }
    func reset()   { bridge.hardReset() }
    func wakeUp()  { bridge.wakeUp() }

    func readMemory(from start: UInt16, to end: UInt16) -> Data {
        bridge.readMemory(from: start, to: end) as Data
    }

    func writeByte(_ value: UInt8, to address: UInt16) {
        // VC64Bridge routes writes through RetroShell.
        bridge.retroShellExec(String(format: "m %04X %02X", address, value))
    }

    func disassemble(count: Int, from address: UInt16) -> [String] {
        bridge.disassemble(count, instructionsFrom: address)
    }

    func updateTexture(device: MTLDevice) -> MTLTexture? {
        bridge.updateMetalTexture(on: device)
    }

    // MARK: - DebuggableTarget

    var registers: RegisterState {
        let r = bridge.registers()
        return RegisterState(pc: r.pc, a: r.a, x: r.x, y: r.y, sp: r.sp, flags: r.flags)
    }

    /// The bridge answers register reads synchronously and cheaply, so this
    /// just republishes the current state through the usual `onPause` path.
    func requestRegisters() { notifyPause() }

    func stepInto()   { bridge.stepInto();   notifyPause() }
    func stepOver()   { bridge.stepOver();   notifyPause() }
    func stepCycle()  { bridge.stepCycle();  notifyPause() }
    /// Step out. `notifyPause()` so the debugger's register view and source
    /// highlight follow, the way stepInto/stepOver already do.
    func finishLine() { bridge.finishLine(); notifyPause() }

    /// Sets PC to `address` and resumes. Not implemented yet: VC64Bridge
    /// doesn't expose a PC setter, and the RetroShell syntax for register
    /// writes needs verifying against the embedded VCCore version.
    /// TODO: add a jump/setPC method to VC64Bridge and route this through it.
    func goto(address: UInt16) {
        log(String(format: "Go-to $%04X isn't implemented for VirtualC64 yet.", address), .warning)
    }

    func setBreakpoint(at address: UInt16)    { bridge.setBreakpointAt(address) }
    func deleteBreakpoint(at address: UInt16) { bridge.deleteBreakpoint(at: address) }
    func deleteAllBreakpoints()               { bridge.retroShellExec("break delete") }

    /// Send a RetroShell command. Used by the debugger console's free-entry field.
    func retroShellExec(_ command: String)    { bridge.retroShellExec(command) }
    func hasBreakpoint(at address: UInt16) -> Bool { bridge.hasBreakpoint(at: address) }

    func setWatchpoint(at address: UInt16)    { bridge.setWatchpointAt(address) }
    func deleteWatchpoint(at address: UInt16) { bridge.deleteWatchpoint(at: address) }
    func hasWatchpoint(at address: UInt16) -> Bool { bridge.hasWatchpoint(at: address) }

    // MARK: - Private — Window Management

    private func emulatorWindowController() -> VC64EmulatorWindowController {
        if let wc = windowController { return wc }
        let wc = VC64EmulatorWindowController(target: self)
        windowController = wc
        return wc
    }

    private func notifyPause() {
        let regs = registers
        DispatchQueue.main.async { [weak self] in self?.onPause?(regs) }
    }

    private func log(_ message: String, _ type: MessageType) {
        DispatchQueue.main.async { [weak self] in self?.onLog?(message, type) }
    }
}

// MARK: - VC64BridgeDelegate

extension VC64RunTarget: VC64BridgeDelegate {

    // VC64Bridge.h documents that all delegate callbacks are delivered on the
    // main thread, but the ObjC protocol carries no isolation annotation. We
    // mark the witnesses `nonisolated` (so assigning `self` to the bridge's
    // nonisolated `delegate` property is legal under Swift 6) and assert main
    // isolation inside, which is sound given the bridge contract.

    nonisolated func vc64(_ bridge: VC64Bridge, didHitBreakpointAtPC pc: UInt16) {
        MainActor.assumeIsolated {
            onBreakpoint?(pc)
            notifyPause()
        }
    }

    nonisolated func vc64(_ bridge: VC64Bridge, didHitWatchpointAtPC pc: UInt16) {
        MainActor.assumeIsolated {
            onBreakpoint?(pc)
            notifyPause()
        }
    }

    nonisolated func vc64(_ bridge: VC64Bridge, didJamAtPC pc: UInt16) {
        // The CPU has halted on an illegal opcode. Mark us paused (so the
        // debugger's register view is valid) and surface the jam to whoever
        // wired onJam — the machine is dead until reset.
        MainActor.assumeIsolated {
            isRunning = false
            onJam?(pc)
            notifyPause()
        }
    }

    nonisolated func vc64BridgeRetroShellDidUpdate(_ bridge: VC64Bridge) { }

    nonisolated func vc64(_ bridge: VC64Bridge, didReceive message: VC64Message) {
        MainActor.assumeIsolated {
            switch message {
            case .run:          isRunning = true
            case .pause:        isRunning = false
            case .powerOff:     isRunning = false
            default:            break
            }
        }
    }
}

// MARK: - VC64EmulatorWindowController

/// The emulator window: a plain `NSWindow` containing an `MTKView`.
/// The render loop is a `CVDisplayLink` that calls `wakeUp()` on the
/// bridge every vsync and uploads the current frame to a Metal texture.
final class VC64EmulatorWindowController: NSWindowController, NSWindowDelegate {

    /// Weak: the run target owns this window controller. A strong reference
    /// here closed a retain cycle (target -> windowController -> target) that
    /// kept every launched target, its bridge, and its display link alive
    /// forever - one leaked 60Hz render loop per launch.
    private weak var target: VC64RunTarget?
    private var mtkView: MTKView!
    private var renderer: VC64Renderer!
    private var displayLink: CVDisplayLink?

    /// Native C64 PAL output is 403 × 284 visible pixels.
    /// Double it for a crisp non-retina window; the MTKView handles scaling.
    private let windowWidth:  CGFloat = 806
    private let windowHeight: CGFloat = 568

    init(target: VC64RunTarget) {
        self.target = target

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 806, height: 568),
            styleMask:   [.titled, .closable, .miniaturizable, .resizable],
            backing:     .buffered,
            defer:       false
        )
        window.title            = "VirtualC64"
        window.minSize          = NSSize(width: 403, height: 284)
        window.backgroundColor  = .black
        window.center()

        super.init(window: window)
        window.delegate = self

        setupMTKView()
        startDisplayLink()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    deinit { stopDisplayLink() }

    // MARK: - NSWindowDelegate

    /// User clicked the red close button (or hit Cmd-W). Tell the run
    /// target to stop so the EmulatorCoordinator's `active` reference
    /// clears and the IDE knows the emulator is no longer alive.
    func windowWillClose(_ notification: Notification) {
        target?.stop()
    }

    // MARK: - Setup
    
    /// Point the renderer at the crop for `standard` and resize the window
    /// content to match its aspect. Called by the run target on every run,
    /// so a PAL/NTSC preference change between runs takes effect without
    /// tearing down the cached window controller.
    func syncVideoStandard(_ standard: VC64VideoStandard) {
        renderer.visibleRect = standard.visibleAreaUV

        // Resize so the content aspect matches the crop (PAL 384x284 vs
        // NTSC 411x235 source pixels, doubled). Skip if unchanged so we
        // don't stomp a user resize on every run.
        let uv = standard.visibleAreaUV
        let size = NSSize(
            width:  (CGFloat(uv.z - uv.x) * 520 * 2).rounded(),
            height: (CGFloat(uv.w - uv.y) * 312 * 2).rounded()
        )
        if lastStandardSize != size {
            lastStandardSize = size
            window?.setContentSize(size)
            window?.center()
        }
    }

    private var lastStandardSize: NSSize?

    private func setupMTKView() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not available on this device")
        }

        guard let contentView = window?.contentView else {
            fatalError("Window has no content view")
        }

        // Make the content view layer-backed and opaque. Without this, the
        // window server may composite the surrounding area as transparent,
        // which macOS renders as the checkerboard pattern in screenshots.
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.black.cgColor
        contentView.layer?.isOpaque = true
        window?.isOpaque = true

        // Use the key-handling subclass so the emulator can receive keyboard
        // input. A plain MTKView doesn't accept first responder, so keystrokes
        // bounce off the responder chain and macOS plays the system beep.
        let view = VC64MTKView(frame: contentView.bounds, device: device)
        view.bridge = target?.bridge
        mtkView = view

        // VCCore writes u32 pixels in RGBA byte order. Using `.bgra8Unorm` here
        // would swap R and B channels — the boot screen would be pink-on-red
        // instead of light-blue-on-blue. Keep this in sync with the texture
        // format created in VC64Bridge::updateMetalTextureOnDevice:.
        mtkView.colorPixelFormat        = .rgba8Unorm
        mtkView.clearColor              = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        mtkView.isPaused                = true   // we drive manually from the display link
        mtkView.enableSetNeedsDisplay   = false
        mtkView.autoResizeDrawable      = true

        // Force the MTKView and its CAMetalLayer to be fully opaque so the
        // drawable doesn't alpha-composite against the window background.
        mtkView.layer?.isOpaque = true
        if let metalLayer = mtkView.layer as? CAMetalLayer {
            metalLayer.isOpaque = true
            metalLayer.framebufferOnly = true
        }

        // PAL fallback only matters if the target vanished mid-setup, which
        // can't happen in practice (setup runs from the target's own init
        // path). syncVideoStandard() corrects the crop on every run anyway.
        let videoStandard = target?.videoStandard ?? .pal
        renderer = VC64Renderer(device: device, view: mtkView,
                                 videoStandard: videoStandard)
        renderer.vc64Target = target
        mtkView.delegate = renderer

        // Pin the MTKView to all four edges of the content view via Auto
        // Layout. Either autoresizingMask or constraints would work here —
        // constraints are just easier to reason about when the content view
        // is layer-backed.
        mtkView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(mtkView)
        NSLayoutConstraint.activate([
            mtkView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            mtkView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            mtkView.topAnchor.constraint(equalTo: contentView.topAnchor),
            mtkView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        // Make the MTKView first responder so it receives keyDown:/keyUp:.
        // Without this, even though the view accepts first responder, no one
        // tells the window to make it the first responder — so keys still
        // beep until the user clicks the view.
        window?.makeFirstResponder(mtkView)
    }

    private func startDisplayLink() {
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let link = displayLink else { return }

        // The display link callback fires on a high-priority background thread.
        // All we do is tell the bridge a vsync happened and ask the view to draw.
        CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
            guard let self = self else { return kCVReturnSuccess }
            self.target?.wakeUp()
            DispatchQueue.main.async { self.mtkView.draw() }
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(link)
    }

    /// Suspend vsync callbacks while the emulator window is hidden between
    /// runs. Called by `VC64RunTarget.stop()`. Keeping the link alive but
    /// stopped makes resume cheap on the next run.
    func pauseRendering() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
        }
    }

    /// Restart vsync callbacks when the window is shown again.
    /// Safe to call when the link is already running.
    func resumeRendering() {
        if let link = displayLink, !CVDisplayLinkIsRunning(link) {
            CVDisplayLinkStart(link)
        }
    }

    private func stopDisplayLink() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
        }
        displayLink = nil
    }
}

// MARK: - VC64VideoStandard

/// Video standard for the emulated machine. VCCore renders into a 520x312
/// texture regardless of standard, but the visible C64 picture occupies a
/// different sub-rect for each.
///
/// The off-screen padding inside the texture (vblank/hblank) is filled with
/// a checkerboard pattern by VCCore — a debug aid that becomes a visible
/// nuisance unless we crop it out. VCCore's own `findInnerAreaNormalized`
/// can't tell the checkerboard from real content (it's all drawn pixels,
/// not transparent), so it returns (0,0,1,1) — useless. We use hardcoded
/// crop values per standard instead.
///
/// NOTE: These UV coordinates are empirically tuned against VCCore's output.
/// If the underlying renderer changes its internal texture layout, these
/// values will need to be re-tuned.
enum VC64VideoStandard {
    case pal
    case ntsc

    /// (uMin, vMin, uMax, vMax) — UV sub-rect of the 520x312 texture
    /// containing the visible C64 picture (border + screen).
    var visibleAreaUV: SIMD4<Float> {
        switch self {
        case .pal:
            // Empirically tuned against VCCore's PAL output to eliminate the
            // checkerboard debug pattern. The visible area is biased rightward
            // inside the 520-wide buffer (it's not centred). If you see a
            // checkerboard sliver on the left, raise uMin. If the right border
            // looks clipped, raise uMax. Top/bottom are well-centred.
            //   x: [102, 486] of 520  (width 384, gives natural-looking side
            //                          borders roughly matching top/bottom)
            //   y: [16, 300] of 312   (height 284, classic PAL active height)
            return SIMD4<Float>(
                102.0 / 520.0,   // uMin ≈ 0.1962
                16.0 / 312.0,    // vMin ≈ 0.0513
                486.0 / 520.0,   // uMax ≈ 0.9346
                300.0 / 312.0    // vMax ≈ 0.9615
            )
        case .ntsc:
            // NTSC visible region inside VCCore's texture:
            //   x: [55, 466] of 520  (width 411)
            //   y: [27, 262] of 312  (height 235)
            // NTSC pixels are slightly wider than PAL, and the active area
            // starts a bit earlier horizontally.
            return SIMD4<Float>(
                55.0 / 520.0,    // uMin ≈ 0.1058
                27.0 / 312.0,    // vMin ≈ 0.0865
                466.0 / 520.0,   // uMax ≈ 0.8962
                262.0 / 312.0    // vMax ≈ 0.8397
            )
        }
    }

    static func from(_ config: BuildConfiguration?) -> VC64VideoStandard {
        // viceVideoStandard is shared with the VICE target and stores
        // "pal" or "ntsc". Default to PAL if unset (matches C64Timing).
        config?.viceVideoStandard == "ntsc" ? .ntsc : .pal
    }
}

extension VC64VideoStandard {

    /// Map to the bridge's ObjC enum.
    var bridgeStandard: VC64Standard {
        self == .ntsc ? .NTSC : .PAL
    }

    /// Map from the bridge's ObjC enum.
    init(bridge: VC64Standard) {
        self = (bridge == .NTSC) ? .ntsc : .pal
    }
}

// MARK: - VC64Renderer

/// Minimal `MTKViewDelegate` that uploads the VC64 frame to a fullscreen quad.
///
/// Uses the simplest possible pipeline: blit the texture into the drawable
/// via a render pass with a fullscreen triangle. No post-processing.
/// If you want scanlines, CRT curvature, or integer scaling, this is the
/// place to add them.
final class VC64Renderer: NSObject, MTKViewDelegate {

    private let device:        MTLDevice
    private let commandQueue:  MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    private var samplerState:  MTLSamplerState?

    /// Set by `VC64EmulatorWindowController.setupMTKView` immediately after
    /// constructing this renderer. Must be set before the first draw; otherwise
    /// `draw(in:)` early-returns and the window stays black.
    /// Weak: the target (indirectly) owns this renderer; a strong reference
    /// here was part of the retain cycle that leaked run targets.
    weak var vc64Target: VC64RunTarget?

    /// UV sub-rect of VCCore's 520x312 texture corresponding to the visible
    /// C64 picture. Set at init from the video standard and refreshed by
    /// VC64EmulatorWindowController.syncVideoStandard(_:) on every run.
    /// Only mutated on the main thread; draw(in:) also runs on main.
    var visibleRect: SIMD4<Float>

    init(device: MTLDevice, view: MTKView, videoStandard: VC64VideoStandard) {
        self.device       = device
        self.commandQueue = device.makeCommandQueue()!
        self.visibleRect  = videoStandard.visibleAreaUV
        super.init()
        buildPipeline(view: view)
        buildSampler()
        print("[VC64Renderer] Using \(videoStandard) crop: \(visibleRect)")
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // One-line log when the drawable resizes. If this never fires after
        // the initial creation, autoresizing isn't working and we'll know.
        print("[VC64Renderer] drawableSizeWillChange: \(size)")
    }

    /// Set to true after the first successful draw, so we only log once.
    private var hasLoggedFirstFrame = false

    func draw(in view: MTKView) {
        guard
            let target      = vc64Target,
            let texture     = target.updateTexture(device: device),
            let drawable    = view.currentDrawable,
            let descriptor  = view.currentRenderPassDescriptor,
            let pipeline    = pipelineState,
            let sampler     = samplerState,
            let cmdBuffer   = commandQueue.makeCommandBuffer(),
            let encoder     = cmdBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        // One-shot diagnostics on the first successful draw. Keeps us honest
        // about what the render pipeline is actually seeing.
        if !hasLoggedFirstFrame {
            hasLoggedFirstFrame = true
            let viewBounds = view.bounds
            let drawableSize = view.drawableSize
            let texW = texture.width
            let texH = texture.height
            let windowSize = view.window?.frame.size ?? .zero
            let contentSize = view.window?.contentView?.bounds.size ?? .zero
            print("[VC64Renderer] First draw diagnostics:")
            print("  window.frame.size:        \(windowSize)")
            print("  contentView.bounds.size:  \(contentSize)")
            print("  mtkView.bounds.size:      \(viewBounds.size)")
            print("  mtkView.drawableSize:     \(drawableSize)")
            print("  texture (W x H):          \(texW) x \(texH)")
            print("  visibleRect (uv):         \(visibleRect)")
        }

        descriptor.colorAttachments[0].loadAction  = .clear
        descriptor.colorAttachments[0].storeAction = .store

        encoder.setRenderPipelineState(pipeline)
        // Pass the visible-area UV rect to the vertex shader as a uniform.
        // setVertexBytes is the right choice for tiny buffers — Metal avoids
        // allocating a real MTLBuffer under the hood.
        var rect = visibleRect
        encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        // Fullscreen triangle: 3 vertices, positions computed in the vertex shader.
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        cmdBuffer.present(drawable)
        cmdBuffer.commit()
    }

    // MARK: - Pipeline

    private func buildPipeline(view: MTKView) {
        // Inline MSL — no .metal file needed.
        //
        // The vertex shader emits a fullscreen triangle (positions [-1,3],
        // [-1,-1], [3,-1] in NDC) covering the entire viewport. Its UV
        // outputs are remapped through `uvRect = (uMin, vMin, uMax, vMax)`
        // so that the visible region of VCCore's 520×312 texture fills
        // the viewport. Without this remap, the off-screen border area
        // (vblank/hblank padding) shows up as checkerboard around the C64
        // picture.
        //
        // The fragment shader is a straight texture sample with whatever
        // filter the sampler is configured for (nearest by default for
        // pixel-art crispness).
        let src = """
        #include <metal_stdlib>
        using namespace metal;

        struct Vert { float4 pos [[position]]; float2 uv; };

        vertex Vert vc64_vert(uint vid [[vertex_id]],
                              constant float4 &uvRect [[buffer(0)]]) {
            // Fullscreen triangle covering clip space, with UVs that span
            // [0,2] horizontally and [-1,1] vertically — when interpolated
            // across the visible portion of the triangle inside [-1,1]²
            // they produce a [0,1] × [0,1] gradient.
            float2 pos[3] = { {-1,  3}, {-1, -1}, { 3, -1} };
            float2 uvs[3] = { { 0, -1}, { 0,  1}, { 2,  1} };

            float2 uv = uvs[vid];
            // Remap [0,1]² UV into the visible sub-rect of the source
            // texture. (uvRect = uMin, vMin, uMax, vMax)
            uv.x = mix(uvRect.x, uvRect.z, uv.x);
            uv.y = mix(uvRect.y, uvRect.w, uv.y);

            Vert v;
            v.pos = float4(pos[vid], 0, 1);
            v.uv  = uv;
            return v;
        }

        fragment float4 vc64_frag(Vert in [[stage_in]],
                                   texture2d<float> tex [[texture(0)]],
                                   sampler smp [[sampler(0)]]) {
            // VCCore's texture has alpha=0 on its off-screen vblank/hblank
            // padding (and possibly on parts of the border). Returning that
            // alpha as-is makes those pixels transparent in the drawable,
            // and the window's background shows through as checkerboard.
            // Force alpha to 1.0 — we always want an opaque emulator window.
            float4 c = tex.sample(smp, in.uv);
            c.a = 1.0;
            return c;
        }
        """

        guard
            let lib  = try? device.makeLibrary(source: src, options: nil),
            let vert  = lib.makeFunction(name: "vc64_vert"),
            let frag  = lib.makeFunction(name: "vc64_frag")
        else { return }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction                  = vert
        desc.fragmentFunction                = frag
        desc.colorAttachments[0].pixelFormat = view.colorPixelFormat

        pipelineState = try? device.makeRenderPipelineState(descriptor: desc)
    }

    private func buildSampler() {
        let desc           = MTLSamplerDescriptor()
        // Nearest-neighbor: preserves the pixel-art look of the C64 output.
        // Change to .linear for a softer, slightly blurred appearance.
        desc.minFilter     = .nearest
        desc.magFilter     = .nearest
        desc.mipFilter     = .notMipmapped
        desc.sAddressMode  = .clampToEdge
        desc.tAddressMode  = .clampToEdge
        samplerState       = device.makeSamplerState(descriptor: desc)
    }
}

// MARK: - VC64MTKView

/// `MTKView` subclass that accepts first responder and forwards keystrokes
/// to the `VC64Bridge`. Without this, the emulator window can render frames
/// but can't receive keyboard input — every key triggers the macOS beep
/// because no view in the responder chain handles it.
///
/// Printable characters still go through `autoType` (correct for an IDE
/// typing workflow — it handles shift/case translation). The "special" keys
/// that `autoType` can't deliver — Backspace/DEL, the four arrows, RUN/STOP,
/// RETURN, HOME, and F1–F8 — are routed through the bridge's discrete
/// `pressKey:`/`releaseKey:` so they hold while physically held and release on
/// key-up, which is what games and the C64 editor expect.
final class VC64MTKView: MTKView {

    /// How one macOS keycode maps onto the C64 matrix: the target key, plus
    /// whether we must synthesize a held SHIFT to reach it.
    ///
    /// The C64 has fewer physical keys than a Mac in two places:
    ///   • Cursor: two physical keys (LEFT/RIGHT, UP/DOWN); the reverse
    ///     direction is shift+key. Mac sends four distinct arrow keycodes.
    ///   • Function: four physical keys (F1/F2 … F7/F8); the even key is
    ///     shift+odd. Mac sends eight distinct Fn keycodes.
    /// In both cases the Mac key the user pressed already names the direction
    /// /F-number they want, so we map directly and supply SHIFT ourselves
    /// when the C64 needs it — independent of the user's real shift state.
    private struct C64Mapping {
        let key: VC64KeyCode
        let needsShift: Bool
    }

    private static let specialKeyMap: [UInt16: C64Mapping] = [
        36:  C64Mapping(key: .return,          needsShift: false), // Return
        76:  C64Mapping(key: .return,          needsShift: false), // Enter (keypad)
        51:  C64Mapping(key: .delete,          needsShift: false), // Delete → INST/DEL
        117: C64Mapping(key: .delete,          needsShift: false), // Fwd-Delete → DEL
        115: C64Mapping(key: .home,            needsShift: false), // Home → CLR/HOME
        53:  C64Mapping(key: .runStop,         needsShift: false), // Esc → RUN/STOP

        // Arrows. Bare = RIGHT / DOWN; shifted = LEFT / UP.
        124: C64Mapping(key: .cursorLeftRight, needsShift: false), // Right
        123: C64Mapping(key: .cursorLeftRight, needsShift: true),  // Left
        125: C64Mapping(key: .cursorUpDown,    needsShift: false), // Down
        126: C64Mapping(key: .cursorUpDown,    needsShift: true),  // Up

        // Function keys. macOS Fn keycodes are NOT sequential — these exact
        // values matter. Odd C64 F-keys are bare; even ones are shift+odd.
        122: C64Mapping(key: .f1f2, needsShift: false), // F1
        120: C64Mapping(key: .f1f2, needsShift: true),  // F2  = Shift+F1
        99:  C64Mapping(key: .f3f4, needsShift: false), // F3
        118: C64Mapping(key: .f3f4, needsShift: true),  // F4  = Shift+F3
        96:  C64Mapping(key: .f5f6, needsShift: false), // F5
        97:  C64Mapping(key: .f5f6, needsShift: true),  // F6  = Shift+F5
        98:  C64Mapping(key: .f7f8, needsShift: false), // F7
        100: C64Mapping(key: .f7f8, needsShift: true),  // F8  = Shift+F7
    ]

    /// Keys currently held down via `pressKey:`, so `keyUp:` / `resignFirstResponder`
    /// can release exactly what was pressed (and we never double-press on
    /// auto-repeat). Keyed by macOS keycode.
    private var heldKeys: Set<UInt16> = []

    /// Count of currently-held keys that needed a synthesized SHIFT. We only
    /// release the synthesized SHIFT when this drops to zero, so overlapping
    /// shifted keys (e.g. F2 still down when F4 is pressed) don't release
    /// SHIFT out from under each other.
    private var synthesizedShiftCount: Int = 0

    /// Weak reference to the bridge. Set by the window controller right
    /// after construction. Held weakly because the bridge owns the run
    /// target which owns the window controller which owns this view —
    /// a strong reference here would close the loop.
    weak var bridge: VC64Bridge?

    override var acceptsFirstResponder: Bool { true }

    // Accept first-responder status when the window becomes key, so the
    // user doesn't have to click the view first.
    override func becomeFirstResponder() -> Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let bridge = bridge else {
            super.keyDown(with: event)
            return
        }

        // Special (non-printable) keys: hold via the discrete key API so
        // they behave like real key-down/key-up, including auto-repeat.
        if let mapping = Self.specialKeyMap[event.keyCode] {
            // Ignore OS auto-repeat re-presses; the matrix is already
            // asserted and the C64 does its own repeat. Re-pressing would
            // just churn the matrix counters.
            if event.isARepeat { return }

            // Guard against a missing keyUp (e.g. focus stolen mid-press)
            // having left this keycode "held" — if so, treat as already down.
            if heldKeys.contains(event.keyCode) { return }

            if mapping.needsShift {
                // Press SHIFT before the key so the matrix scan sees the
                // modifier first. Refcount it so overlapping shifted keys
                // don't release it prematurely.
                if synthesizedShiftCount == 0 { bridge.pressKey(.leftShift) }
                synthesizedShiftCount += 1
            }
            bridge.pressKey(mapping.key)
            heldKeys.insert(event.keyCode)
            return
        }

        // Printable characters → autoType (handles case/shift translation).
        if let chars = event.characters, !chars.isEmpty {
            bridge.autoType(chars)
            return
        }

        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        guard let bridge = bridge else { return }

        if heldKeys.remove(event.keyCode) != nil,
           let mapping = Self.specialKeyMap[event.keyCode] {
            bridge.releaseKey(mapping.key)
            if mapping.needsShift {
                synthesizedShiftCount -= 1
                if synthesizedShiftCount <= 0 {
                    synthesizedShiftCount = 0
                    bridge.releaseKey(.leftShift)
                }
            }
        }
        // autoType'd characters self-release; nothing to do for those.
    }

    /// Release every held special key — call when the view loses focus so a
    /// key physically released outside our responder chain doesn't stick.
    override func resignFirstResponder() -> Bool {
        if let bridge = bridge {
            for code in heldKeys {
                if let mapping = Self.specialKeyMap[code] {
                    bridge.releaseKey(mapping.key)
                }
            }
            if synthesizedShiftCount > 0 { bridge.releaseKey(.leftShift) }
            synthesizedShiftCount = 0
            heldKeys.removeAll()
        }
        return super.resignFirstResponder()
    }

    /// Intercept Cmd-W so it closes the emulator window, not the active
    /// editor tab in the IDE window underneath. Other Cmd-shortcuts fall
    /// through to the responder chain — Cmd-Q quits the app, Cmd-, opens
    /// preferences, etc., all of which are still appropriate.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // event.modifierFlags includes a bunch of state we don't care
        // about (caps lock indicator, numeric keypad flag). Mask down to
        // just the standard modifier keys.
        let mods = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)

        if mods == .command, event.charactersIgnoringModifiers == "w" {
            window?.performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // Required to actually become first responder when added to a window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
}

