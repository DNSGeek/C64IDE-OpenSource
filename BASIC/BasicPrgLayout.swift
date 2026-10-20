//
//  BasicPrgLayout.swift
//  C64 IDE
//
//  Finds where a tokenized BASIC program ends inside a PRG file and what
//  follows it, so a BASIC loader stub with machine code behind it can be
//  opened as both.
//

import Foundation

/// The layout of a tokenized BASIC PRG: where its lines end and what, if
/// anything, comes after them.
///
/// A large share of C64 software is a one-line loader such as `10 SYS2061`
/// with the actual program, in machine code, stored directly behind it in the
/// same file. The whole thing loads at $0801 and begins with a well-formed
/// BASIC line, so `BasicTokenizer.isTokenizedBASIC` accepts it and the IDE
/// used to show that single line and nothing else. This scanner walks the
/// program's line links the way the ROM does to find the end of the BASIC
/// part, and reports the bytes behind it so they can be disassembled.
public struct BasicPrgLayout: Equatable {

    /// Address the file loads at, from its two-byte header.
    public let loadAddress: UInt16

    /// Number of well-formed BASIC lines before the program ends.
    public let lineCount: Int

    /// Offset into the PRG data (header included) of the first byte after the
    /// BASIC program: past the two zero link bytes that end a well-formed
    /// program, or at the start of the first "line" whose link does not hold
    /// together.
    public let basicEndOffset: Int

    /// Target of the first `SYS` whose argument is a constant: a number
    /// (`SYS2061`, `SYS(2061)`) or arithmetic on numbers and π, which the
    /// ROM evaluates the same way (`SYS 12*256+13`, Llamasoft's `SYS π*656`).
    /// An argument that needs a variable or a function (`SYS A`,
    /// `SYS PEEK(43)`) is left `nil` rather than guessed at.
    public let sysAddress: UInt16?

    /// Size of the PRG including its header.
    public let fileSize: Int

    /// Fewer trailing bytes than this, with no `SYS` pointing into them, are
    /// taken for padding rather than a program: some tools round a save up to
    /// a sector boundary.
    public static let minimumMachineCodeSize = 16

    /// Address of the first byte after the BASIC program.
    public var trailingAddress: UInt16 {
        UInt16(truncatingIfNeeded: Int(loadAddress) + basicEndOffset - 2)
    }

    /// Number of bytes after the BASIC program.
    public var trailingByteCount: Int { max(0, fileSize - basicEndOffset) }

    /// Address of the last byte in the file. Only meaningful when
    /// `trailingByteCount` is non-zero.
    public var trailingEndAddress: UInt16 {
        UInt16(truncatingIfNeeded: Int(trailingAddress) + trailingByteCount - 1)
    }

    /// Whether the stub's `SYS` lands inside the trailing bytes.
    public var sysTargetsTrailingBytes: Bool {
        guard let sys = sysAddress, trailingByteCount > 0 else { return false }
        let start = Int(trailingAddress)
        return Int(sys) >= start && Int(sys) < start + trailingByteCount
    }

    /// Whether the bytes behind the BASIC lines look like a program rather
    /// than padding.
    public var hasMachineCode: Bool {
        trailingByteCount >= Self.minimumMachineCodeSize || sysTargetsTrailingBytes
    }

    /// Whether the file is a BASIC program (at least one well-formed line)
    /// with machine code stored behind it. This is the case the IDE opens as
    /// a BASIC tab plus a disassembly; a file with no usable line at all is
    /// left to the existing routing.
    public var isBasicWithMachineCode: Bool { lineCount > 0 && hasMachineCode }

    /// The BASIC program alone, header included, ready for the detokenizer.
    public func basicPortion(of prg: Data) -> Data {
        Data(prg.prefix(min(basicEndOffset, prg.count)))
    }

    /// The bytes after the BASIC program.
    public func machineCode(in prg: Data) -> [UInt8] {
        guard basicEndOffset < prg.count else { return [] }
        return Array(prg.dropFirst(basicEndOffset))
    }

    /// One line for status output, such as
    /// `1 BASIC line, then 6131 bytes of machine code at $080D-$2003 (SYS 2061 = $080D)`.
    public var summary: String {
        let lines = lineCount == 1 ? "1 BASIC line" : "\(lineCount) BASIC lines"
        var text = String(format: "%@, then %ld bytes of machine code at $%04X-$%04X",
                          lines, trailingByteCount,
                          Int(trailingAddress), Int(trailingEndAddress))
        if let sys = sysAddress {
            text += String(format: " (SYS %ld = $%04X%@)", Int(sys), Int(sys),
                           sysTargetsTrailingBytes ? "" : ", outside the file")
        }
        return text
    }

    // MARK: - Scanning

    private static let quote: UInt8 = 0x22
    private static let sysToken: UInt8 = 0x9E
    private static let remToken: UInt8 = 0x8F

