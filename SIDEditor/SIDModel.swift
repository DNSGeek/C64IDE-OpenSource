import Foundation

// MARK: - SID Constants

/// Base address of the SID chip in the C64 memory map.
let SID_BASE: UInt16 = 0xD400

/// Note names for display (C-0 to B-7).
let NOTE_NAMES = ["C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-"]

/// Highest usable note number on a PAL SID.
/// B-7 (note 95, 3951 Hz) computes to a register value of 67,283, which
/// overflows the 16-bit frequency register, so the usable range tops out
/// at A#7 (note 94). Note 96 remains the note-off sentinel.
let SID_NOTE_MAX = 94

/// SID frequency table for notes C-0 through B-7 (96 notes).
/// Entries above SID_NOTE_MAX are clamped to $FFFF and should not be used.
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
final class SIDInstrument {
    var name: String = "New Sound"
    var waveform: SIDWaveform = .pulse

    // ADSR (4 bits each, 0-15)
    var attack: Int = 2    // 0-15
    var decay: Int = 8     // 0-15
    var sustain: Int = 6   // 0-15 (sustain level)
    var release: Int = 4   // 0-15

    /// Pulse width (12-bit, 0-4095). 2048 = 50% duty cycle.
    var pulseWidth: Int = 2048

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
    var isNoteOn: Bool { !isEmpty && !isNoteOff }

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
final class SIDPattern {
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
final class SIDSong {
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

            if note.isEmpty {
                // Lookahead: if the next row starts a new note on this voice,
                // gate off now so the envelope has a full row to release before
                // the retrigger. Gating off and back on within the same frame
                // does not reliably retrigger the envelope on real hardware
                // (the SID ADSR bug); releasing one row early is standard
                // practice for drivers without frame-level hard restart.
                if row + 1 < pattern.length, pattern.notes[voice][row + 1].isNoteOn {
                    let inst = gateOffInstrument(voice: voice, row: row, pattern: pattern)
                    writes.append((voiceBase + 4, inst.controlReg(gate: false)))
                }
                continue
            }

            if note.isNoteOff {
                // Gate off — keep waveform, clear gate bit
                let inst = instruments.indices.contains(note.instrument) ? instruments[note.instrument] : instruments[0]
                writes.append((voiceBase + 4, inst.controlReg(gate: false)))
                continue
            }

            let inst = instruments.indices.contains(note.instrument) ? instruments[note.instrument] : instruments[0]
            guard note.note >= 0, note.note <= SID_NOTE_MAX else { continue }

            let freq = SID_FREQ_TABLE[note.note]

            // Same-frame gate-off fallback: only needed when the previous row
            // could not clear the gate for us (row 0, or back-to-back notes on
            // this voice). Unreliable on real hardware, but the best a
            // row-granularity format can express. Proper 2-frame hard restart
            // arrives with the frame-tick driver.
            let prevRowClearedGate = row > 0 && !pattern.notes[voice][row - 1].isNoteOn
            if !prevRowClearedGate {
                writes.append((voiceBase + 4, inst.controlReg(gate: false)))
            }

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

