//  LinkerConfigs.swift
//  C64 IDE
//
//  Provides built-in linker configurations for ld65. Includes standard C64
//  .prg layouts, raw assembly configs, and upper RAM ($C000) layouts.

import Foundation

/// Provides built-in linker configurations for ld65.
struct LinkerConfigs {

    /// Standard C64 `.prg` linker configuration.
    /// Produces a program that loads at `$0801` (BASIC start) with a BASIC stub
    /// that executes `SYS` to the assembly entry point.
    static let c64Prg = """
    # C64 IDE — Standard C64 .prg linker configuration
    # Produces a .prg file loadable with LOAD"*",8,1 then RUN

    FEATURES {
        STARTADDRESS: default = $0801;
    }

    SYMBOLS {
        __LOADADDR__: type = import;
    }

    MEMORY {
        ZP:      file = "", start = $0002, size = $001A, type = rw, define = yes;
        LOADADDR: file = %O, start = %S - 2, size = $0002;
        MAIN:    file = %O, start = %S, size = $D000 - %S, define = yes;
    }

    SEGMENTS {
        ZEROPAGE: load = ZP,       type = zp;
        LOADADDR: load = LOADADDR, type = ro;
        STARTUP:  load = MAIN,     type = ro,  define = yes;
        LOWCODE:  load = MAIN,     type = ro,  optional = yes;
        CODE:     load = MAIN,     type = ro,  define = yes;
        RODATA:   load = MAIN,     type = ro;
        DATA:     load = MAIN,     type = rw;
        BSS:      load = MAIN,     type = bss, define = yes;
    }
    """

    /// Raw assembly `.prg` linker configuration.
    /// No BASIC stub. Intended for programs launched via `SYS <address>`.
    static let c64Raw = """
    # C64 IDE — Raw assembly .prg linker configuration
    # No BASIC stub. Load with LOAD"*",8,1 then SYS <start_address>

    MEMORY {
        LOADADDR: file = %O, start = $0FFE, size = $0002;
        MAIN:     file = %O, start = $1000, size = $CF00;
    }

    SEGMENTS {
        LOADADDR: load = LOADADDR, type = ro;
        CODE:     load = MAIN,     type = ro, define = yes;
        RODATA:   load = MAIN,     type = ro;
        DATA:     load = MAIN,     type = rw;
        BSS:      load = MAIN,     type = bss, define = yes;
    }
    """

    /// Upper RAM (`$C000`) linker configuration.
    /// Popular for machine language routines called from BASIC via `SYS 49152`.
    static let c64UpperRAM = """
    # C64 IDE — Upper RAM ($C000) linker configuration
    # For ML routines called via SYS 49152

    MEMORY {
        LOADADDR: file = %O, start = $BFFE, size = $0002;
        MAIN:     file = %O, start = $C000, size = $1000;
    }

    SEGMENTS {
        LOADADDR: load = LOADADDR, type = ro;
        CODE:     load = MAIN,     type = ro, define = yes;
        RODATA:   load = MAIN,     type = ro;
        DATA:     load = MAIN,     type = rw;
        BSS:      load = MAIN,     type = bss, define = yes;
    }
    """

    /// Writes a configuration string to a temporary file and returns its URL.
    static func writeTemporaryConfig(_ config: String, named name: String) -> URL? {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("c64ide", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let url = tempDir.appendingPathComponent("\(name).cfg")
        do {
            try config.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

