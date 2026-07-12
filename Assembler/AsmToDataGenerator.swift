//  AsmToDataGenerator.swift
//  C64 IDE
//
//  Converts a compiled PRG binary into a self-loading BASIC DATA program.
//
//  Output structure (line numbers separated by user-specified increment):
//
//    <startLine>       FOR I=0 TO <byteCount-1>:READ V:POKE <loadAddr>+I,V:NEXT I
//    <startLine+inc>   SYS <loadAddr>
//    <startLine+inc*2> REM <sourceName> - LOAD $<loadAddr> (<byteCount> BYTES)
//    <startLine+inc*3> DATA ...
//    <startLine+inc*4> DATA ...
//    ...

import Foundation

/// Error describing why PRG-to-DATA generation failed, carrying a
/// human-readable message for display in the build output panel.
struct AsmToDataError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct AsmToDataGenerator {

    // MARK: - Entry Point

    /// Generates BASIC DATA loader text from a PRG file.
    ///
    /// - Parameters:
    ///   - prgURL:      URL of the compiled .prg file.
    ///   - sourceName:  Original assembly source filename (used in the REM line).
    ///   - params:      Dialog parameters (start line, increment, bytes per row).
    /// - Returns:       BASIC source text on success, or a human-readable error string.
    static func generate(
        from prgURL: URL,
        sourceName: String,
        params: AsmToDataParams
    ) -> Result<String, AsmToDataError> {

        // Read the PRG
        guard let data = try? Data(contentsOf: prgURL) else {
            return .failure(AsmToDataError(message: "Could not read PRG file: \(prgURL.lastPathComponent)"))
        }

        guard data.count >= 2 else {
            return .failure(AsmToDataError(message: "PRG file is too short to contain a load address header."))
        }

        // C64 PRG header: 2-byte little-endian load address
        let loadAddr = UInt16(data[0]) | (UInt16(data[1]) << 8)
        let payload  = data.dropFirst(2)
        let byteCount = payload.count

        guard byteCount > 0 else {
            return .failure(AsmToDataError(message: "PRG file has no payload bytes after the load address header."))
        }

        // The loader POKEs loadAddr..loadAddr+byteCount-1; POKE can't reach past $FFFF.
        guard Int(loadAddr) + byteCount <= 0x10000 else {
            return .failure(AsmToDataError(message:
                "Payload of \(byteCount) bytes at $\(String(format: "%04X", loadAddr)) runs past $FFFF."))
        }

        var output: [String] = []
        var lineNum = params.startLine
        let inc     = params.lineIncrement

        // Line 1: FOR/NEXT loader
        // BASIC evaluates the TO expression once at FOR, not per iteration,
        // so baking in the literal byteCount-1 is safe and slightly faster.
        output.append(
            "\(lineNum) FOR I=0 TO \(byteCount - 1):READ V:POKE \(loadAddr)+I,V:NEXT I"
        )
        lineNum += inc

        // Line 2: SYS to launch the loaded code
        output.append("\(lineNum) SYS \(loadAddr)")
        lineNum += inc

        // Line 3: REM showing origin, load address, and byte count
        let addrHex = String(loadAddr, radix: 16, uppercase: true)
        let baseSource = (sourceName as NSString).deletingPathExtension
        output.append(
            "\(lineNum) REM \(baseSource.uppercased()) - LOAD $\(addrHex) (\(byteCount) BYTES)"
        )
        lineNum += inc

        // Lines 4+: DATA statements, bytesPerRow bytes each
        let bytes  = Array(payload)
        var offset = 0

        while offset < bytes.count {
            let end   = min(offset + params.bytesPerRow, bytes.count)
            let chunk = bytes[offset ..< end]
            let csv   = chunk.map { String($0) }.joined(separator: ",")
            output.append("\(lineNum) DATA \(csv)")
            lineNum += inc
            offset  += params.bytesPerRow
        }

        // Self-overlap guard: the generated program is itself a BASIC program
        // occupying memory from $0801 upward, and BASIC variables (I, V) live
        // immediately after the program text. If the POKE target range
        // intersects that region, the loader destroys itself at RUN.
        //
        // Tokenized program size is bounded above by the raw text size plus a
        // small per-line overhead: tokenizing only shrinks keywords, digits
        // and commas are 1:1, and 6 bytes per line generously covers the
        // link pointer, binary line number, and terminator versus the text's
        // line-number prefix. 256 bytes of slack covers the loader's variables.
        let basicStart     = 0x0801
        let tokenizedBound = output.reduce(0) { $0 + $1.utf8.count + 6 } + 2
        let basicEnd       = basicStart + tokenizedBound + 256
        let loadStart      = Int(loadAddr)
        let loadEnd        = loadStart + byteCount

        if loadStart < basicEnd && loadEnd > basicStart {
            let hexAddr = String(format: "%04X", loadAddr)
            let hexEnd  = String(format: "%04X", basicEnd - 1)
            return .failure(AsmToDataError(message:
                "Load address $\(hexAddr) overlaps the generated BASIC program " +
                "(approx. $0801-$\(hexEnd) including variables). The DATA loader " +
                "would POKE over itself at RUN. Link the code above the BASIC " +
                "program instead, e.g. with the Upper RAM ($C000) layout."))
        }

        return .success(output.joined(separator: "\n"))
    }
}
