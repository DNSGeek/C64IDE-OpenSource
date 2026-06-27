import Foundation

// ═══════════════════════════════════════════════════════════
// MARK: - C64ROMSymbols
// ═══════════════════════════════════════════════════════════

/// Comprehensive symbol table for C64 BASIC and KERNAL ROM routines.
/// Sourced from the C64 ROM disassembly (unusedino.de) and Commodore
/// Programmer's Reference Guide.
///
/// Used by:
///  - Disassembler: show `JSR CHROUT` instead of `JSR $FFD2`
///  - Debugger: identify which ROM routine the PC is inside
///  - Reference panel: extended lookup for ROM addresses
struct C64ROMSymbols {

    struct Symbol {
        let address: UInt16
        let name: String
        let description: String
        let category: Category
    }

    enum Category: String, CaseIterable {
        case basicCommand    = "BASIC Command"
        case basicFunction   = "BASIC Function"
        case basicInternal   = "BASIC Internal"
        case floatingPoint   = "Floating Point"
        case stringHandling  = "String Handling"
        case memoryManage    = "Memory Management"
        case kernalJumpTable = "KERNAL Jump Table"
        case kernalInternal  = "KERNAL Internal"
        case kernalIO        = "KERNAL I/O"
        case kernalIRQ       = "KERNAL IRQ/NMI"
        case hardwareVector  = "Hardware Vector"
    }

    // MARK: - Lookup

    /// Looks up a symbol by exact address. O(1) via dictionary.
    static func symbol(at address: UInt16) -> Symbol? {
        return symbolDict[address]
    }

