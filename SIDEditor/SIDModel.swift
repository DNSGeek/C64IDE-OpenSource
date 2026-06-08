import Foundation

// MARK: - SID Constants

/// Base address of the SID chip in the C64 memory map.
let SID_BASE: UInt16 = 0xD400

/// Note names for display (C-0 to B-7).
let NOTE_NAMES = ["C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-"]

/// SID frequency table for notes C-0 through B-7 (96 notes).
/// Based on PAL clock (985248 Hz). Formula: `freq_reg = (note_freq * 2^24) / clock`
let SID_FREQ_TABLE: [UInt16] = {
    var table: [UInt16] = []
    let clock = 985248.0  // PAL clock frequency
    for octave in 0..<8 {
        for note in 0..<12 {
            let noteNum = octave * 12 + note
            // A4 (note 57) = 440 Hz. Calculate frequency for each note.
            let freq = 440.0 * pow(2.0, Double(noteNum - 57) / 12.0)
            // Convert frequency to 16-bit SID register value (capped at 65535)
            let regVal = UInt16(min(65535, (freq * 16_777_216.0) / clock))
            table.append(regVal)
        }
    }
    return table
}()

// MARK: - Waveform

/// OptionSet representing the SID waveform register configuration.
struct SIDWaveform: OptionSet {
    let rawValue: UInt8

    static let triangle = SIDWaveform(rawValue: 0x10)
    static let sawtooth = SIDWaveform(rawValue: 0x20)
    static let pulse    = SIDWaveform(rawValue: 0x40)
    static let noise    = SIDWaveform(rawValue: 0x80)

    /// Gate bit (key on/off). Must be ORed with waveform bits.
    static let gate     = SIDWaveform(rawValue: 0x01)

    /// Human-readable display name (e.g., "TRI+SAW").
    var displayName: String {
        var names: [String] = []
        if contains(.triangle) { names.append("TRI") }
        if contains(.sawtooth) { names.append("SAW") }
        if contains(.pulse)    { names.append("PUL") }
        if contains(.noise)    { names.append("NOI") }
        return names.isEmpty ? "---" : names.joined(separator: "+")
    }
}

// MARK: - SID Instrument

/// Represents a single SID voice instrument configuration.
class SIDInstrument {
    var name: String = "New Sound"
    var waveform: SIDWaveform = .pulse

    // ADSR (4 bits each, 0-15)
    var attack: Int = 2    // 0-15
    var decay: Int = 8     // 0-15
    var sustain: Int = 6   // 0-15 (sustain level)
    var release: Int = 4   // 0-15

    /// Pulse width (12-bit, 0-4095). 2048 = 50% duty cycle.
    var pulseWidth: Int = 2048

    /// Global filter toggle for this instrument (for future per-voice filtering).
    var filterEnabled: Bool = false

    /// Combined ADSR register byte: upper nibble = attack, lower nibble = decay.
    var adsrAD: UInt8 { UInt8((attack << 4) | decay) }
    /// Combined ADSR register byte: upper nibble = sustain, lower nibble = release.
    var adsrSR: UInt8 { UInt8((sustain << 4) | release) }

    /// Control register value (waveform + gate when playing).
    func controlReg(gate: Bool) -> UInt8 {
        var val = waveform.rawValue
        if gate { val |= 0x01 }
        return val
    }

    /// Pulse width split into low and high register bytes.
    var pwLo: UInt8 { UInt8(pulseWidth & 0xFF) }
    var pwHi: UInt8 { UInt8((pulseWidth >> 8) & 0x0F) }

    /// Approximate ADSR time values in milliseconds (matches SID hardware behavior).
    static let attackTimes: [Double] = [2, 8, 16, 24, 38, 56, 68, 80, 100, 250, 500, 800, 1000, 3000, 5000, 8000]
    static let decayReleaseTimes: [Double] = [6, 24, 48, 72, 114, 168, 204, 240, 300, 750, 1500, 2400, 3000, 9000, 15000, 24000]

    /// Creates a deep copy of the instrument.
    func deepCopy() -> SIDInstrument {
        let copy = SIDInstrument()
        copy.name = name
        copy.waveform = waveform
        copy.attack = attack
        copy.decay = decay
        copy.sustain = sustain
        copy.release = release
        copy.pulseWidth = pulseWidth
        copy.filterEnabled = filterEnabled
        return copy
    }
}