    /// Finds the instrument whose waveform bits should be kept when gating a
    /// voice off ahead of a retrigger: the most recent note-on on that voice
    /// within this pattern, falling back to the upcoming note's instrument.
    private func gateOffInstrument(voice: Int, row: Int, pattern: SIDPattern) -> SIDInstrument {
        var r = row
        while r >= 0 {
            let n = pattern.notes[voice][r]
            if n.isNoteOn {
                return instruments.indices.contains(n.instrument) ? instruments[n.instrument] : instruments[0]
            }
            r -= 1
        }
        if row + 1 < pattern.length {
            let next = pattern.notes[voice][row + 1]
            if next.isNoteOn, instruments.indices.contains(next.instrument) {
                return instruments[next.instrument]
            }
        }
        return instruments[0]
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

                // Pack POKEs onto lines without exceeding the C64's 80-character
                // logical line limit (a longer line cannot be typed or re-entered
                // on real hardware).
                let maxLineLength = 78
                var pokes = writes.map { "POKE \(SID_BASE + UInt16($0.0)),\($0.1)" }
                while !pokes.isEmpty {
                    var line = "\(lineNum) \(pokes.removeFirst())"
                    while let next = pokes.first, line.count + 1 + next.count <= maxLineLength {
                        line += ":\(next)"
                        pokes.removeFirst()
                    }
                    lines.append(line)
                    lineNum += 10
                }

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
    return noteNum >= 0 && noteNum <= SID_NOTE_MAX ? noteNum : nil
}

// MARK: - Persistence (Codable)

// File format: JSON, extension .sidsong, versioned via formatVersion.
// Decoding is lenient (missing fields fall back to defaults) so older files
// keep loading as the format grows. sanitize() repairs out-of-range values.

extension SIDWaveform: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = SIDWaveform(rawValue: try container.decode(UInt8.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension PatternNote: Codable {}

extension SIDInstrument: Codable {
    // Note: format version 1 files may contain a legacy "filterEnabled" key;
    // JSONDecoder ignores unknown keys, so those files still load fine.
    private enum CodingKeys: String, CodingKey {
        case name, waveform, attack, decay, sustain, release, pulseWidth
    }

    convenience init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name          = try c.decodeIfPresent(String.self,      forKey: .name)          ?? "New Sound"
        waveform      = try c.decodeIfPresent(SIDWaveform.self, forKey: .waveform)      ?? .pulse
        attack        = try c.decodeIfPresent(Int.self,         forKey: .attack)        ?? 2
        decay         = try c.decodeIfPresent(Int.self,         forKey: .decay)         ?? 8
        sustain       = try c.decodeIfPresent(Int.self,         forKey: .sustain)       ?? 6
        release       = try c.decodeIfPresent(Int.self,         forKey: .release)       ?? 4
        pulseWidth    = try c.decodeIfPresent(Int.self,         forKey: .pulseWidth)    ?? 2048
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name,          forKey: .name)
        try c.encode(waveform,      forKey: .waveform)
        try c.encode(attack,        forKey: .attack)
        try c.encode(decay,         forKey: .decay)
        try c.encode(sustain,       forKey: .sustain)
        try c.encode(release,       forKey: .release)
        try c.encode(pulseWidth,    forKey: .pulseWidth)
    }
}

extension SIDPattern: Codable {
    private enum CodingKeys: String, CodingKey {
        case length, notes
    }

    convenience init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedLength = try c.decodeIfPresent(Int.self, forKey: .length) ?? 32
        self.init(length: max(1, min(256, decodedLength)))
        if let decodedNotes = try c.decodeIfPresent([[PatternNote]].self, forKey: .notes) {
            notes = decodedNotes  // Shape is repaired by SIDSong.sanitize()
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(length, forKey: .length)
        try c.encode(notes,  forKey: .notes)
    }
}

extension SIDSong: Codable {
    /// Current .sidsong file format version. Bump when the schema changes.
    static let currentFormatVersion = 1

    private enum CodingKeys: String, CodingKey {
        case formatVersion, title, author, speed
        case instruments, patterns, sequence
        case filterCutoff, filterResonance, filterType, filterVoices, globalVolume
    }

