import Foundation
import AVFoundation

// MARK: - Noise Source

/// 23-bit LFSR noise generator, shared by instrument preview and pattern
/// playback so a noise instrument sounds the same in both places. Matches the
/// SID's register width and tap positions; the clock rate is approximated
/// from the note frequency rather than derived from the oscillator.
private struct SIDNoiseSource {
    private var lfsr: UInt32 = 0x7FFFF8
    private var counter: Double = 0
    private var value: Float = 0
    private let period: Double

    init(frequency: Double, sampleRate: Double) {
        period = max(1.0, sampleRate / max(frequency * 16.0, 1.0))
    }

    /// Advances the register by one output sample and returns its level.
    mutating func next() -> Float {
        counter += 1
        if counter >= period {
            counter -= period
            let bit = ((lfsr >> 22) ^ (lfsr >> 17)) & 1
            lfsr = ((lfsr << 1) | bit) & 0x7F_FFFF
            value = Float(lfsr & 0xFF) / 128.0 - 1.0
        }
        return value
    }
}

// MARK: - Note Event

/// One gated note on a voice, resolved from pattern rows into sample offsets.
private struct SIDNoteEvent {
    let instrument: SIDInstrument
    let frequency: Double
    let startSample: Int
    /// Sample at which the gate bit clears and the release stage begins.
    let gateOffSample: Int
    /// Sample at which rendering stops. A voice has a single oscillator, so
    /// the next note-on takes it over and truncates any remaining release.
    let endSample: Int
}

// MARK: - SID Audio Engine

/// Generates approximate SID audio on macOS using AVAudioEngine.
/// Not a cycle-accurate SID emulator, but sufficient for previewing
/// instruments and patterns while composing.
class SIDAudioEngine {

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    /// Three-band EQ approximating the SID state-variable filter.
    /// Band 0 = low-pass, Band 1 = band-pass, Band 2 = high-pass.
    private let filterNode = AVAudioUnitEQ(numberOfBands: 3)

    private let sampleRate: Double = 44100
    private var isPlaying = false
    private var playbackTimer: Timer?

    /// Rendering a long pattern is far too slow for the main thread — a
    /// 256-row pattern at speed 20 is over 100 seconds of audio — so it runs
    /// here and hops back to the main thread to schedule.
    private let renderQueue = DispatchQueue(label: "com.c64ide.sideditor.render", qos: .userInitiated)

    /// Bumped by every play/stop so a render that finishes after the user
    /// has moved on is discarded instead of being scheduled.
    private var playbackGeneration = 0

    // Playback state
    private var currentRow: Int = 0

    /// Called on each row advance (for UI cursor tracking).
    var onRowAdvanced: ((Int) -> Void)?

    /// Called when playback stops.
    var onPlaybackStopped: (() -> Void)?

    init() {
        setupAudio()
    }

    deinit {
        // Drop the callbacks first: stop() reports the end of playback, and
        // there is nothing left to tell by the time the engine is torn down.
        onRowAdvanced = nil
        onPlaybackStopped = nil
        stop()
        engine.stop()
    }

    private func setupAudio() {
        engine.attach(playerNode)
        engine.attach(filterNode)

        // Band filter types must be set explicitly. AVAudioUnitEQ bands
        // default to .parametric, and a parametric band with its default
        // 0 dB gain passes audio through unchanged, so without these lines
        // the whole filter section is an audible no-op. The resonant
        // variants honor the bandwidth parameter, which is what the SID
        // resonance mapping in applyFilter() feeds.
        filterNode.bands[0].filterType = .resonantLowPass
        filterNode.bands[1].filterType = .bandPass
        filterNode.bands[2].filterType = .resonantHighPass

        // Fully bypassed until applyFilter() configures a song or preview.
        filterNode.bypass = true
        for band in filterNode.bands { band.bypass = true }

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        engine.connect(playerNode, to: filterNode, format: format)
        engine.connect(filterNode, to: engine.mainMixerNode, format: format)

        startEngineIfNeeded()
    }

    /// Starts the engine, or restarts it after an audio route or
    /// configuration change stopped it. Without this a single interruption
    /// leaves every later preview silently doing nothing.
    @discardableResult
    private func startEngineIfNeeded() -> Bool {
        if engine.isRunning { return true }
        do {
            try engine.start()
            return true
        } catch {
            print("SIDAudioEngine: Failed to start audio engine: \(error)")
            return false
        }
    }

    // MARK: - Filter

    /// Applies SID filter settings from a song to the EQ node.
    /// Must be called before scheduling audio so the filter state is ready.
    func applyFilter(song: SIDSong) {
        applyFilter(cutoff: song.filterCutoff,
                    resonance: song.filterResonance,
                    filterType: song.filterType,
                    filterVoices: song.filterVoices)
    }