    /// Walks the line links of a tokenized BASIC PRG.
    ///
    /// Each line is `link(2) number(2) tokens... $00`. The ROM follows `link`
    /// to the next line and stops at a zero link. A link that points backwards,
    /// at itself, into the line's own body, or outside the file is not a BASIC
    /// line at all: it is the first bytes of whatever follows the program, so
    /// the walk ends there. A link that jumps forward past the terminator is
    /// followed as the ROM would follow it.
    ///
    /// - Returns: `nil` for data too short to hold a header and one link.
    public static func analyze(_ prg: Data) -> BasicPrgLayout? {
        let bytes = Array(prg)
        let count = bytes.count
        guard count >= 4 else { return nil }

        let loadAddress = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        var offset = 2
        var lineCount = 0
        var sysAddress: UInt16? = nil
        // A program that runs off the end of the file without an end marker
        // has nothing behind it.
        var basicEndOffset = count

        while offset + 1 < count {
            let link = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            if link == 0 {
                // End-of-program marker.
                basicEndOffset = offset + 2
                break
            }

            let lineAddress = Int(loadAddress) + offset - 2
            let linkOffset = link - Int(loadAddress) + 2
            // A link has to move forward, land inside the file, and leave
            // room for a line number.
            guard link > lineAddress, linkOffset <= count, offset + 4 <= count else {
                basicEndOffset = offset
                break
            }

            // Scan the line body for its terminator, noting the first SYS.
            var p = offset + 4
            var inQuotes = false
            var literal = false       // after REM nothing is a token
            while p < count && bytes[p] != 0 {
                let b = bytes[p]
                if !literal {
                    if b == quote {
                        inQuotes.toggle()
                    } else if !inQuotes {
                        if b == remToken {
                            literal = true
                        } else if b == sysToken, sysAddress == nil {
                            sysAddress = parseSysArgument(bytes, from: p + 1)
                        }
                    }
                }
                p += 1
            }
            guard p < count, linkOffset >= p + 1 else {
                // No terminator before the end of the file, or a link that
                // points into the line's own body: not a real line.
                basicEndOffset = offset
                break
            }

            lineCount += 1
            offset = linkOffset
        }

        return BasicPrgLayout(loadAddress: loadAddress,
                              lineCount: lineCount,
                              basicEndOffset: basicEndOffset,
                              sysAddress: sysAddress,
                              fileSize: count)
    }

    /// Evaluates a `SYS` argument the way the ROM would, as far as constants
    /// go, and converts it to an address.
    ///
    /// `SYS` calls FRMNUM and then GETADR: the expression is evaluated in
    /// floating point, must be non-negative and below 65536, and is truncated
    /// to an integer. Whatever follows the expression is not the ROM's
    /// concern until the routine returns (`SYS2066 KBR` jumps to 2066), so
    /// trailing text is ignored here too.
    private static func parseSysArgument(_ bytes: [UInt8], from start: Int) -> UInt16? {
        var parser = ConstantExpression(bytes: bytes, position: start)
        guard let value = parser.expression(), value.isFinite,
              value >= 0, value < 65536 else { return nil }
        return UInt16(value.rounded(.down))
    }

    /// A recursive-descent evaluator for the arithmetic BASIC allows in a
    /// constant expression: numbers, π, `+ - * / ^`, unary sign and
    /// parentheses, with the ROM's precedence (`^` above unary minus above
    /// `* /` above `+ -`). Anything else -- a variable, a function, a string
    /// -- makes the whole expression unknown.
    private struct ConstantExpression {
        let bytes: [UInt8]
        var position: Int

        private static let plus: UInt8 = 0xAA
        private static let minus: UInt8 = 0xAB
        private static let times: UInt8 = 0xAC
        private static let divide: UInt8 = 0xAD
        private static let power: UInt8 = 0xAE
        private static let pi: UInt8 = 0xFF

        private var current: UInt8? {
            position < bytes.count ? bytes[position] : nil
        }

        private mutating func skipSpaces() {
            while current == 0x20 { position += 1 }
        }

        /// Consumes `byte` if it is next (after spaces).
        private mutating func accept(_ byte: UInt8) -> Bool {
            skipSpaces()
            guard current == byte else { return false }
            position += 1
            return true
        }

        mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while true {
                if accept(Self.plus) {
                    guard let rhs = term() else { return nil }
                    value += rhs
                } else if accept(Self.minus) {
                    guard let rhs = term() else { return nil }
                    value -= rhs
                } else {
                    return value
                }
            }
        }

        private mutating func term() -> Double? {
            guard var value = signed() else { return nil }
            while true {
                if accept(Self.times) {
                    guard let rhs = signed() else { return nil }
                    value *= rhs
                } else if accept(Self.divide) {
                    guard let rhs = signed(), rhs != 0 else { return nil }
                    value /= rhs
                } else {
                    return value
                }
            }
        }

        private mutating func signed() -> Double? {
            if accept(Self.minus) { return signed().map { -$0 } }
            if accept(Self.plus)  { return signed() }
            return powered()
        }

        private mutating func powered() -> Double? {
            guard let base = primary() else { return nil }
            guard accept(Self.power) else { return base }
            // Right-associative, and the exponent may carry its own sign.
            guard let exponent = signed() else { return nil }
            return pow(base, exponent)
        }

        private mutating func primary() -> Double? {
            skipSpaces()
            guard let byte = current else { return nil }
            if byte == Self.pi {
                position += 1
                return Double.pi
            }
            if byte == 0x28 {   // (
                position += 1
                guard let inner = expression(), accept(0x29) else { return nil }
                return inner
            }
            return number()
        }

        /// Digits with an optional decimal point, as `123`, `12.5` or `.5`.
        private mutating func number() -> Double? {
            var text = ""
            var sawDigit = false
            while let byte = current, (0x30...0x39).contains(byte) || byte == 0x2E {
                if byte == 0x2E {
                    guard !text.contains(".") else { break }
                    text.append(".")
                } else {
                    sawDigit = true
                    text.append(Character(UnicodeScalar(byte)))
                }
                position += 1
            }
            guard sawDigit else { return nil }
            return Double(text.hasPrefix(".") ? "0" + text : text)
        }
    }
}