// MARK: - Pattern Note

/// Represents a single note entry in the tracker.
struct PatternNote {
    var note: Int = -1        // -1 = empty, 0-95 = C-0 to B-7, 96 = note off
    var instrument: Int = 0   // Instrument index

    static let empty = PatternNote(note: -1, instrument: 0)
    static let noteOff = PatternNote(note: 96, instrument: 0)

    var isEmpty: Bool { note == -1 }
    var isNoteOff: Bool { note == 96 }

    /// Human-readable display string (e.g., "C-4 01").
    var displayString: String {
        if isEmpty { return "... .." }
        if isNoteOff { return "=== .." }
        let octave = note / 12
        let noteName = NOTE_NAMES[note % 12]
        return "\(noteName)\(octave) \(String(format: "%02d", instrument))"
    }
}

// MARK: - Pattern

/// A single pattern containing 3 voices and configurable length.
class SIDPattern {
    var length: Int = 32      // Rows per pattern
    var notes: [[PatternNote]] // [voice][row]

    init(length: Int = 32) {
        self.length = length
        self.notes = Array(repeating: Array(repeating: PatternNote.empty, count: length), count: 3)
    }

    /// Creates a deep copy of the pattern.
    func deepCopy() -> SIDPattern {
        let copy = SIDPattern(length: length)
        copy.notes = notes.map { $0 }  // PatternNote is a struct, so this is a value copy
        return copy
    }
}

// MARK: - Song

/// Represents a complete SID composition: instruments, patterns, sequence, and global settings.
class SIDSong {
    var title: String = "Untitled"
    var author: String = "C64 IDE"
    var speed: Int = 6   // Frames per row (lower = faster; 6 = ~8.3 rows/sec at 50Hz PAL)

    var instruments: [SIDInstrument] = []
    var patterns: [SIDPattern] = []
    var sequence: [Int] = [0]  // Pattern play order

    // Global filter
    var filterCutoff: Int = 1024   // 0-2047 (11-bit)
    var filterResonance: Int = 0   // 0-15
    var filterType: UInt8 = 0      // Bit 4=LP, 5=BP, 6=HP
    var filterVoices: UInt8 = 0    // Bits 0-2 = voice 1-3 filter enable
    var globalVolume: Int = 15     // 0-15

    init() {
        // Default instrument
        instruments.append(SIDInstrument())
        // Default pattern
        patterns.append(SIDPattern())
    }

    /// Creates a deep copy of the song.
    func deepCopy() -> SIDSong {
        let copy = SIDSong()
        copy.title = title
        copy.author = author
        copy.speed = speed
        copy.instruments = instruments.map { $0.deepCopy() }
        copy.patterns = patterns.map { $0.deepCopy() }
        copy.sequence = sequence
        copy.filterCutoff = filterCutoff
        copy.filterResonance = filterResonance
        copy.filterType = filterType
        copy.filterVoices = filterVoices
        copy.globalVolume = globalVolume
        return copy
    }

    /// Generates SID register writes for a given pattern and row.
    func registerWrites(pattern patternIdx: Int, row: Int) -> [(register: UInt8, value: UInt8)] {
        guard patternIdx < patterns.count else { return [] }
        let pattern = patterns[patternIdx]
        guard row < pattern.length else { return [] }

        var writes: [(UInt8, UInt8)] = []

        for voice in 0..<3 {
            let note = pattern.notes[voice][row]
            let voiceBase = UInt8(voice * 7)  // Voice registers are 7 bytes apart

            guard !note.isEmpty else { continue }

            if note.isNoteOff {
                // Gate off — keep waveform, clear gate bit
                let inst = instruments.indices.contains(note.instrument) ? instruments[note.instrument] : instruments[0]
                writes.append((voiceBase + 4, inst.controlReg(gate: false)))
                continue
            }

            let inst = instruments.indices.contains(note.instrument) ? instruments[note.instrument] : instruments[0]
            guard note.note < SID_FREQ_TABLE.count else { continue }

            let freq = SID_FREQ_TABLE[note.note]

            // Gate off first (retrigger)
            writes.append((voiceBase + 4, inst.controlReg(gate: false)))

            // Frequency
            writes.append((voiceBase + 0, UInt8(freq & 0xFF)))
            writes.append((voiceBase + 1, UInt8(freq >> 8)))

            // Pulse width
            writes.append((voiceBase + 2, inst.pwLo))
            writes.append((voiceBase + 3, inst.pwHi))

            // ADSR
            writes.append((voiceBase + 5, inst.adsrAD))
            writes.append((voiceBase + 6, inst.adsrSR))

            // Gate on
            writes.append((voiceBase + 4, inst.controlReg(gate: true)))
        }

        // Filter & volume (always write)
        writes.append((0x15, UInt8(filterCutoff & 0x07)))         // Filter cutoff lo (3 bits)
        writes.append((0x16, UInt8(filterCutoff >> 3)))            // Filter cutoff hi (8 bits)
        writes.append((0x17, UInt8(filterResonance << 4) | filterVoices)) // Resonance + filter voice
        writes.append((0x18, filterType | UInt8(globalVolume)))    // Filter mode + volume

        return writes
    }