    /// Applies filter from explicit parameters (used by instrument preview).
    /// filterVoices defaults to "all routed" so callers without routing
    /// context keep the old behavior.
    func applyFilter(cutoff: Int, resonance: Int, filterType: UInt8, filterVoices: UInt8 = 0x07) {
        // SID cutoff: 11-bit value (0–2047) → ~30 Hz to ~12 kHz (exponential)
        // Note: This uses a known approximation curve for SID filter behavior.
        let cutoffNorm = Double(max(0, min(2047, cutoff))) / 2047.0
        let cutoffHz   = Float(30.0 * pow(400.0, cutoffNorm))

        // SID resonance: 4-bit (0–15) → Q factor ~0.7 (flat) to ~8.0 (sharp peak)
        // AVAudioUnitEQ uses bandwidth in octaves (bandwidth = 1/Q).
        let resNorm    = Double(max(0, min(15, resonance))) / 15.0
        let qFactor    = 0.7 + resNorm * 7.3
        let bandwidth  = Float(max(0.05, 1.0 / qFactor))

        // filterType bits: bit 4 = LP, bit 5 = BP, bit 6 = HP
        let enabled: [Bool] = [
            filterType & (1 << 4) != 0,
            filterType & (1 << 5) != 0,
            filterType & (1 << 6) != 0,
        ]

        // On real hardware, voices not routed through the filter (filterVoices
        // bits 0-2) pass through dry. With no voices routed, the filter
        // processes nothing, so bypass it here too. Partial routing (some
        // voices filtered, some dry) cannot be approximated with this global
        // EQ; that fidelity arrives when playback routes through the
        // emulator's SID.
        let anyVoiceRouted = filterVoices & 0x07 != 0

        filterNode.bypass = !enabled.contains(true) || !anyVoiceRouted

        for (i, band) in filterNode.bands.enumerated() {
            band.frequency = cutoffHz
            band.bandwidth = bandwidth
            band.bypass    = !enabled[i]
        }
    }

    // MARK: - Playback Control

    /// Plays a single instrument note (for preview).
    /// `volume` is the song's global volume register value (0-15).
    func playNote(instrument: SIDInstrument, noteNumber: Int, duration: Double = 1.0, volume: Int = 15) {
        guard noteNumber >= 0, noteNumber <= SID_NOTE_MAX else { return }
        // A preview takes over the output, so any pattern in progress ends here.
        stop()
        let freq = frequencyForNote(noteNumber)
        let samples = generateNoteSamples(instrument: instrument, frequency: freq,
                                          duration: duration, amplitude: 0.3 * volumeScale(volume))
        scheduleBuffer(samples)
    }

    /// Plays a single note with explicit filter parameters (used by the instrument preview button).
    func playNote(instrument: SIDInstrument, noteNumber: Int, duration: Double = 1.0,
                  filterCutoff: Int, filterResonance: Int, filterType: UInt8,
                  filterVoices: UInt8 = 0x07, volume: Int = 15) {
        applyFilter(cutoff: filterCutoff, resonance: filterResonance,
                    filterType: filterType, filterVoices: filterVoices)
        playNote(instrument: instrument, noteNumber: noteNumber, duration: duration, volume: volume)
    }

    /// Plays the current pattern.
    func playPattern(song: SIDSong, patternIndex: Int) {
        stop()
        guard song.patterns.indices.contains(patternIndex) else { return }
        applyFilter(song: song)

        let pattern = song.patterns[patternIndex]
        let rowCount = pattern.length
        let rowDuration = Double(max(1, song.speed)) / 50.0  // PAL: 50 frames/sec
        let totalDuration = rowDuration * Double(rowCount)

        currentRow = 0
        isPlaying = true
        playbackGeneration &+= 1
        let generation = playbackGeneration

        // Render from a snapshot: the user can keep editing the live song
        // while the background render is running.
        let snapshot = song.deepCopy()

        renderQueue.async { [weak self] in
            guard let self else { return }
            let samples = self.generatePatternSamples(song: snapshot, patternIndex: patternIndex,
                                                      duration: totalDuration)
            DispatchQueue.main.async {
                guard self.isPlaying, self.playbackGeneration == generation else { return }
                self.scheduleBuffer(samples)
                self.startRowTimer(rowDuration: rowDuration, rowCount: rowCount)
            }
        }
    }

    /// Drives the UI cursor alongside the pre-rendered audio buffer.
    private func startRowTimer(rowDuration: Double, rowCount: Int) {
        playbackTimer = Timer.scheduledTimer(withTimeInterval: rowDuration, repeats: true) { [weak self] timer in
            guard let self, self.isPlaying else {
                timer.invalidate()
                return
            }
            self.currentRow += 1
            if self.currentRow >= rowCount {
                self.stop()
                return
            }
            self.onRowAdvanced?(self.currentRow)
        }
    }

