import Foundation
import AVFoundation

// ═══════════════════════════════════════════════════════════
// MARK: - VC64AudioEngine
// ═══════════════════════════════════════════════════════════

/// AVAudioEngine wrapper that pulls SID samples from the VC64 bridge and
/// streams them to the default audio output.
///
/// Architecture:
///   - One AVAudioEngine, one AVAudioSourceNode producing interleaved stereo
///     Float32 samples.
///   - The source node's render block runs on a real-time audio thread and
///     calls `bridge.copyInterleavedSamples(...)` to drain VCCore's audio
///     ringbuffer directly into the audio device's buffer.
///   - VCCore's Adaptive Sample Rate (ASR) algorithm aligns sample production
///     with the host rate we report via `setHostSampleRate:`, so under normal
///     conditions the ring neither starves nor overflows.
///
/// Lifecycle:
///   - `start()` configures the engine and begins streaming. Idempotent.
///   - `stop()` pauses the engine but keeps it configured for fast restart.
///   - `shutdown()` tears everything down — call when the bridge is going away.
///
/// Threading:
///   The render block runs on a high-priority audio I/O thread managed by
///   CoreAudio. We must not allocate, lock, or call into Swift's runtime
///   metadata from inside it. The bridge's copyInterleaved is a single
///   lock-free read from VCCore's stereo ring, which is safe.
final class VC64AudioEngine {

    // ─────────────────────────────────────────────────────────
    // MARK: Public state
    // ─────────────────────────────────────────────────────────

    /// True when the engine is configured and running. False after stop().
    private(set) var isRunning: Bool = false

    // ─────────────────────────────────────────────────────────
    // MARK: Private state
    // ─────────────────────────────────────────────────────────

    /// Reference back to the bridge. Weak so we don't keep the bridge alive
    /// past its run target's lifetime — if the bridge dies, the render block
    /// will see nil and emit silence.
    private weak var bridge: VC64Bridge?

    /// The engine. Created lazily on first start() — AVAudioEngine itself
    /// is cheap, but constructing it touches the audio session, which we
    /// want to defer until we actually need sound.
    private var engine: AVAudioEngine?

    /// The source node. Holds the render block. Recreated on (re-)start
    /// because its format is fixed at construction time and we want the
    /// option to follow the output device's rate if it changes.
    private var sourceNode: AVAudioSourceNode?

    /// The sample rate currently in use. Mirrors what we told VCCore via
    /// setHostSampleRate, so we can detect rate changes on restart.
    private var configuredSampleRate: Double = 0

    // ─────────────────────────────────────────────────────────
    // MARK: Init / deinit
    // ─────────────────────────────────────────────────────────

    init(bridge: VC64Bridge) {
        self.bridge = bridge
    }

    deinit {
        shutdown()
    }

    // ─────────────────────────────────────────────────────────
    // MARK: Public API
    // ─────────────────────────────────────────────────────────