    // MARK: - Export

    /// Exports the song as 6502 assembly data containing register writes.
    func exportAsAssembly() -> String {
        var lines = [
            "; SID music data — generated by C64 IDE",
            "; Title: \(title)",
            "; Author: \(author)",
            "; Speed: \(speed) frames/row",
            "",
            "sid_speed:  .byte \(speed)",
            "sid_num_patterns: .byte \(sequence.count)",
            "sid_sequence:",
            "    .byte \(sequence.map { String($0) }.joined(separator: ", "))",
            "",
        ]

        for (pi, pattern) in patterns.enumerated() {
            lines.append("sid_pattern_\(pi):")
            lines.append("    ; Format: num_writes, [reg, val, reg, val, ...]")

            for row in 0..<pattern.length {
                let writes = registerWrites(pattern: pi, row: row)
                if writes.isEmpty {
                    lines.append("    .byte 0  ; row \(row) (empty)")
                } else {
                    let data = writes.flatMap { [String(format: "$%02X", $0.0), String(format: "$%02X", $0.1)] }
                    lines.append("    .byte \(writes.count), \(data.joined(separator: ", "))  ; row \(row)")
                }
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    /// Exports the song as BASIC POKE statements.
    func exportAsBASIC() -> String {
        var lines = [
            "1 REM \(title.uppercased())",
            "2 REM BY \(author.uppercased())",
        ]
        var lineNum = 100

        // Volume
        lines.append("\(lineNum) POKE 54296,\(globalVolume)")
        lineNum += 10

        for (_, patIdx) in sequence.enumerated() {
            guard patIdx < patterns.count else { continue }
            let pattern = patterns[patIdx]

            for row in 0..<pattern.length {
                let writes = registerWrites(pattern: patIdx, row: row)
                guard !writes.isEmpty else { continue }

                let pokes = writes.map { "POKE \(SID_BASE + UInt16($0.0)),\($0.1)" }.joined(separator: ":")
                lines.append("\(lineNum) \(pokes)")
                lineNum += 10

                // Delay
                lines.append("\(lineNum) FOR D=1 TO \(speed * 3):NEXT D")
                lineNum += 10
            }
        }

        // Silence
        lines.append("\(lineNum) POKE 54296,0")

        return lines.joined(separator: "\n")
    }
}

// MARK: - Note Helper

/// Converts a note number (0-95) to a display string (e.g., "C-4").
func noteNameForNumber(_ note: Int) -> String {
    guard note >= 0, note < 96 else { return "---" }
    let octave = note / 12
    let name = NOTE_NAMES[note % 12]
    return "\(name)\(octave)"
}

/// Parses a note string (e.g., "C-4", "C#4") and returns its number (0-95).
func noteNumberForName(_ name: String) -> Int? {
    guard name.count >= 3 else { return nil }
    let notePart = String(name.prefix(2))
    guard let octave = Int(String(name.suffix(1))) else { return nil }
    guard let noteIdx = NOTE_NAMES.firstIndex(of: notePart) else { return nil }
    let noteNum = octave * 12 + noteIdx
    return noteNum >= 0 && noteNum < 96 ? noteNum : nil
}