    convenience init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // formatVersion is informational for now; unknown future keys are
        // ignored by JSONDecoder, so newer minor versions still load.
        title           = try c.decodeIfPresent(String.self,          forKey: .title)           ?? "Untitled"
        author          = try c.decodeIfPresent(String.self,          forKey: .author)          ?? "C64 IDE"
        speed           = try c.decodeIfPresent(Int.self,             forKey: .speed)           ?? 6
        instruments     = try c.decodeIfPresent([SIDInstrument].self, forKey: .instruments)     ?? []
        patterns        = try c.decodeIfPresent([SIDPattern].self,    forKey: .patterns)        ?? []
        sequence        = try c.decodeIfPresent([Int].self,           forKey: .sequence)        ?? [0]
        filterCutoff    = try c.decodeIfPresent(Int.self,             forKey: .filterCutoff)    ?? 1024
        filterResonance = try c.decodeIfPresent(Int.self,             forKey: .filterResonance) ?? 0
        filterType      = try c.decodeIfPresent(UInt8.self,           forKey: .filterType)      ?? 0
        filterVoices    = try c.decodeIfPresent(UInt8.self,           forKey: .filterVoices)    ?? 0
        globalVolume    = try c.decodeIfPresent(Int.self,             forKey: .globalVolume)    ?? 15
        sanitize()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(SIDSong.currentFormatVersion, forKey: .formatVersion)
        try c.encode(title,           forKey: .title)
        try c.encode(author,          forKey: .author)
        try c.encode(speed,           forKey: .speed)
        try c.encode(instruments,     forKey: .instruments)
        try c.encode(patterns,        forKey: .patterns)
        try c.encode(sequence,        forKey: .sequence)
        try c.encode(filterCutoff,    forKey: .filterCutoff)
        try c.encode(filterResonance, forKey: .filterResonance)
        try c.encode(filterType,      forKey: .filterType)
        try c.encode(filterVoices,    forKey: .filterVoices)
        try c.encode(globalVolume,    forKey: .globalVolume)
    }

    /// Clamps and repairs song state after loading a file. Guarantees at
    /// least one instrument and one pattern, exactly 3 voices per pattern
    /// with `length` rows each, valid sequence indices, and in-range values.
    func sanitize() {
        speed = max(1, min(20, speed))

        if instruments.isEmpty { instruments.append(SIDInstrument()) }
        for inst in instruments {
            inst.attack     = max(0, min(15, inst.attack))
            inst.decay      = max(0, min(15, inst.decay))
            inst.sustain    = max(0, min(15, inst.sustain))
            inst.release    = max(0, min(15, inst.release))
            inst.pulseWidth = max(0, min(4095, inst.pulseWidth))
        }

        if patterns.isEmpty { patterns.append(SIDPattern()) }
        for pattern in patterns {
            pattern.length = max(1, min(256, pattern.length))

            while pattern.notes.count < 3 {
                pattern.notes.append(Array(repeating: PatternNote.empty, count: pattern.length))
            }
            if pattern.notes.count > 3 {
                pattern.notes.removeLast(pattern.notes.count - 3)
            }

            for v in 0..<3 {
                if pattern.notes[v].count < pattern.length {
                    let padding = pattern.length - pattern.notes[v].count
                    pattern.notes[v].append(contentsOf: Array(repeating: PatternNote.empty, count: padding))
                } else if pattern.notes[v].count > pattern.length {
                    pattern.notes[v].removeLast(pattern.notes[v].count - pattern.length)
                }

                for r in 0..<pattern.length {
                    var n = pattern.notes[v][r]
                    if n.note != -1 && n.note != 96 {
                        n.note = max(0, min(SID_NOTE_MAX, n.note))
                    }
                    n.instrument = max(0, min(instruments.count - 1, n.instrument))
                    pattern.notes[v][r] = n
                }
            }
        }

        sequence = sequence.filter { patterns.indices.contains($0) }
        if sequence.isEmpty { sequence = [0] }

        filterCutoff    = max(0, min(2047, filterCutoff))
        filterResonance = max(0, min(15, filterResonance))
        filterType     &= 0x70
        filterVoices   &= 0x07
        globalVolume    = max(0, min(15, globalVolume))
    }

    /// Serializes the song to pretty-printed JSON for a .sidsong file.
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Deserializes a song from .sidsong JSON data. The result is sanitized.
    static func fromJSONData(_ data: Data) throws -> SIDSong {
        return try JSONDecoder().decode(SIDSong.self, from: data)
    }
}