    /// Start (or restart) audio output. Safe to call repeatedly.
    func start() {
        if isRunning { return }
        guard let bridge = bridge else { return }

        // Reuse the engine across start/stop cycles where possible. Only
        // rebuild if the output rate has changed since last time.
        let engine = engine ?? AVAudioEngine()
        self.engine = engine

        // Query the hardware-preferred output rate. On macOS this is whatever
        // the system audio device is set to (44100 or 48000 typically). The
        // engine's outputNode reports the format it's currently driving.
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        let hostRate = outputFormat.sampleRate

        // Tell VCCore the host rate. ASR will now adapt SID sample production
        // to drain into our render block at this rate.
        bridge.setHostSampleRate(hostRate)
        configuredSampleRate = hostRate

        // (Re)create the source node if the rate changed or we don't have one.
        // The format MUST match what the source node produces — interleaved
        // stereo Float32 at the host rate.
        if sourceNode == nil || hostRate != outputFormat.sampleRate {
            // Detach the old node if there is one.
            if let old = sourceNode {
                engine.detach(old)
                sourceNode = nil
            }

            guard let nodeFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate:   hostRate,
                channels:     2,
                interleaved:  false
            ) else {
                // AVAudioFormat's init is failable because some parameter
                // combinations are invalid. Float32 non-interleaved stereo
                // at any standard sample rate is always valid, so reaching
                // this branch means something very strange happened — bail
                // rather than crash with a force-unwrap.
                //
                // NOTE: interleaved MUST be false here. AVAudioEngine's
                // internal nodes (mainMixerNode, intermediate effect nodes)
                // only accept the "standard" deinterleaved Float32 layout.
                // Interleaved formats are accepted at the outputNode edge
                // only — attempting to connect an interleaved source to
                // mainMixerNode throws kAudioUnitErr_FormatNotSupported
                // (-10868) at engine.connect() time.
                print("[VC64AudioEngine] Failed to construct AVAudioFormat at \(hostRate) Hz")
                return
            }

            // Capture bridge weakly inside the render block. The block runs
            // on the audio I/O thread; we must never call into Swift runtime
            // metadata, allocate, or take locks here.
            //
            // SAFETY: VC64Bridge's copyStereoSamplesLeft:right:frames: is a
            // direct call into VCCore's lock-free audio ring, so it's safe
            // to call from a real-time thread.
            let weakBridge = bridge
            let node = AVAudioSourceNode(format: nodeFormat) {
                [weak weakBridge] _, _, frameCount, audioBufferList -> OSStatus in

                let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
                // Non-interleaved stereo: two separate buffers, one per
                // channel. abl[0] is left, abl[1] is right. Each holds
                // `frameCount` floats.
                guard
                    abl.count >= 2,
                    let leftBuf  = abl[0].mData?.assumingMemoryBound(to: Float.self),
                    let rightBuf = abl[1].mData?.assumingMemoryBound(to: Float.self)
                else {
                    return noErr
                }
                let frameBytes = Int(frameCount) * MemoryLayout<Float>.size

                guard let bridge = weakBridge else {
                    // Bridge gone — emit silence on both channels.
                    memset(leftBuf,  0, frameBytes)
                    memset(rightBuf, 0, frameBytes)
                    return noErr
                }

                // Pull from VCCore. Returns frames actually written (may be
                // less than requested if the ring is starved).
                let framesWritten = bridge.copyStereoSamplesLeft(
                    leftBuf,
                    right:  rightBuf,
                    frames: Int(frameCount)
                )

                // If we got short, zero-fill the rest on both channels so
                // the speaker doesn't play uninitialised memory as static.
                if framesWritten < Int(frameCount) {
                    let startOffset = Int(framesWritten)
                    let remaining   = Int(frameCount) - startOffset
                    if remaining > 0 {
                        let remainingBytes = remaining * MemoryLayout<Float>.size
                        memset(leftBuf.advanced(by:  startOffset), 0, remainingBytes)
                        memset(rightBuf.advanced(by: startOffset), 0, remainingBytes)
                    }
                }

                return noErr
            }

            engine.attach(node)
            engine.connect(node,
                           to: engine.mainMixerNode,
                           format: nodeFormat)
            sourceNode = node
        }

        // Start the engine. This is the call that actually opens the audio
        // device and begins driving the render block.
        do {
            try engine.start()
            isRunning = true
            print("[VC64AudioEngine] Started at \(hostRate) Hz")
        } catch {
            print("[VC64AudioEngine] Failed to start: \(error)")
            isRunning = false
        }
    }

    /// Pause audio output. The engine stays configured for fast restart.
    func stop() {
        guard let engine = engine, isRunning else { return }
        engine.pause()
        isRunning = false
        print("[VC64AudioEngine] Paused")
    }

    /// Tear down the engine entirely. Call when the bridge is being released.
    func shutdown() {
        if let engine = engine {
            if engine.isRunning { engine.stop() }
            if let node = sourceNode {
                engine.detach(node)
            }
        }
        sourceNode = nil
        engine = nil
        isRunning = false
        configuredSampleRate = 0
    }
}