    /// Stops playback and cleans up timers. Reports the stop only if
    /// something was actually playing, so callers can use this to reset
    /// state without generating a spurious callback.
    func stop() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        playbackGeneration &+= 1
        let wasPlaying = isPlaying
        isPlaying = false
        playerNode.stop()
        if wasPlaying { onPlaybackStopped?() }
    }

    var playing: Bool { isPlaying }

    // MARK: - Audio Generation

    private func frequencyForNote(_ noteNumber: Int) -> Double {
        // A4 (note 57) = 440 Hz
        return 440.0 * pow(2.0, Double(noteNumber - 57) / 12.0)
    }

    /// Maps the SID's 4-bit master volume onto an output gain.
    private func volumeScale(_ volume: Int) -> Float {
        Float(max(0, min(15, volume))) / 15.0
    }

    /// Envelope level during the gated (attack/decay/sustain) stages.
    private static func envelopeLevel(_ t: Double, attack: Double, decay: Double, sustain: Double) -> Double {
        if t <= 0 { return 0 }
        if t < attack { return t / max(attack, 0.001) }
        if t < attack + decay {
            return 1.0 - (1.0 - sustain) * ((t - attack) / max(decay, 0.001))
        }
        return sustain
    }

    /// Sums the enabled waveforms at `phase`, averaging when several are on.
    private static func waveformSample(_ waveform: SIDWaveform, phase: Double, pulseWidth: Double,
                                       noise: inout SIDNoiseSource) -> Double {
        var sample: Double = 0
        var count = 0
        if waveform.contains(.triangle) { sample += 2.0 * abs(2.0 * phase - 1.0) - 1.0; count += 1 }
        if waveform.contains(.sawtooth) { sample += 2.0 * phase - 1.0;                  count += 1 }
        if waveform.contains(.pulse)    { sample += phase < pulseWidth ? 1.0 : -1.0;     count += 1 }
        if waveform.contains(.noise)    { sample += Double(noise.next());                count += 1 }
        return count > 1 ? sample / Double(count) : sample
    }

    /// Renders one gated note into `buffer`, mixing additively.
    /// The oscillator phase and the envelope both run from the note's own
    /// start sample, so notes always begin at phase 0 rather than wherever
    /// a free-running oscillator happened to be — the latter puts a step
    /// discontinuity, and an audible click, at the head of every note.
    private func render(_ event: SIDNoteEvent, into buffer: inout [Float], amplitude: Float) {
        let inst = event.instrument
        let attackTime   = SIDInstrument.attackTimes[min(max(0, inst.attack), 15)] / 1000.0
        let decayTime    = SIDInstrument.decayReleaseTimes[min(max(0, inst.decay), 15)] / 1000.0
        let releaseTime  = SIDInstrument.decayReleaseTimes[min(max(0, inst.release), 15)] / 1000.0
        let sustainLevel = Double(min(max(0, inst.sustain), 15)) / 15.0
        let pulseWidth   = Double(inst.pulseWidth) / 4096.0

        let first = max(0, event.startSample)
        let last  = min(event.endSample, buffer.count)
        guard last > first else { return }

        let gateOffT = Double(event.gateOffSample - event.startSample) / sampleRate
        let levelAtGateOff = Self.envelopeLevel(gateOffT, attack: attackTime,
                                                decay: decayTime, sustain: sustainLevel)

        var noise = SIDNoiseSource(frequency: event.frequency, sampleRate: sampleRate)
        let phaseInc = event.frequency / sampleRate
        var phase: Double = 0

        for i in first..<last {
            let t = Double(i - event.startSample) / sampleRate

            let envelope: Double
            if t < gateOffT {
                envelope = Self.envelopeLevel(t, attack: attackTime, decay: decayTime, sustain: sustainLevel)
            } else {
                let progress = (t - gateOffT) / max(releaseTime, 0.001)
                envelope = levelAtGateOff * max(0, 1.0 - progress)
                if envelope <= 0 { break }  // Release finished — nothing left to render
            }

            let sample = Self.waveformSample(inst.waveform, phase: phase,
                                             pulseWidth: pulseWidth, noise: &noise)
            buffer[i] += Float(sample * envelope) * amplitude

            phase += phaseInc
            if phase >= 1.0 { phase -= 1.0 }
        }
    }

    /// Generates samples for a single note with ADSR envelope.
    private func generateNoteSamples(instrument: SIDInstrument, frequency: Double,
                                     duration: Double, amplitude: Float) -> [Float] {
        let numSamples = max(1, Int(sampleRate * duration))
        var samples = [Float](repeating: 0, count: numSamples)

        let gateOffTime = duration * 0.7  // Release starts at 70% of duration
        render(SIDNoteEvent(instrument: instrument,
                            frequency: frequency,
                            startSample: 0,
                            gateOffSample: Int(sampleRate * gateOffTime),
                            endSample: numSamples),
               into: &samples, amplitude: amplitude)

        return samples
    }

    /// Resolves one voice's pattern rows into note events with explicit
    /// gate-off and takeover points, so the renderer can give every note a
    /// real release stage instead of cutting it off at a row boundary.
    private func noteEvents(voice: Int, pattern: SIDPattern, instruments: [SIDInstrument],
                            samplesPerRow: Int, totalSamples: Int) -> [SIDNoteEvent] {
        guard !instruments.isEmpty, pattern.notes.indices.contains(voice) else { return [] }
        let rows = min(pattern.length, pattern.notes[voice].count)
        var events: [SIDNoteEvent] = []

        for row in 0..<rows {
            let note = pattern.notes[voice][row]
            guard note.isNoteOn, note.note >= 0, note.note <= SID_NOTE_MAX else { continue }

            // Find where the gate clears, and where the next note-on claims
            // this voice's oscillator. These are separate rows: a note-off
            // starts the release, but the release keeps ringing until either
            // it decays away or a later note takes the voice.
            var gateOffRow = rows
            var takeoverRow = rows
            var r = row + 1
            while r < rows {
                let next = pattern.notes[voice][r]
                if next.isNoteOn {
                    takeoverRow = r
                    if gateOffRow == rows {
                        // Mirror the driver in SIDSong.registerWrites: when the
                        // row before a retrigger is empty, the gate clears a row
                        // early so the envelope has a full row to release.
                        gateOffRow = (r - 1 > row && pattern.notes[voice][r - 1].isEmpty) ? r - 1 : r
                    }
                    break
                }
                if next.isNoteOff, gateOffRow == rows {
                    gateOffRow = r
                }
                r += 1
            }

            let instIdx = min(max(0, note.instrument), instruments.count - 1)
            events.append(SIDNoteEvent(
                instrument: instruments[instIdx],
                frequency: frequencyForNote(note.note),
                startSample: row * samplesPerRow,
                gateOffSample: min(gateOffRow * samplesPerRow, totalSamples),
                endSample: min(takeoverRow * samplesPerRow, totalSamples)))
        }

        return events
    }

    /// Generates samples for an entire pattern (all 3 voices mixed).
    /// Runs on `renderQueue`; `song` must be a snapshot the caller no longer
    /// mutates.
    private func generatePatternSamples(song: SIDSong, patternIndex: Int, duration: Double) -> [Float] {
        guard song.patterns.indices.contains(patternIndex) else { return [] }
        let pattern = song.patterns[patternIndex]
        guard pattern.notes.count >= 3, !song.instruments.isEmpty else { return [] }

        let numSamples = max(0, Int(sampleRate * duration))
        guard numSamples > 0 else { return [] }
        var mixBuffer = [Float](repeating: 0, count: numSamples)

        let rowDuration = Double(max(1, song.speed)) / 50.0
        let samplesPerRow = max(1, Int(sampleRate * rowDuration))
        let amplitude = 0.25 * volumeScale(song.globalVolume)

        // Voices mix straight into the output buffer — a per-voice buffer plus
        // a separate mixdown pass would triple the allocation for no gain.
        for voice in 0..<3 {
            for event in noteEvents(voice: voice, pattern: pattern, instruments: song.instruments,
                                    samplesPerRow: samplesPerRow, totalSamples: numSamples) {
                render(event, into: &mixBuffer, amplitude: amplitude)
            }
        }

        // Clamp to prevent clipping
        for i in mixBuffer.indices {
            mixBuffer[i] = max(-1.0, min(1.0, mixBuffer[i]))
        }

        return mixBuffer
    }

    // MARK: - Buffer Scheduling

    private func scheduleBuffer(_ samples: [Float]) {
        guard !samples.isEmpty, startEngineIfNeeded() else { return }

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channelData = buffer.floatChannelData![0]
        samples.withUnsafeBufferPointer { src in
            channelData.update(from: src.baseAddress!, count: src.count)
        }

        playerNode.stop()
        playerNode.play()
        // .dataPlayedBack fires once the audio has actually been rendered. The
        // default (.dataConsumed) fires as soon as the player ingests the
        // buffer, which reports the end of playback far too early.
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.isPlaying else { return }
                self.playbackTimer?.invalidate()
                self.playbackTimer = nil
                self.isPlaying = false
                self.onPlaybackStopped?()
            }
        }
    }
}
