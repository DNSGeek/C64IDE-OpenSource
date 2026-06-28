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
    ) -> Result<String, String> {

        // Read the PRG
        guard let data = try? Data(contentsOf: prgURL) else {
            return .failure("Could not read PRG file: \(prgURL.lastPathComponent)")
        }

        guard data.count >= 2 else {
            return .failure("PRG file is too short to contain a load address header.")
        }

        // C64 PRG header: 2-byte little-endian load address
        let loadAddr = UInt16(data[0]) | (UInt16(data[1]) << 8)
        let payload  = data.dropFirst(2)
        let byteCount = payload.count

        guard byteCount > 0 else {
            return .failure("PRG file has no payload bytes after the load address header.")
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

        return .success(output.joined(separator: "\n"))
    }
}