    /// Finds which ROM routine an address falls within.
    /// Returns the nearest symbol at or before the given address.
    static func containingRoutine(for address: UInt16) -> Symbol? {
        // Binary search the sorted address list
        var lo = 0, hi = sortedAddresses.count - 1
        var best: UInt16? = nil
        while lo <= hi {
            let mid = (lo + hi) / 2
            let addr = sortedAddresses[mid]
            if addr <= address {
                best = addr
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        guard let found = best else { return nil }
        return symbolDict[found]
    }

    /// Returns all symbols in a given category.
    static func symbols(in category: Category) -> [Symbol] {
        return allSymbols.filter { $0.category == category }
    }

    /// Searches symbols by name (case-insensitive prefix match).
    static func search(_ query: String) -> [Symbol] {
        let q = query.uppercased()
        return allSymbols.filter {
            $0.name.uppercased().hasPrefix(q) ||
            $0.description.uppercased().contains(q)
        }
    }

    // MARK: - All Symbols

    static let allSymbols: [Symbol] = {
        var s: [Symbol] = []

        // ── BASIC ROM: Command Entry Points ──────────────
        // From the jump table at $A00C-$A050
        s.append(contentsOf: [
            Symbol(address: 0xA474, name: "READY",       description: "Print READY. and enter warm start (main loop)", category: .basicInternal),
            Symbol(address: 0xA480, name: "MAIN_LOOP",   description: "BASIC main loop — wait for input", category: .basicInternal),
            Symbol(address: 0xA483, name: "WARM_START",  description: "Standard warm start routine", category: .basicInternal),
            Symbol(address: 0xA533, name: "RELINK",      description: "Relink BASIC program line pointers", category: .basicInternal),
            Symbol(address: 0xA560, name: "GETLIN",      description: "Get line of input into buffer at $0200", category: .basicInternal),
            Symbol(address: 0xA579, name: "CRUNCH",      description: "Tokenize input buffer", category: .basicInternal),
            Symbol(address: 0xA613, name: "FNDLIN",      description: "Search for BASIC line number in $14/$15", category: .basicInternal),
            Symbol(address: 0xA642, name: "CMD_NEW",     description: "NEW command — clear program", category: .basicCommand),
            Symbol(address: 0xA65D, name: "CMD_CLR",     description: "CLR command — clear variables", category: .basicCommand),
            Symbol(address: 0xA67A, name: "STKRST",      description: "Reset stack and program pointers", category: .basicInternal),
            Symbol(address: 0xA68E, name: "SETCUR",      description: "Set current char pointer to start of BASIC - 1", category: .basicInternal),
            Symbol(address: 0xA69B, name: "CMD_LIST",    description: "LIST command", category: .basicCommand),
            Symbol(address: 0xA742, name: "CMD_FOR",     description: "FOR command", category: .basicCommand),
            Symbol(address: 0xA7AE, name: "EXEC_NEXT",   description: "Execute next BASIC statement", category: .basicInternal),
            Symbol(address: 0xA7E4, name: "EXEC_STMT",   description: "Execute statement — dispatch on token", category: .basicInternal),
            Symbol(address: 0xA81C, name: "CMD_RESTORE", description: "RESTORE command — reset DATA pointer", category: .basicCommand),
            Symbol(address: 0xA82E, name: "CMD_STOP",    description: "STOP command", category: .basicCommand),
            Symbol(address: 0xA831, name: "CMD_END",     description: "END command", category: .basicCommand),
            Symbol(address: 0xA856, name: "CMD_CONT",    description: "CONT command — continue after STOP", category: .basicCommand),
            Symbol(address: 0xA871, name: "CMD_RUN",     description: "RUN command", category: .basicCommand),
            Symbol(address: 0xA883, name: "CMD_GOSUB",   description: "GOSUB command — push return addr, goto line", category: .basicCommand),
            Symbol(address: 0xA8A0, name: "CMD_GOTO",    description: "GOTO command", category: .basicCommand),
            Symbol(address: 0xA8D2, name: "CMD_RETURN",  description: "RETURN command — pop GOSUB address", category: .basicCommand),
            Symbol(address: 0xA8F8, name: "CMD_DATA",    description: "DATA command — skip to end of statement", category: .basicCommand),
            Symbol(address: 0xA928, name: "CMD_IF",      description: "IF command — evaluate condition", category: .basicCommand),
            Symbol(address: 0xA93B, name: "CMD_REM",     description: "REM command — skip to end of line", category: .basicCommand),
            Symbol(address: 0xA94B, name: "CMD_ON",      description: "ON command — ON...GOTO / ON...GOSUB", category: .basicCommand),
            Symbol(address: 0xA96B, name: "GETNUM",      description: "Get decimal number into $14/$15", category: .basicInternal),
            Symbol(address: 0xA9A5, name: "CMD_LET",     description: "LET command — variable assignment", category: .basicCommand),
            Symbol(address: 0xAA9F, name: "CMD_PRINT",   description: "PRINT command", category: .basicCommand),
            Symbol(address: 0xAA80, name: "CMD_PRINT_N", description: "PRINT# command", category: .basicCommand),
            Symbol(address: 0xAA86, name: "CMD_CMD",     description: "CMD command — redirect output", category: .basicCommand),
            Symbol(address: 0xAB1E, name: "STROUT_AY",   description: "Print string from address in A/Y", category: .basicInternal),
            Symbol(address: 0xAB21, name: "STROUT",      description: "Print string from $22/$23", category: .basicInternal),
            Symbol(address: 0xAB47, name: "OUTCHR",      description: "Print character in A to current output", category: .basicInternal),
            Symbol(address: 0xABBF, name: "CMD_INPUT",   description: "INPUT command", category: .basicCommand),
            Symbol(address: 0xABA5, name: "CMD_INPUT_N", description: "INPUT# command", category: .basicCommand),
            Symbol(address: 0xAB7B, name: "CMD_GET",     description: "GET command", category: .basicCommand),
            Symbol(address: 0xAC06, name: "CMD_READ",    description: "READ command", category: .basicCommand),
            Symbol(address: 0xAD1E, name: "CMD_NEXT",    description: "NEXT command", category: .basicCommand),

            // ── Expression Evaluation ────────────────────
            Symbol(address: 0xAD9E, name: "FRMEVL",      description: "Evaluate expression — main entry", category: .basicInternal),
            Symbol(address: 0xAE83, name: "GETVAL",      description: "Get arithmetic element (number, variable, function)", category: .basicInternal),
            Symbol(address: 0xAEFF, name: "CHKCOM",      description: "Check for comma ($2C) in BASIC text; ?SYNTAX ERROR if absent", category: .basicInternal),
            Symbol(address: 0xAF08, name: "SYNERR",      description: "Syntax error — print ?SYNTAX ERROR", category: .basicInternal),
            Symbol(address: 0xAF28, name: "GETVAR",      description: "Get value of variable", category: .basicInternal),

            // ── Error Handler ────────────────────────────
            Symbol(address: 0xA437, name: "ERROR",        description: "Handle error — index in X", category: .basicInternal),
            Symbol(address: 0xA43A, name: "ERRMSG",       description: "Standard error message handler", category: .basicInternal),
            Symbol(address: 0xA435, name: "OMERR",        description: "Out of memory error", category: .basicInternal),

            // ── Variable Management ──────────────────────
            Symbol(address: 0xB08B, name: "PTRGET",      description: "Get name and pointer to a variable", category: .basicInternal),
            Symbol(address: 0xB113, name: "ISALPHA",     description: "Check if char in A is alphabetic (C=1)", category: .basicInternal),
            Symbol(address: 0xB1D1, name: "DIMVAR",      description: "Get pointer to dimensioned variable", category: .basicInternal),
            Symbol(address: 0xB37D, name: "FN_FRE",      description: "FRE() function", category: .basicFunction),
            Symbol(address: 0xB39E, name: "FN_POS",      description: "POS() function", category: .basicFunction),
            Symbol(address: 0xB3A6, name: "CHKDIR",      description: "Check for direct mode (error if so)", category: .basicInternal),
            Symbol(address: 0xB3B3, name: "CMD_DEF",     description: "DEF FN command", category: .basicCommand),
            Symbol(address: 0xB3F4, name: "FN_CALL",     description: "Expand FN() call", category: .basicInternal),

            // ── String Functions ──────────────────────────
            Symbol(address: 0xB465, name: "FN_STR",      description: "STR$() function — number to string", category: .stringHandling),
            Symbol(address: 0xB47D, name: "STRALLOC",    description: "Allocate A bytes for string", category: .stringHandling),
            Symbol(address: 0xB487, name: "STRDESC",     description: "Get string descriptor into FAC", category: .stringHandling),
            Symbol(address: 0xB4CA, name: "STRSAV",      description: "Save string descriptor on stack", category: .stringHandling),
            Symbol(address: 0xB526, name: "GARBAG",      description: "String garbage collection", category: .memoryManage),
            Symbol(address: 0xB63D, name: "STRCAT",      description: "Concatenate strings (+ operator)", category: .stringHandling),
            Symbol(address: 0xB67A, name: "STRMOV",      description: "Move string — setup pointers", category: .stringHandling),
            Symbol(address: 0xB688, name: "STRMOV_AXY",  description: "Move string: length A, pointer X/Y", category: .stringHandling),
            Symbol(address: 0xB6A6, name: "FRESTR",      description: "De-allocate temporary string", category: .stringHandling),
            Symbol(address: 0xB6EC, name: "FN_CHR",      description: "CHR$() function", category: .basicFunction),
            Symbol(address: 0xB700, name: "FN_LEFT",     description: "LEFT$() function", category: .basicFunction),
            Symbol(address: 0xB72C, name: "FN_RIGHT",    description: "RIGHT$() function", category: .basicFunction),
            Symbol(address: 0xB737, name: "FN_MID",      description: "MID$() function", category: .basicFunction),
            Symbol(address: 0xB77C, name: "FN_LEN",      description: "LEN() function", category: .basicFunction),
            Symbol(address: 0xB78B, name: "FN_ASC",      description: "ASC() function", category: .basicFunction),
            Symbol(address: 0xB7AD, name: "FN_VAL",      description: "VAL() function", category: .basicFunction),
            Symbol(address: 0xB7EB, name: "GETADR",      description: "Get address into $14/$15 and int in X", category: .basicInternal),
            Symbol(address: 0xB80D, name: "FN_PEEK",     description: "PEEK() function", category: .basicFunction),
            Symbol(address: 0xB824, name: "CMD_POKE",    description: "POKE command", category: .basicCommand),
            Symbol(address: 0xB82D, name: "CMD_WAIT",    description: "WAIT command", category: .basicCommand),

            // ── Floating Point Math ──────────────────────
            // These are the workhorses that BasicCompiler.swift JSRs into
            Symbol(address: 0xB849, name: "FADDH",       description: "Add 0.5 to FAC (rounding)", category: .floatingPoint),
            Symbol(address: 0xB850, name: "FSUB",        description: "Subtract: load float at A/Y into ARG, then FAC = ARG - FAC", category: .floatingPoint),
            Symbol(address: 0xB853, name: "FSUBT",       description: "Subtract: FAC = ARG - FAC (entry after ARG load)", category: .floatingPoint),
            Symbol(address: 0xB867, name: "FADD_AY",     description: "Add: FAC = FAC + float at A/Y", category: .floatingPoint),
            Symbol(address: 0xB86A, name: "FADD",        description: "Add: FAC = FAC + ARG", category: .floatingPoint),
            Symbol(address: 0xB8F7, name: "FZERO",       description: "Set FAC to zero", category: .floatingPoint),
            Symbol(address: 0xB947, name: "NEGFAC",      description: "Negate FAC (change sign)", category: .floatingPoint),
            Symbol(address: 0xB97E, name: "OVERR",       description: "Overflow error", category: .floatingPoint),
            Symbol(address: 0xB9EA, name: "FN_LOG",      description: "LOG() function — natural logarithm", category: .basicFunction),
            Symbol(address: 0xBA2B, name: "FMUL",        description: "Multiply: FAC = FAC * MEM at A/Y", category: .floatingPoint),
            Symbol(address: 0xBA8C, name: "LDARG_AY",    description: "Load ARG from float at address A/Y", category: .floatingPoint),
            Symbol(address: 0xBAE2, name: "FMUL10",      description: "Multiply FAC by 10", category: .floatingPoint),
            Symbol(address: 0xBAFE, name: "FDIV10",      description: "Divide FAC by 10", category: .floatingPoint),
            Symbol(address: 0xBB0F, name: "FDIV_AY",     description: "Divide: FAC = MEM(A/Y) / FAC", category: .floatingPoint),
            Symbol(address: 0xBB12, name: "FDIV",        description: "Divide: FAC = ARG / FAC", category: .floatingPoint),
            Symbol(address: 0xBBA2, name: "LDFAC_AY",    description: "Load FAC from 5-byte float at address A/Y", category: .floatingPoint),
            Symbol(address: 0xBBD0, name: "STFAC_XY",    description: "Store FAC to 5-byte float at address in X(lo)/Y(hi)", category: .floatingPoint),
            Symbol(address: 0xBBFC, name: "LDFAC_ARG",   description: "Copy ARG to FAC", category: .floatingPoint),
            Symbol(address: 0xBC0C, name: "STFAC_ARG",   description: "Copy FAC to ARG", category: .floatingPoint),
            Symbol(address: 0xBC1B, name: "FACSGN",      description: "Get sign of FAC into A ($FF=neg, $00=zero, $01=pos)", category: .floatingPoint),
            Symbol(address: 0xBC2B, name: "FCOMP",       description: "Compare FAC with 5-byte float at A/Y; result in A: 0=equal, +1=FAC>mem, $FF=FAC<mem", category: .floatingPoint),
            Symbol(address: 0xBC39, name: "FN_SGN",      description: "SGN() function", category: .basicFunction),
            Symbol(address: 0xBC3C, name: "FLOAT_A",     description: "Convert unsigned byte in A to FAC (result 0-255)", category: .floatingPoint),
            Symbol(address: 0xBC44, name: "FLOAT_XA",    description: "Convert integer in X(hi)/A(lo) to FAC", category: .floatingPoint),
            Symbol(address: 0xBC4F, name: "GIVAYF",      description: "GIVAYF: convert unsigned 16-bit Y(hi)/A(lo) integer to FAC", category: .floatingPoint),
            Symbol(address: 0xBC58, name: "FN_ABS",      description: "ABS() function", category: .basicFunction),

            Symbol(address: 0xBC9B, name: "FAC2INT",     description: "Convert FAC to 2-byte integer in $64/$65", category: .floatingPoint),
            Symbol(address: 0xBCCC, name: "FN_INT",      description: "INT() function — truncate to integer", category: .basicFunction),
            Symbol(address: 0xBCF3, name: "ASCFLT",      description: "Convert ASCII string to FAC (BASIC input)", category: .floatingPoint),
            Symbol(address: 0xBDC2, name: "INTPRT",      description: "Print integer in A/X", category: .floatingPoint),
            Symbol(address: 0xBDCD, name: "FLTPRT",      description: "Print FAC as floating-point decimal string (setup for FACPRT)", category: .floatingPoint),
            Symbol(address: 0xBDDD, name: "FACPRT",      description: "Print FAC as decimal string", category: .floatingPoint),
            Symbol(address: 0xBDDF, name: "FACSTR",      description: "Convert FAC to ASCII string at $0100", category: .floatingPoint),
            Symbol(address: 0xBF71, name: "FN_SQR",      description: "SQR() function — square root", category: .basicFunction),
            Symbol(address: 0xBF7A, name: "FPWR",        description: "Power: FAC = ARG ^ FAC", category: .floatingPoint),
            Symbol(address: 0xBFED, name: "FN_EXP",      description: "EXP() function — e^x", category: .basicFunction),

            // ── Memory Management ────────────────────────
            Symbol(address: 0xA3B8, name: "BLKMOV",      description: "Move bytes after check for space", category: .memoryManage),
            Symbol(address: 0xA3BF, name: "MOVMEM",      description: "Move memory: $5F/$60→$58/$59, $5A/$5B=end", category: .memoryManage),
            Symbol(address: 0xA3FB, name: "STKSPC",      description: "Check for 2*A bytes free on stack", category: .memoryManage),
            Symbol(address: 0xA408, name: "ARRCHK",      description: "Array area overflow check", category: .memoryManage),
            Symbol(address: 0xA38A, name: "FNDFOR",      description: "Search for FOR blocks on stack", category: .basicInternal),

            // ── KERNAL Jump Table ($FF81-$FFF3) ──────────
            // KERNAL entry points used by the disassembler for annotation
            Symbol(address: 0xFF81, name: "SCINIT",      description: "Initialize VIC, clear screen", category: .kernalJumpTable),
            Symbol(address: 0xFF84, name: "IOINIT",      description: "Initialize CIAs, SID; setup memory config", category: .kernalJumpTable),
            Symbol(address: 0xFF87, name: "RAMTAS",      description: "Test RAM, set BASIC pointers", category: .kernalJumpTable),
            Symbol(address: 0xFF8A, name: "RESTOR",      description: "Restore default I/O vectors at $0314", category: .kernalJumpTable),
            Symbol(address: 0xFF8D, name: "VECTOR",      description: "Copy/store I/O vectors", category: .kernalJumpTable),
            Symbol(address: 0xFF90, name: "SETMSG",      description: "Set KERNAL message control flag", category: .kernalJumpTable),
            Symbol(address: 0xFF93, name: "LSTNSA",      description: "Send secondary address after LISTEN", category: .kernalJumpTable),
            Symbol(address: 0xFF96, name: "TALKSA",      description: "Send secondary address after TALK", category: .kernalJumpTable),
            Symbol(address: 0xFF99, name: "MEMBOT",      description: "Read/set bottom of memory", category: .kernalJumpTable),
            Symbol(address: 0xFF9C, name: "MEMTOP",      description: "Read/set top of memory", category: .kernalJumpTable),
            Symbol(address: 0xFF9F, name: "SCNKEY",      description: "Scan keyboard", category: .kernalJumpTable),
            Symbol(address: 0xFFA2, name: "SETTMO",      description: "Set serial bus timeout", category: .kernalJumpTable),
            Symbol(address: 0xFFA5, name: "IECIN",       description: "Read byte from serial bus", category: .kernalJumpTable),
            Symbol(address: 0xFFA8, name: "IECOUT",      description: "Write byte to serial bus", category: .kernalJumpTable),
            Symbol(address: 0xFFAB, name: "UNTALK",      description: "Send UNTALK to serial bus", category: .kernalJumpTable),
            Symbol(address: 0xFFAE, name: "UNLSTN",      description: "Send UNLISTEN to serial bus", category: .kernalJumpTable),
            Symbol(address: 0xFFB1, name: "LISTEN",      description: "Send LISTEN to serial bus", category: .kernalJumpTable),
            Symbol(address: 0xFFB4, name: "TALK",        description: "Send TALK to serial bus", category: .kernalJumpTable),
            Symbol(address: 0xFFB7, name: "READST",      description: "Read I/O status (ST variable)", category: .kernalJumpTable),
            Symbol(address: 0xFFBA, name: "SETLFS",      description: "Set file parameters (logical#, device#, secondary)", category: .kernalJumpTable),
            Symbol(address: 0xFFBD, name: "SETNAM",      description: "Set filename", category: .kernalJumpTable),
            Symbol(address: 0xFFC0, name: "OPEN",        description: "Open logical file", category: .kernalJumpTable),
            Symbol(address: 0xFFC3, name: "CLOSE",       description: "Close logical file", category: .kernalJumpTable),
            Symbol(address: 0xFFC6, name: "CHKIN",       description: "Set input channel", category: .kernalJumpTable),
            Symbol(address: 0xFFC9, name: "CHKOUT",      description: "Set output channel", category: .kernalJumpTable),
            Symbol(address: 0xFFCC, name: "CLRCHN",      description: "Restore default I/O channels", category: .kernalJumpTable),
            Symbol(address: 0xFFCF, name: "CHRIN",       description: "Read byte from input channel", category: .kernalJumpTable),
            Symbol(address: 0xFFD2, name: "CHROUT",      description: "Write byte to output channel", category: .kernalJumpTable),
            Symbol(address: 0xFFD5, name: "LOAD",        description: "Load file into memory", category: .kernalJumpTable),
            Symbol(address: 0xFFD8, name: "SAVE",        description: "Save memory to file", category: .kernalJumpTable),
            Symbol(address: 0xFFDB, name: "SETTIM",      description: "Set jiffy clock", category: .kernalJumpTable),
            Symbol(address: 0xFFDE, name: "RDTIM",       description: "Read jiffy clock", category: .kernalJumpTable),
            Symbol(address: 0xFFE1, name: "STOP",        description: "Check STOP key", category: .kernalJumpTable),
            Symbol(address: 0xFFE4, name: "GETIN",       description: "Get character from keyboard buffer", category: .kernalJumpTable),
            Symbol(address: 0xFFE7, name: "CLALL",       description: "Close all files", category: .kernalJumpTable),
            Symbol(address: 0xFFEA, name: "UDTIM",       description: "Update jiffy clock", category: .kernalJumpTable),
            Symbol(address: 0xFFED, name: "SCREEN",      description: "Get screen size (X=cols, Y=rows)", category: .kernalJumpTable),
            Symbol(address: 0xFFF0, name: "PLOT",        description: "Read/set cursor position", category: .kernalJumpTable),
            Symbol(address: 0xFFF3, name: "IOBASE",      description: "Get CIA #1 base address (X/Y=$DC00)", category: .kernalJumpTable),

            // ── KERNAL Internal Routines ─────────────────
            // Real addresses behind the jump table, plus commonly called internal routines
            Symbol(address: 0xE000, name: "EXP_FN",      description: "EXP continued / trig polynomial eval", category: .kernalInternal),
            Symbol(address: 0xE043, name: "POLYX",       description: "Polynomial evaluation (odd degrees)", category: .floatingPoint),
            Symbol(address: 0xE059, name: "POLY",        description: "Polynomial evaluation (all degrees)", category: .floatingPoint),
            Symbol(address: 0xE097, name: "FN_RND",      description: "RND() function", category: .basicFunction),
            Symbol(address: 0xE112, name: "BASIN",       description: "Input character from channel (internal)", category: .kernalIO),
            Symbol(address: 0xE118, name: "BSOUT_SETUP", description: "Setup for character output", category: .kernalIO),
            Symbol(address: 0xE10C, name: "BSOUT",       description: "Output character to channel (internal)", category: .kernalIO),
            Symbol(address: 0xE124, name: "GETBYTE",     description: "Get one byte from input channel", category: .kernalIO),
            Symbol(address: 0xE129, name: "CMD_SYS",     description: "SYS command — call ML routine", category: .basicCommand),
            Symbol(address: 0xE155, name: "CMD_SAVE",    description: "SAVE command", category: .basicCommand),
            Symbol(address: 0xE164, name: "CMD_VERIFY",  description: "VERIFY command", category: .basicCommand),
            Symbol(address: 0xE167, name: "CMD_LOAD",    description: "LOAD command", category: .basicCommand),
            Symbol(address: 0xE1BD, name: "CMD_OPEN",    description: "OPEN command", category: .basicCommand),
            Symbol(address: 0xE1C6, name: "CMD_CLOSE",   description: "CLOSE command", category: .basicCommand),
            Symbol(address: 0xE264, name: "FN_COS",      description: "COS() function", category: .basicFunction),
            Symbol(address: 0xE26B, name: "FN_SIN",      description: "SIN() function", category: .basicFunction),
            Symbol(address: 0xE2B4, name: "FN_TAN",      description: "TAN() function", category: .basicFunction),
            Symbol(address: 0xE30E, name: "FN_ATN",      description: "ATN() function", category: .basicFunction),
            Symbol(address: 0xE386, name: "WARM_EXIT",   description: "Warm restart — close channels, READY.", category: .kernalInternal),
            Symbol(address: 0xE394, name: "COLD_START",  description: "Cold start entry — RESET vector target", category: .kernalInternal),
            Symbol(address: 0xE37B, name: "WARM_ENTRY",  description: "Warm start entry — NMI RESTORE vector target", category: .kernalInternal),

            // ── KERNAL Internal: IRQ/NMI/Screen ──────────
            Symbol(address: 0xEA31, name: "IRQ_MAIN",    description: "Main IRQ handler — scan keyboard, update cursor", category: .kernalIRQ),
            Symbol(address: 0xEA87, name: "SCNKEY_INT",  description: "Keyboard scan (internal)", category: .kernalInternal),
            Symbol(address: 0xED09, name: "TALK_INT",    description: "Send TALK on serial bus (internal)", category: .kernalIO),
            Symbol(address: 0xED0C, name: "LISTEN_INT",  description: "Send LISTEN on serial bus (internal)", category: .kernalIO),
            Symbol(address: 0xEDB9, name: "LSTNSA_INT",  description: "Send LISTEN secondary (internal)", category: .kernalIO),
            Symbol(address: 0xEDC7, name: "TALKSA_INT",  description: "Send TALK secondary (internal)", category: .kernalIO),
            Symbol(address: 0xEDDD, name: "IECOUT_INT",  description: "Serial bus byte out (internal)", category: .kernalIO),
            Symbol(address: 0xEDEF, name: "UNTALK_INT",  description: "Send UNTALK (internal)", category: .kernalIO),
            Symbol(address: 0xEDFE, name: "UNLSTN_INT",  description: "Send UNLISTEN (internal)", category: .kernalIO),
            Symbol(address: 0xEE13, name: "IECIN_INT",   description: "Serial bus byte in (internal)", category: .kernalIO),

            // ── KERNAL Internal: File I/O ────────────────
            Symbol(address: 0xF13E, name: "GETIN_INT",   description: "Get character from input (internal)", category: .kernalIO),
            Symbol(address: 0xF157, name: "CHRIN_INT",   description: "Character input (internal)", category: .kernalIO),
            Symbol(address: 0xF1CA, name: "CHROUT_INT",  description: "Character output (internal)", category: .kernalIO),
            Symbol(address: 0xF20E, name: "CHKIN_INT",   description: "Set input file (internal)", category: .kernalIO),
            Symbol(address: 0xF250, name: "CHKOUT_INT",  description: "Set output file (internal)", category: .kernalIO),
            Symbol(address: 0xF291, name: "CLOSE_INT",   description: "Close file (internal)", category: .kernalIO),
            Symbol(address: 0xF333, name: "CLRCHN_INT",  description: "Clear channels (internal)", category: .kernalIO),
            Symbol(address: 0xF34A, name: "OPEN_INT",    description: "Open file (internal)", category: .kernalIO),
            Symbol(address: 0xF49E, name: "LOAD_INT",    description: "Load file (internal)", category: .kernalIO),
            Symbol(address: 0xF5DD, name: "SAVE_INT",    description: "Save file (internal)", category: .kernalIO),

            // ── KERNAL Internal: System ──────────────────
            Symbol(address: 0xF6DD, name: "RDTIM_INT",   description: "Read jiffy clock (internal)", category: .kernalInternal),
            Symbol(address: 0xF6E4, name: "SETTIM_INT",  description: "Set jiffy clock (internal)", category: .kernalInternal),
            Symbol(address: 0xF6ED, name: "STOP_INT",    description: "Check STOP key (internal)", category: .kernalInternal),
            Symbol(address: 0xFCE2, name: "RESET",       description: "Hardware RESET entry point", category: .kernalInternal),
            Symbol(address: 0xFDA3, name: "IOINIT_INT",  description: "Initialize I/O devices (internal)", category: .kernalInternal),
            Symbol(address: 0xFD15, name: "RESTOR_INT",  description: "Restore I/O vectors (internal)", category: .kernalInternal),
            Symbol(address: 0xFD1A, name: "VECTOR_INT",  description: "Set/read I/O vectors (internal)", category: .kernalInternal),
            Symbol(address: 0xFD50, name: "RAMTAS_INT",  description: "RAM test and setup (internal)", category: .kernalInternal),
            Symbol(address: 0xFDF9, name: "SETNAM_INT",  description: "Set filename (internal)", category: .kernalInternal),
            Symbol(address: 0xFE00, name: "SETLFS_INT",  description: "Set file params (internal)", category: .kernalInternal),
            Symbol(address: 0xFE07, name: "READST_INT",  description: "Read status (internal)", category: .kernalInternal),
            Symbol(address: 0xFE18, name: "SETMSG_INT",  description: "Set message control (internal)", category: .kernalInternal),
            Symbol(address: 0xFE21, name: "SETTMO_INT",  description: "Set serial timeout (internal)", category: .kernalInternal),
            Symbol(address: 0xFE25, name: "MEMBOT_INT",  description: "Memory bottom (internal)", category: .kernalInternal),
            Symbol(address: 0xFE34, name: "MEMTOP_INT",  description: "Memory top (internal)", category: .kernalInternal),
            Symbol(address: 0xFE43, name: "NMI_HANDLER", description: "NMI handler entry (checks for RESTORE key)", category: .kernalIRQ),
            Symbol(address: 0xFF48, name: "IRQ_ENTRY",   description: "IRQ/BRK handler entry", category: .kernalIRQ),
            Symbol(address: 0xFF5B, name: "SCINIT_INT",  description: "Screen init (internal)", category: .kernalInternal),

            // ── Hardware Vectors ──────────────────────────
            Symbol(address: 0xFFFA, name: "VEC_NMI",     description: "NMI vector → $FE43", category: .hardwareVector),
            Symbol(address: 0xFFFC, name: "VEC_RESET",   description: "RESET vector → $FCE2", category: .hardwareVector),
            Symbol(address: 0xFFFE, name: "VEC_IRQ",     description: "IRQ/BRK vector → $FF48", category: .hardwareVector),
        ])

        return s
    }()

    // MARK: - Precomputed Lookup Structures

    private static let symbolDict: [UInt16: Symbol] = {
        var d: [UInt16: Symbol] = [:]
        for sym in allSymbols {
            d[sym.address] = sym
        }
        return d
    }()

    private static let sortedAddresses: [UInt16] = {
        allSymbols.map { $0.address }.sorted()
    }()
}

