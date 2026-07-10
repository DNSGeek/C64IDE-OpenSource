import Foundation
import AVFoundation

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

    // Playback state
    private var song: SIDSong?
    private var currentPattern: Int = 0
    private var currentRow: Int = 0
    private var frameCounter: Int = 0

    /// Called on each row advance (for UI cursor tracking).
    var onRowAdvanced: ((Int) -> Void)?

    /// Called when playback stops.
    var onPlaybackStopped: (() -> Void)?

    init() {
        setupAudio()
    }

    deinit {
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

        do {
            try engine.start()
        } catch {
            print("SIDAudioEngine: Failed to start audio engine: \(error)")
        }
    }

    // MARK: - Filter

    /// Applies SID filter settings from a song to the EQ node.
    /// Must be called before scheduling audio so the filter state is ready.
    func applyFilter(song: SIDSong) {
        // SID cutoff: 11-bit value (0–2047) → ~30 Hz to ~12 kHz (exponential)
        // Note: This uses a known approximation curve for SID filter behavior.
        let cutoffNorm = Double(max(0, min(2047, song.filterCutoff))) / 2047.0
        let cutoffHz   = Float(30.0 * pow(400.0, cutoffNorm))

        // SID resonance: 4-bit (0–15) → Q factor ~0.7 (flat) to ~8.0 (sharp peak)
        // AVAudioUnitEQ uses bandwidth in octaves (bandwidth = 1/Q).
        let resNorm    = Double(max(0, min(15, song.filterResonance))) / 15.0
        let qFactor    = 0.7 + resNorm * 7.3
        let bandwidth  = Float(max(0.05, 1.0 / qFactor))

        // filterType bits: bit 4 = LP, bit 5 = BP, bit 6 = HP
        let lpEnabled  = song.filterType & (1 << 4) != 0
        let bpEnabled  = song.filterType & (1 << 5) != 0
        let hpEnabled  = song.filterType & (1 << 6) != 0
        let anyEnabled = lpEnabled || bpEnabled || hpEnabled

        // On real hardware, voices not routed through the filter (filterVoices
        // bits 0-2) pass through dry. With no voices routed, the filter
        // processes nothing, so bypass it here too. Partial routing (some
        // voices filtered, some dry) cannot be approximated with this global
        // EQ; that fidelity arrives when playback routes through the
        // emulator's SID.
        let anyVoiceRouted = song.filterVoices & 0x07 != 0

        filterNode.bypass = !anyEnabled || !anyVoiceRouted

        let lpBand = filterNode.bands[0]
        lpBand.frequency = cutoffHz
        lpBand.bandwidth = bandwidth
        lpBand.bypass    = !lpEnabled

        let bpBand = filterNode.bands[1]
        bpBand.frequency = cutoffHz
        bpBand.bandwidth = bandwidth
        bpBand.bypass    = !bpEnabled

        let hpBand = filterNode.bands[2]
        hpBand.frequency = cutoffHz
        hpBand.bandwidth = bandwidth
        hpBand.bypass    = !hpEnabled
    }

    /// Applies filter from explicit parameters (used by instrument preview).
    /// filterVoices defaults to "all routed" so callers without routing
    /// context keep the old behavior.
    func applyFilter(cutoff: Int, resonance: Int, filterType: UInt8, filterVoices: UInt8 = 0x07) {
        let cutoffNorm = Double(max(0, min(2047, cutoff))) / 2047.0
        let cutoffHz   = Float(30.0 * pow(400.0, cutoffNorm))
        let resNorm    = Double(max(0, min(15, resonance))) / 15.0
        let qFactor    = 0.7 + resNorm * 7.3
        let bandwidth  = Float(max(0.05, 1.0 / qFactor))

        let lpEnabled  = filterType & (1 << 4) != 0
        let bpEnabled  = filterType & (1 << 5) != 0
        let hpEnabled  = filterType & (1 << 6) != 0
        let anyEnabled = lpEnabled || bpEnabled || hpEnabled
        let anyVoiceRouted = filterVoices & 0x07 != 0

        filterNode.bypass = !anyEnabled || !anyVoiceRouted

        filterNode.bands[0].frequency = cutoffHz
        filterNode.bands[0].bandwidth = bandwidth
        filterNode.bands[0].bypass    = !lpEnabled

        filterNode.bands[1].frequency = cutoffHz
        filterNode.bands[1].bandwidth = bandwidth
        filterNode.bands[1].bypass    = !bpEnabled

        filterNode.bands[2].frequency = cutoffHz
        filterNode.bands[2].bandwidth = bandwidth
        filterNode.bands[2].bypass    = !hpEnabled
    }

    // MARK: - Playback Control

    /// Plays a single instrument note (for preview).
    func playNote(instrument: SIDInstrument, noteNumber: Int, duration: Double = 1.0) {
        guard noteNumber >= 0, noteNumber <= SID_NOTE_MAX else { return }
        let freq = frequencyForNote(noteNumber)
        let samples = generateNoteSamples(instrument: instrument, frequency: freq, duration: duration)
        scheduleBuffer(samples)
    }

    /// Plays a single note with explicit filter parameters (used by the instrument preview button).
    func playNote(instrument: SIDInstrument, noteNumber: Int, duration: Double = 1.0,
                  filterCutoff: Int, filterResonance: Int, filterType: UInt8,
                  filterVoices: UInt8 = 0x07) {
        applyFilter(cutoff: filterCutoff, resonance: filterResonance,
                    filterType: filterType, filterVoices: filterVoices)
        playNote(instrument: instrument, noteNumber: noteNumber, duration: duration)
    }

    /// Plays the current pattern.
    func playPattern(song: SIDSong, patternIndex: Int) {
        stop()
        applyFilter(song: song)

        self.song = song
        self.currentPattern = patternIndex
        self.currentRow = 0
        self.frameCounter = 0
        self.isPlaying = true

        guard patternIndex < song.patterns.count else { return }
        let pattern = song.patterns[patternIndex]
        let framesPerRow = song.speed
        let rowDuration = Double(framesPerRow) / 50.0  // PAL: 50 frames/sec
        let totalDuration = rowDuration * Double(pattern.length)

        let samples = generatePatternSamples(song: song, patternIndex: patternIndex, duration: totalDuration)
        scheduleBuffer(samples)

        // Timer for row tracking (runs on main thread for UI safety)
        playbackTimer = Timer.scheduledTimer(withTimeInterval: rowDuration, repeats: true) { [weak self] timer in
            guard let self = self, self.isPlaying else {
                timer.invalidate()
                return
            }
            self.currentRow += 1
            if self.currentRow >= pattern.length {
                self.stop()
                return
            }
            self.onRowAdvanced?(self.currentRow)
        }
    }

    /// Stops playback and cleans up timers.
    func stop() {
        isPlaying = false
        playbackTimer?.invalidate()
        playbackTimer = nil
        playerNode.stop()
        onPlaybackStopped?()
    }

    var playing: Bool { isPlaying }

    // MARK: - Audio Generation

    private func frequencyForNote(_ noteNumber: Int) -> Double {
        // A4 (note 57) = 440 Hz
        return 440.0 * pow(2.0, Double(noteNumber - 57) / 12.0)
    }

    /// Generates samples for a single note with ADSR envelope.
    private func generateNoteSamples(instrument: SIDInstrument, frequency: Double, duration: Double) -> [Float] {
        let numSamples = Int(sampleRate * duration)
        var samples = [Float](repeating: 0, count: numSamples)

        let aTimes = SIDInstrument.attackTimes
        let drTimes = SIDInstrument.decayReleaseTimes

        let attackTime = aTimes[min(instrument.attack, 15)] / 1000.0
        let decayTime = drTimes[min(instrument.decay, 15)] / 1000.0
        let sustainLevel = Double(instrument.sustain) / 15.0
        let releaseTime = drTimes[min(instrument.release, 15)] / 1000.0

        let gateOffTime = duration * 0.7  // Release starts at 70% of duration
        let pw = Double(instrument.pulseWidth) / 4096.0

        var phase: Double = 0
        let phaseInc = frequency / sampleRate

        // Simplified LFSR state for noise (real SID uses a 23-bit LFSR with specific taps)
        var lfsr: UInt32 = 0x7FFFF8
        var noiseVal: Float = 0
        var noiseSampleCounter: Double = 0
        let noisePeriod = sampleRate / (frequency * 16)  // Approximate noise rate

        for i in 0..<numSamples {
            let t = Double(i) / sampleRate

            // ADSR envelope
            var envelope: Double
            if t < attackTime {
                envelope = t / max(attackTime, 0.001)
            } else if t < attackTime + decayTime {
                let decayProgress = (t - attackTime) / max(decayTime, 0.001)
                envelope = 1.0 - (1.0 - sustainLevel) * decayProgress
            } else if t < gateOffTime {
                envelope = sustainLevel
            } else {
                let releaseProgress = (t - gateOffTime) / max(releaseTime, 0.001)
                envelope = sustainLevel * max(0, 1.0 - releaseProgress)
            }

            // Waveform generation
            var sample: Double = 0
            var waveCount = 0

            if instrument.waveform.contains(.triangle) {
                let tri = 2.0 * abs(2.0 * phase - 1.0) - 1.0
                sample += tri
                waveCount += 1
            }

            if instrument.waveform.contains(.sawtooth) {
                let saw = 2.0 * phase - 1.0
                sample += saw
                waveCount += 1
            }

            if instrument.waveform.contains(.pulse) {
                let pul: Double = phase < pw ? 1.0 : -1.0
                sample += pul
                waveCount += 1
            }

            if instrument.waveform.contains(.noise) {
                noiseSampleCounter += 1
                if noiseSampleCounter >= noisePeriod {
                    noiseSampleCounter = 0
                    let bit = ((lfsr >> 22) ^ (lfsr >> 17)) & 1
                    lfsr = (lfsr << 1) | bit
                    noiseVal = Float(lfsr & 0xFF) / 128.0 - 1.0
                }
                sample += Double(noiseVal)
                waveCount += 1
            }

            if waveCount > 1 { sample /= Double(waveCount) }

            samples[i] = Float(sample * envelope * 0.3)  // 0.3 = master volume

            phase += phaseInc
            if phase >= 1.0 { phase -= 1.0 }
        }

        return samples
    }

    /// Generates samples for an entire pattern (all 3 voices mixed).
    private func generatePatternSamples(song: SIDSong, patternIndex: Int, duration: Double) -> [Float] {
        guard patternIndex < song.patterns.count else { return [] }
        let pattern = song.patterns[patternIndex]

        let numSamples = Int(sampleRate * duration)
        var mixBuffer = [Float](repeating: 0, count: numSamples)

        let framesPerRow = song.speed
        let rowDuration = Double(framesPerRow) / 50.0
        let samplesPerRow = Int(sampleRate * rowDuration)

        // Generate each voice separately then mix
        for voice in 0..<3 {
            var voiceBuffer = [Float](repeating: 0, count: numSamples)
            var currentInst: SIDInstrument?
            var noteStartSample = 0
            var noteFreq: Double = 0
            var gateOn = false

            for row in 0..<pattern.length {
                let rowStartSample = row * samplesPerRow
                let note = pattern.notes[voice][row]

                if note.isNoteOff {
                    gateOn = false
                    currentInst = nil
                } else if !note.isEmpty {
                    let instIdx = min(note.instrument, song.instruments.count - 1)
                    currentInst = song.instruments[max(0, instIdx)]
                    noteFreq = frequencyForNote(note.note)
                    noteStartSample = rowStartSample
                    gateOn = true
                }

                if gateOn, let inst = currentInst {
                    let aTimes = SIDInstrument.attackTimes
                    let drTimes = SIDInstrument.decayReleaseTimes
                    let attackTime = aTimes[min(inst.attack, 15)] / 1000.0
                    let decayTime = drTimes[min(inst.decay, 15)] / 1000.0
                    let sustainLevel = Double(inst.sustain) / 15.0
                    let pw = Double(inst.pulseWidth) / 4096.0

                    for s in 0..<samplesPerRow {
                        let sampleIdx = rowStartSample + s
                        guard sampleIdx < numSamples else { break }

                        let t = Double(sampleIdx - noteStartSample) / sampleRate
                        let phase = fmod(noteFreq * Double(sampleIdx) / sampleRate, 1.0)

                        // Envelope
                        var env: Double
                        if t < attackTime {
                            env = t / max(attackTime, 0.001)
                        } else if t < attackTime + decayTime {
                            env = 1.0 - (1.0 - sustainLevel) * ((t - attackTime) / max(decayTime, 0.001))
                        } else {
                            env = sustainLevel
                        }

                        // Waveform
                        var sample: Double = 0
                        var wc = 0
                        if inst.waveform.contains(.triangle) { sample += 2.0 * abs(2.0 * phase - 1.0) - 1.0; wc += 1 }
                        if inst.waveform.contains(.sawtooth) { sample += 2.0 * phase - 1.0; wc += 1 }
                        if inst.waveform.contains(.pulse) { sample += phase < pw ? 1.0 : -1.0; wc += 1 }
                        if inst.waveform.contains(.noise) {
                            sample += Double.random(in: -1...1) * 0.7
                            wc += 1
                        }
                        if wc > 1 { sample /= Double(wc) }

                        voiceBuffer[sampleIdx] = Float(sample * env * 0.25)
                    }
                }
            }

            // Mix into main buffer
            for i in 0..<numSamples {
                mixBuffer[i] += voiceBuffer[i]
            }
        }

        // Clamp to prevent clipping
        for i in 0..<numSamples {
            mixBuffer[i] = max(-1.0, min(1.0, mixBuffer[i]))
        }

        return mixBuffer
    }

    // MARK: - Buffer Scheduling

    private func scheduleBuffer(_ samples: [Float]) {
        guard !samples.isEmpty else { return }

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channelData = buffer.floatChannelData![0]
        for i in 0..<samples.count {
            channelData[i] = samples[i]
        }

        playerNode.stop()
        playerNode.play()
        playerNode.scheduleBuffer(buffer) { [weak self] in
            DispatchQueue.main.async {
                self?.isPlaying = false
                self?.onPlaybackStopped?()
            }
        }
    }
}

