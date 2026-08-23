import Foundation

// ═══════════════════════════════════════════════════════════
// MARK: - C64ROMSymbols
// ═══════════════════════════════════════════════════════════

/// Symbol table for the Commodore 64 BASIC V2 and KERNAL ROMs.
///
/// Every address in this table was verified against the original
/// Commodore ROM sources (mist64/c64rom), which assemble byte-for-byte
/// to the shipping images:
///   * BASIC  901226-01  (CRC32 f833d117)
///   * KERNAL 901227-03  (CRC32 dbe3e7c7)
/// Names follow the original Commodore source labels where those are the
/// commonly published ones; a few keep the friendlier names used elsewhere
/// in this IDE, with the Commodore label given in the notes.
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
        /// What the routine expects on entry: registers, flags, zero page.
        let input: String?
        /// What it hands back.
        let output: String?
        /// Registers and flags the routine destroys.
        let registers: String?
        /// Caveats: banking, indirection through a RAM vector, side effects,
        /// neighbouring entry points that are easy to confuse with this one.
        let notes: String?
        /// A short, assemble-ready 6502 snippet.
        let example: String?

        init(address: UInt16,
             name: String,
             description: String,
             category: Category,
             input: String? = nil,
             output: String? = nil,
             registers: String? = nil,
             notes: String? = nil,
             example: String? = nil) {
            self.address = address
            self.name = name
            self.description = description
            self.category = category
            self.input = input
            self.output = output
            self.registers = registers
            self.notes = notes
            self.example = example
        }

        /// How you reach this address from assembly. Routines are called;
        /// data tables and hardware vectors are read.
        var callSyntax: String {
            switch category {
            case .romTable, .hardwareVector:
                return String(format: "lda $%04X        ; %@", address, name)
            default:
                return String(format: "jsr $%04X        ; %@", address, name)
            }
        }

        /// The BASIC equivalent, e.g. `SYS 65490`.
        /// Only meaningful for routines that take no register arguments,
        /// so callers should present it as a hint rather than a recipe.
        var sysSyntax: String {
            "SYS \(address)"
        }

        /// Which ROM has to be banked in at $0001 before the call can work.
        var bankingRequirement: String? {
            switch address {
            case 0xA000...0xBFFF:
                return "BASIC ROM must be visible: $01 bits 0-1 = %11 (the default $37). "
                     + "With LORAM low this address is RAM."
            case 0xE000...0xFFFF:
                return "KERNAL ROM must be visible: $01 bit 1 (HIRAM) = 1 (the default $37). "
                     + "With HIRAM low this address is RAM."
            default:
                return nil
            }
        }
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
        case kernalEditor    = "Screen Editor"
        case hardwareVector  = "Hardware Vector"
        case romTable        = "ROM Data Table"
    }

    // MARK: - Shared Notes

    /// FAC1 / FAC2 layout, referenced by the floating-point entries.
    static let facLayoutNote = """
    FAC1 lives at $61-$66: $61 exponent (excess-128, 0 = the value zero), \
    $62-$65 mantissa (MSB first, implicit bit 7 = 1), $66 sign ($00 positive, $FF negative). \
    FAC2/ARG lives at $69-$6E with the same layout. $70 is FAC1's rounding byte (FACOV).
    """

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

        // ══════════════════════════════════════════════════
        // BASIC ROM $A000-$BFFF
        // ══════════════════════════════════════════════════

        // ── ROM header and dispatch tables ───────────────
        s.append(contentsOf: [
            Symbol(address: 0xA000, name: "BASIC_COLD", description: "Word: BASIC cold-start vector. Holds $E394.", category: .romTable,
                   notes: "The KERNAL reset code reads this word after the 'CBM80' cartridge check fails, so a cartridge that fakes the BASIC ROM signature must supply it too."),
            Symbol(address: 0xA002, name: "BASIC_WARM", description: "Word: BASIC warm-start vector. Holds $E37B.", category: .romTable,
                   notes: "Reached by RUN/STOP+RESTORE and by BRK."),
            Symbol(address: 0xA004, name: "CBMBASIC_ID", description: "8-byte ASCII signature 'CBMBASIC'.", category: .romTable,
                   notes: "Handy as a quick 'is the BASIC ROM banked in?' probe: compare $A004 with $43 ('C')."),
            Symbol(address: 0xA00C, name: "STMDSP", description: "Statement dispatch table: 35 words, one per BASIC command token $80 (END) through $A2 (NEW).", category: .romTable,
                   notes: "Each word holds the handler address MINUS ONE, because the interpreter pushes it and RTSes to it. That is why the table reads $A82E for STOP even though STOP starts at $A82F. Index = (token - $80) * 2.",
                   example: """
                   ; fetch the handler for token $9E (SYS)
                   ; ($9E-$80)*2 = $3C  ->  $A00C+$3C = $A048
                   lda $A048          ; low  byte of (handler-1)
                   ldy $A049          ; high byte of (handler-1)
                   """),
            Symbol(address: 0xA052, name: "FUNDSP", description: "Function dispatch table: 23 words, one per function token $B4 (SGN) through $CA (MID$).", category: .romTable,
                   notes: "Unlike STMDSP these are true addresses, not address-1: FRMEVL JSRs through them."),
            Symbol(address: 0xA080, name: "OPTAB", description: "Operator table: 10 three-byte entries -- a priority byte plus the handler address minus one -- for tokens $AA-$B3 (+, -, *, /, ^, AND, OR, >, =, <).", category: .romTable),
            Symbol(address: 0xA09E, name: "RESLST", description: "BASIC keyword table, in token order starting at $80 (END).", category: .romTable,
                   notes: "Keywords are stored in PETSCII with bit 7 set on the LAST character, which is how the tokeniser finds the end of each entry. A $00 terminates the table."),
            Symbol(address: 0xA19E, name: "ERRTXT", description: "Error message text, $00-terminated, in error-number order starting with 'TOO MANY FILES'.", category: .romTable),
            Symbol(address: 0xA328, name: "ERRTAB", description: "Table of pointers into ERRTXT, indexed by error number.", category: .romTable,
                   notes: "ERROR ($A437) indexes this with X*2 - 2, so error numbers are 1-based."),
            Symbol(address: 0xA364, name: "OKMSG", description: "The messages 'OK', ' ERROR' and ' IN ' used when reporting errors.", category: .romTable),
            Symbol(address: 0xA376, name: "REDDY", description: "The string CR/LF 'READY.' CR/LF, $00-terminated.", category: .romTable,
                   example: """
                   lda #$76           ; print READY.
                   ldy #$A3
                   jsr $AB1E          ; STROUT
                   """),
        ])

        // ── Memory management and stack ──────────────────
        s.append(contentsOf: [
            Symbol(address: 0xA38A, name: "FNDFOR", description: "Search the BASIC runtime stack for a FOR or GOSUB frame belonging to the variable in FORPNT ($49/$4A).", category: .basicInternal,
                   input: "$49/$4A = pointer to the loop variable, or $xx00 to match any FOR",
                   output: "Z=1 and X = stack index if a matching FOR frame was found; Z=0 if not",
                   registers: "A, X, Y",
                   notes: "Used by FOR to reuse an existing loop frame and by NEXT to find one. A FOR frame is 18 bytes."),
            Symbol(address: 0xA3B8, name: "BLKMOV", description: "Open a gap in memory: check there is room, then move the block $5F/$60..$5A/$5B up so it ends at $58/$59.", category: .memoryManage,
                   input: "$5F/$60 = source start, $5A/$5B = source end+1, $58/$59 = destination end+1",
                   output: "STREND ($31/$32) updated to the new end of arrays",
                   registers: "A, X, Y",
                   notes: "Commodore label 'BLTU'. Calls REASON ($A408) first and can therefore raise ?OUT OF MEMORY. Use $A3BF to skip the space check."),
            Symbol(address: 0xA3BF, name: "MOVMEM", description: "Move a block of memory upward, without the space check that $A3B8 performs.", category: .memoryManage,
                   input: "$5F/$60 = source start, $5A/$5B = source end+1, $58/$59 = destination end+1",
                   registers: "A, X, Y",
                   notes: "Commodore label 'BLTUC'. Copies downward from the top, so the destination may overlap the source as long as it is HIGHER in memory."),
            Symbol(address: 0xA3FB, name: "STKSPC", description: "Check that 2*A bytes are still free on the 6502 stack below the BASIC runtime stack.", category: .memoryManage,
                   input: "A = number of words needed",
                   output: "Returns normally if there is room",
                   registers: "A, X",
                   notes: "Commodore label 'GETSTK'. Raises ?OUT OF MEMORY (and never returns) if the stack would collide with the string/array area."),
            Symbol(address: 0xA408, name: "REASON", description: "Check that the address in A/Y is below the bottom of string space; garbage-collect and retry if it is not.", category: .memoryManage,
                   input: "A = low byte, Y = high byte of the address to test",
                   output: "Returns with A/Y unchanged if the address fits",
                   registers: "A, X, Y",
                   notes: "Raises ?OUT OF MEMORY if even a garbage collection cannot make room. This is the routine that makes GARBAG appear to freeze a program that is short of string space."),
        ])

        // ── Error handling and the main loop ─────────────
        s.append(contentsOf: [
            Symbol(address: 0xA435, name: "OMERR", description: "Raise ?OUT OF MEMORY: loads X with error 16 and falls into ERROR.", category: .basicInternal,
                   registers: "Does not return",
                   example: """
                   jmp $A435          ; abort with ?OUT OF MEMORY
                   """),
            Symbol(address: 0xA437, name: "ERROR", description: "Raise a BASIC error. Vectored: JMP ($0300).", category: .basicInternal,
                   input: "X = error number (1 = TOO MANY FILES ... 30 = FORMULA TOO COMPLEX)",
                   output: "Never returns; prints '?<message> ERROR IN <line>' and drops to READY",
                   notes: "Hook $0300 (IERROR) to trap BASIC errors from machine code. After a cold start $0300 holds $E38B, which either falls through to the default handler at $A43A or, when X has bit 7 set, just prints READY. via $A474.",
                   example: """
                   ldx #$0B           ; 11 = SYNTAX
                   jmp $A437          ; ?SYNTAX ERROR
                   """),
            Symbol(address: 0xA43A, name: "ERRMSG", description: "Default error handler: print '?<message> ERROR', add ' IN <line>' if not in direct mode, then fall into READY.", category: .basicInternal,
                   input: "X = error number",
                   notes: "Commodore label 'NERROX'. This is the routine $0300 points at after a reset."),
            Symbol(address: 0xA474, name: "READY", description: "Print CR/LF 'READY.' CR/LF, re-enable direct-mode messages, and fall into the main loop.", category: .basicInternal,
                   notes: "Commodore label 'READYX'. Entering here from machine code is the polite way to hand control back to BASIC after a SYS that cannot RTS.",
                   example: """
                   jmp $A474          ; give up and return to READY.
                   """),
            Symbol(address: 0xA480, name: "MAIN_LOOP", description: "BASIC's immediate-mode loop. Vectored: JMP ($0302).", category: .basicInternal,
                   notes: "Hook $0302 (IMAIN) to add your own commands or an input filter; the default target is $A483.",
                   example: """
                   ; install a custom immediate-mode handler
                   lda #<myloop
                   sta $0302
                   lda #>myloop
                   sta $0303
                   """),
            Symbol(address: 0xA483, name: "NMAIN", description: "Default main-loop body: read a line with INLIN, tokenise it, then either store it as a program line or execute it immediately.", category: .basicInternal),
            Symbol(address: 0xA533, name: "RELINK", description: "Rebuild the forward-link pointers that chain BASIC program lines together.", category: .basicInternal,
                   input: "TXTTAB ($2B/$2C) = start of program",
                   registers: "A, X, Y",
                   notes: "Call this after POKEing new lines into a program by hand, otherwise LIST and RUN follow stale links.",
                   example: """
                   jsr $A533          ; relink after editing the program
                   """),
            Symbol(address: 0xA560, name: "GETLIN", description: "Read a logical line from the current input channel into the BASIC input buffer at $0200.", category: .basicInternal,
                   output: "X = $00, Y = $02 (pointer to the buffer); the line is $00-terminated",
                   registers: "A, X, Y",
                   notes: "Commodore label 'INLIN'. Echoes what it reads and honours the screen editor, so from the keyboard the user can move the cursor around and press RETURN on any line."),
            Symbol(address: 0xA579, name: "CRUNCH", description: "Tokenise the text in the input buffer in place, turning keywords into single bytes. Vectored: JMP ($0304).", category: .basicInternal,
                   input: "TXTPTR ($7A/$7B) points into the buffer",
                   notes: "Hook $0304 (ICRNCH) to tokenise your own keyword extensions. The default routine is at $A57C."),
            Symbol(address: 0xA613, name: "FNDLIN", description: "Search the program for a line number.", category: .basicInternal,
                   input: "$14/$15 = line number to find",
                   output: "Carry=1 if found, and $5F/$60 points at the line's link field; Carry=0 if not found, with $5F/$60 pointing at the first line whose number is higher",
                   registers: "A, X, Y",
                   notes: "Lines are searched linearly from the start of the program, so this is O(n)."),
        ])

        // ── BASIC commands ───────────────────────────────
        s.append(contentsOf: [
            Symbol(address: 0xA642, name: "CMD_NEW", description: "NEW: erase the program, reset the pointers, then fall into CLR.", category: .basicCommand,
                   notes: "Commodore label 'SCRATH'. It only writes a $00 link at TXTTAB, so an accidental NEW is recoverable by restoring the link bytes and calling RELINK ($A533)."),
            Symbol(address: 0xA65E, name: "CMD_CLR", description: "CLR: call CLALL to drop all open files, discard all variables, arrays and strings, and reset the runtime stack.", category: .basicCommand,
                   registers: "A, X, Y",
                   notes: "Commodore label 'CLEAR'. Also called by RUN. The STMDSP table stores $A65D because it dispatches with RTS."),
            Symbol(address: 0xA67A, name: "STKRST", description: "Reset the 6502 stack pointer to $FA and clear the BASIC temporary-string descriptors.", category: .basicInternal,
                   notes: "Commodore label 'STKINI'. Discards every pending FOR and GOSUB frame; it is why RUN cannot be resumed with RETURN."),
            Symbol(address: 0xA68E, name: "SETCUR", description: "Point TXTPTR ($7A/$7B) at TXTTAB-1, i.e. just before the first byte of the program.", category: .basicInternal,
                   notes: "Commodore label 'STXTPT'. CHRGET then fetches the program's first byte. Use it before JMPing to $A7AE to run a program from machine code."),
            Symbol(address: 0xA69C, name: "CMD_LIST", description: "LIST: detokenise and print program lines to the current output channel.", category: .basicCommand,
                   notes: "STMDSP stores $A69B (address-1)."),
            Symbol(address: 0xA717, name: "QPLOP", description: "LIST's token expander: turn the byte in A into its keyword. Vectored: JMP ($0306).", category: .basicInternal,
                   input: "A = byte from the program text",
                   notes: "Hook $0306 (IQPLOP) so LIST can spell out keywords you added to the tokeniser. The default handler is at $A71A."),
            Symbol(address: 0xA742, name: "CMD_FOR", description: "FOR: run the assignment, then push an 18-byte FOR frame (loop variable pointer, limit, step, line number, text pointer) onto the runtime stack.", category: .basicCommand,
                   notes: "Reuses an existing frame for the same variable, which is why re-entering a loop does not leak stack."),
            Symbol(address: 0xA7AE, name: "EXEC_NEXT", description: "The interpreter's inner loop: check STOP, advance to the next statement or line, then execute it.", category: .basicInternal,
                   notes: "Commodore label 'NEWSTT'. JMP here (after $A68E) to start running the program currently in memory.",
                   example: """
                   jsr $A68E          ; TXTPTR = start of program - 1
                   jmp $A7AE          ; RUN it
                   """),
            Symbol(address: 0xA7E1, name: "GONE", description: "Execute one BASIC statement. Vectored: JMP ($0308).", category: .basicInternal,
                   notes: "Hook $0308 (IGONE) to add your own statement keywords; the default handler is at $A7E4."),
            Symbol(address: 0xA7E4, name: "EXEC_STMT", description: "Default statement executor: fetch the next character, and if it is a command token dispatch through STMDSP ($A00C).", category: .basicInternal,
                   notes: "Commodore label 'NGONE'. Dispatch is done by pushing the table word and RTSing, which is why STMDSP holds handler addresses minus one."),
            Symbol(address: 0xA81D, name: "CMD_RESTORE", description: "RESTORE: reset the DATA pointer ($41/$42) to the start of the program.", category: .basicCommand,
                   notes: "STMDSP stores $A81C. C64 BASIC V2 has no RESTORE <line>."),
            Symbol(address: 0xA82C, name: "ISCNTC", description: "Test the STOP key via the KERNAL STOP routine and break out of the program if it is held down.", category: .basicInternal,
                   output: "Returns normally if STOP was not pressed",
                   notes: "Called from NEWSTT on every statement. Poking $0328/$0329 (ISTOP) elsewhere is the classic way to disable RUN/STOP."),
            Symbol(address: 0xA82F, name: "CMD_STOP", description: "STOP: set the carry flag and fall into END, which makes END report BREAK.", category: .basicCommand,
                   notes: "STMDSP stores $A82E."),
            Symbol(address: 0xA831, name: "CMD_END", description: "END: save TXTPTR and the line number for CONT, then return to READY (printing BREAK IN <line> if entered from STOP).", category: .basicCommand),
            Symbol(address: 0xA857, name: "CMD_CONT", description: "CONT: restore TXTPTR and the line number saved by STOP/END and resume execution.", category: .basicCommand,
                   notes: "STMDSP stores $A856. Raises ?CANT CONTINUE if the saved line number high byte is zero, which is what editing the program clears."),
            Symbol(address: 0xA871, name: "CMD_RUN", description: "RUN: clear variables (CLR), optionally jump to a line number, then start the interpreter loop.", category: .basicCommand),
            Symbol(address: 0xA883, name: "CMD_GOSUB", description: "GOSUB: push a 5-byte GOSUB frame (TXTPTR, line number, token $8D) then fall into GOTO.", category: .basicCommand),
            Symbol(address: 0xA8A0, name: "CMD_GOTO", description: "GOTO: read the line number, find it with FNDLIN, and point TXTPTR at it.", category: .basicCommand,
                   notes: "Searches from the start of the program for a target line lower than the current one, and from the current line forward otherwise -- which is why backwards GOTOs in long programs are slow."),
            Symbol(address: 0xA8D2, name: "CMD_RETURN", description: "RETURN: pop FOR frames until a GOSUB frame is on top, then restore TXTPTR and the line number from it.", category: .basicCommand,
                   notes: "Raises ?RETURN WITHOUT GOSUB if no GOSUB frame is found."),
            Symbol(address: 0xA8F8, name: "CMD_DATA", description: "DATA: skip the rest of the statement at run time.", category: .basicCommand),
            Symbol(address: 0xA906, name: "DATAN", description: "Scan forward for the end of the current statement, respecting quotes.", category: .basicInternal,
                   output: "Y = offset from TXTPTR to the terminating $00 or ':'",
                   notes: "Commodore label 'DATAN'; $A909 ('REMN') is the same scan without the ':' terminator, which is how REM swallows colons."),
            Symbol(address: 0xA928, name: "CMD_IF", description: "IF: evaluate the condition, then either execute the THEN clause or skip to the next line.", category: .basicCommand,
                   notes: "An IF whose condition is false skips the whole rest of the line, colons included."),
            Symbol(address: 0xA93B, name: "CMD_REM", description: "REM: skip to the end of the line.", category: .basicCommand),
            Symbol(address: 0xA94B, name: "CMD_ON", description: "ON ... GOTO / ON ... GOSUB: evaluate the index, skip that many commas, then dispatch.", category: .basicCommand,
                   notes: "An index of 0 or one larger than the list simply falls through to the next statement -- no error."),
            Symbol(address: 0xA96B, name: "LINGET", description: "Parse a decimal line number from BASIC text into $14/$15.", category: .basicInternal,
                   input: "TXTPTR points at the first digit",
                   output: "$14/$15 = the value; stops at the first non-digit",
                   registers: "A, X, Y",
                   notes: "Earlier versions of this table called this GETNUM; that name belongs to $B7EB. Values above 63999 raise ?SYNTAX ERROR later, in GOTO."),
            Symbol(address: 0xA9A5, name: "CMD_LET", description: "LET / implicit assignment: find the target variable with PTRGET, evaluate the expression, and store the result.", category: .basicCommand),
            Symbol(address: 0xAA80, name: "CMD_PRINT_N", description: "PRINT#: set the output channel from the logical file number, then fall into PRINT.", category: .basicCommand),
            Symbol(address: 0xAA86, name: "CMD_CMD", description: "CMD: redirect all subsequent PRINT output to a logical file until CLRCHN or PRINT# runs.", category: .basicCommand),
            Symbol(address: 0xAAA0, name: "CMD_PRINT", description: "PRINT: evaluate and print the expression list, honouring , and ; spacing and TAB()/SPC().", category: .basicCommand,
                   notes: "STMDSP stores $AA9F."),
            Symbol(address: 0xAAD7, name: "CRDO", description: "Print a carriage return, plus a line feed if the current channel is not the screen.", category: .basicInternal,
                   registers: "A, Y",
                   example: """
                   jsr $AAD7          ; newline on the current channel
                   """),
            Symbol(address: 0xAB1E, name: "STROUT_AY", description: "Print the $00-terminated string pointed to by A/Y on the current output channel.", category: .basicInternal,
                   input: "A = low byte, Y = high byte of the string address",
                   registers: "A, X, Y",
                   notes: "Commodore label 'STROUT'. The string is PETSCII and may contain control codes; a $00 ends it, and there is no length limit. Needs the BASIC ROM banked in -- $FFD2 in a loop is the ROM-independent alternative.",
                   example: """
                   lda #<msg
                   ldy #>msg
                   jsr $AB1E
                   ; ...
                   msg: .byte "HELLO", 13, 0
                   """),
            Symbol(address: 0xAB21, name: "STROUT", description: "Print the string described by the descriptor most recently built, freeing it afterwards.", category: .basicInternal,
                   input: "A = length, $22/$23 = pointer (as left by FREFAC)",
                   registers: "A, X, Y",
                   notes: "Commodore label 'STRPRT'. Unlike $AB1E this prints a counted string, so embedded $00 bytes are printed rather than ending it."),
            Symbol(address: 0xAB47, name: "OUTCHR", description: "Print the PETSCII character in A on the current output channel, tracking the print column.", category: .basicInternal,
                   input: "A = character",
                   registers: "A",
                   notes: "Commodore label 'OUTDO'. A thin wrapper over BASIC's CHROUT path at $E10C, so an I/O failure surfaces as a BASIC error rather than a silently set carry flag."),
            Symbol(address: 0xAB7B, name: "CMD_GET", description: "GET / GET#: read a single character without waiting.", category: .basicCommand,
                   notes: "Raises ?ILLEGAL DIRECT if used outside a program."),
            Symbol(address: 0xABA5, name: "CMD_INPUT_N", description: "INPUT#: read a line from a logical file into the variable list.", category: .basicCommand),
            Symbol(address: 0xABBF, name: "CMD_INPUT", description: "INPUT: print the optional prompt, read a line from the keyboard, then parse it into the variable list.", category: .basicCommand,
                   notes: "Prints ?REDO FROM START and re-reads the whole line when a numeric variable gets non-numeric text."),
            Symbol(address: 0xAC06, name: "CMD_READ", description: "READ: pull the next item from the DATA stream at ($41/$42) into the variable list.", category: .basicCommand,
                   notes: "Shares its parser with INPUT; $AC0F sets the flag that tells the two apart."),
            Symbol(address: 0xAD1E, name: "CMD_NEXT", description: "NEXT: find the FOR frame, add the step, test against the limit, and either loop or drop the frame.", category: .basicCommand,
                   notes: "The limit test is 'passed the limit', not 'equal to', so a FOR loop always runs its body at least once."),
        ])

        // ── Expression evaluation ────────────────────────
        s.append(contentsOf: [
            Symbol(address: 0xAD8A, name: "FRMNUM", description: "Evaluate an expression from BASIC text and insist the result is numeric.", category: .basicInternal,
                   input: "TXTPTR ($7A/$7B) points at the expression",
                   output: "FAC1 ($61-$66) = the value; TXTPTR points past the expression",
                   registers: "A, X, Y",
                   notes: "FRMEVL followed by CHKNUM. Raises ?TYPE MISMATCH on a string. This is the routine a SYS-called parameter reader normally wants.",
                   example: """
                   jsr $0073          ; CHRGET - step past the token
                   jsr $AD8A          ; FRMNUM - value now in FAC1
                   jsr $B7F7          ; GETADR - and as 16 bits in $14/$15
                   """),
            Symbol(address: 0xAD8D, name: "CHKNUM", description: "Raise ?TYPE MISMATCH unless the last evaluated expression was numeric.", category: .basicInternal,
                   input: "VALTYP ($0D): $00 numeric, $FF string",
                   registers: "A"),
            Symbol(address: 0xAD8F, name: "CHKSTR", description: "Raise ?TYPE MISMATCH unless the last evaluated expression was a string.", category: .basicInternal,
                   input: "VALTYP ($0D): $00 numeric, $FF string",
                   registers: "A"),
            Symbol(address: 0xAD9E, name: "FRMEVL", description: "Evaluate any BASIC expression, honouring operator precedence, parentheses, functions and relationals.", category: .basicInternal,
                   input: "TXTPTR ($7A/$7B) points at the expression",
                   output: "Numeric result in FAC1 ($61-$66), or a string descriptor with VALTYP ($0D) = $FF",
                   registers: "A, X, Y",
                   notes: "Recursive: deep expressions can raise ?FORMULA TOO COMPLEX. Use $AD8A instead when the result must be a number."),
            Symbol(address: 0xAE83, name: "GETVAL", description: "Evaluate one arithmetic element -- a constant, variable, function call or parenthesised subexpression. Vectored: JMP ($030A).", category: .basicInternal,
                   output: "FAC1 = the element's value",
                   notes: "Commodore label 'EVAL'. Hook $030A (IEVAL) to add your own unary functions; the default handler is at $AE86."),
            Symbol(address: 0xAEF1, name: "PARCHK", description: "Expect '(', evaluate an expression, then expect ')'.", category: .basicInternal,
                   output: "FAC1 = the parenthesised value",
                   notes: "The convenient front door for a user-defined function that takes one argument."),
            Symbol(address: 0xAEFA, name: "CHKOPN", description: "Raise ?SYNTAX ERROR unless the next character in BASIC text is '('.", category: .basicInternal),
            Symbol(address: 0xAEFD, name: "CHKCOM", description: "Raise ?SYNTAX ERROR unless the next character in BASIC text is a comma.", category: .basicInternal,
                   output: "On success TXTPTR has advanced and A holds the character after the comma",
                   example: """
                   jsr $AEFD          ; require a comma
                   jsr $B79E          ; then read a byte argument into X
                   """),
            Symbol(address: 0xAEFF, name: "SYNCHR", description: "Raise ?SYNTAX ERROR unless the next character in BASIC text equals the one in A; otherwise consume it via CHRGET.", category: .basicInternal,
                   input: "A = the character that must appear next",
                   output: "A = the following character, TXTPTR advanced",
                   registers: "A, Y",
                   notes: "$AEFA and $AEFD are just SYNCHR pre-loaded with '(' and ','."),
            Symbol(address: 0xAF08, name: "SYNERR", description: "Raise ?SYNTAX ERROR (error 11).", category: .basicInternal,
                   registers: "Does not return"),
            Symbol(address: 0xAF28, name: "GETVAR", description: "Fetch the value of the variable named at TXTPTR into FAC1 (or into a string descriptor).", category: .basicInternal,
                   notes: "Commodore label 'ISVAR'. Calls PTRGET, so referencing an unknown variable creates it with the value 0 or the empty string."),
        ])

        // ── Variables and arrays ─────────────────────────
        s.append(contentsOf: [
            Symbol(address: 0xB08B, name: "PTRGET", description: "Parse a variable name at TXTPTR and return a pointer to its value, creating the variable if it does not exist.", category: .basicInternal,
                   input: "TXTPTR points at the name",
                   output: "A/Y = pointer to the 5-byte value (or 3-byte string descriptor); also left in VARPNT ($47/$48)",
                   registers: "A, X, Y",
                   notes: "Only the first two characters of a name are significant. DIMFLG ($0C) and SUBFLG ($10) control whether array subscripts and DEF FN names are accepted.",
                   example: """
                   jsr $B08B          ; A/Y -> value of the named variable
                   sta $22
                   sty $23
                   """),
            Symbol(address: 0xB113, name: "ISALPHA", description: "Test whether the PETSCII character in A is a letter A-Z.", category: .basicInternal,
                   input: "A = character",
                   output: "Carry = 1 if it is a letter",
                   registers: "A",
                   notes: "Commodore label 'ISLETC'."),
            Symbol(address: 0xB1AA, name: "FLPINT", description: "Convert FAC1 to a signed 16-bit integer and return it in A/Y.", category: .floatingPoint,
                   input: "FAC1 = the value",
                   output: "A = high byte, Y = low byte; also at $64 (high) / $65 (low)",
                   registers: "A, X, Y",
                   notes: "Wrapper around AYINT ($B1BF). Raises ?ILLEGAL QUANTITY outside -32768..32767. Truncates toward zero."),
            Symbol(address: 0xB1BF, name: "AYINT", description: "Convert FAC1 to a signed 16-bit integer in $64 (high) / $65 (low), range-checking as it goes.", category: .floatingPoint,
                   input: "FAC1 = the value",
                   output: "$64/$65 = the integer, high byte first",
                   registers: "A, X, Y",
                   notes: "Raises ?ILLEGAL QUANTITY if |value| >= 32768. Note the big-endian storage order -- $B7F7 (GETADR) is the little-endian equivalent."),
            Symbol(address: 0xB1D1, name: "DIMVAR", description: "DIM: allocate an array from the subscript list at TXTPTR.", category: .basicInternal,
                   notes: "Commodore label 'ISARY'. Arrays default to a maximum subscript of 10 if used before being DIMmed."),
            Symbol(address: 0xB34C, name: "UMULT", description: "Unsigned 16-bit multiply used to turn array subscripts into a byte offset.", category: .basicInternal,
                   registers: "A, X, Y"),
            Symbol(address: 0xB37D, name: "FN_FRE", description: "FRE(): garbage-collect, then return the number of free bytes between the end of arrays and the bottom of string space.", category: .basicFunction,
                   output: "FAC1 = free bytes, as a signed value (subtract from 65536 when negative)",
                   notes: "The famous negative result: BASIC V2 floats the 16-bit count as signed, so anything above 32767 free comes back negative."),
            Symbol(address: 0xB391, name: "GIVAYF", description: "Convert the signed 16-bit integer in A (high) / Y (low) to floating point in FAC1.", category: .floatingPoint,
                   input: "A = high byte, Y = low byte",
                   output: "FAC1 = the value, VALTYP ($0D) set to numeric",
                   registers: "A, X, Y",
                   notes: "Note the unusual order: A is the HIGH byte. This is the standard way to hand a 16-bit result back to BASIC from a USR() routine.",
                   example: """
                   lda #>1234         ; return 1234 to BASIC
                   ldy #<1234
                   jsr $B391          ; FAC1 = 1234
                   rts                ; USR() picks it up from FAC1
                   """),
            Symbol(address: 0xB39E, name: "FN_POS", description: "POS(): return the cursor column of the current output channel.", category: .basicFunction,
                   output: "FAC1 = column (0-39 on the screen)"),
            Symbol(address: 0xB3A6, name: "CHKDIR", description: "Raise ?ILLEGAL DIRECT if BASIC is in direct mode rather than running a program.", category: .basicInternal,
                   notes: "Commodore label 'ERRDIR'. Direct mode is flagged by CURLIN+1 ($3A) = $FF."),
            Symbol(address: 0xB3B3, name: "CMD_DEF", description: "DEF FN: parse the definition and store the argument pointer and expression address in the FN variable.", category: .basicCommand),
            Symbol(address: 0xB3F4, name: "FN_CALL", description: "Evaluate a call to a user-defined FN: save the argument variable, substitute the actual argument, evaluate the stored expression, then restore.", category: .basicInternal,
                   notes: "Commodore label 'FNDOER'. Raises ?UNDEF'D FUNCTION if the FN was never DEFed."),
        ])

        // ── Strings ──────────────────────────────────────
        s.append(contentsOf: [
            Symbol(address: 0xB465, name: "FN_STR", description: "STR$(): format the number in FAC1 as a string, with a leading space for positive values.", category: .basicFunction,
                   input: "FAC1 = the number",
                   output: "A temporary string descriptor; VALTYP ($0D) = $FF"),
            Symbol(address: 0xB47D, name: "STRALLOC", description: "Reserve A bytes at the bottom of string space.", category: .stringHandling,
                   input: "A = number of bytes",
                   output: "FRESPC ($35/$36) = address of the new block; a descriptor is pushed on the temporary stack",
                   registers: "A, X, Y",
                   notes: "Commodore label 'STRSPA'. Triggers garbage collection, and then ?OUT OF MEMORY, when string space is exhausted."),
            Symbol(address: 0xB487, name: "STRDESC", description: "Build a temporary descriptor for a string literal sitting in memory.", category: .stringHandling,
                   input: "A = low byte, Y = high byte of the text; the string ends at $00 or a double quote",
                   output: "Descriptor pushed on the temporary-string stack, pointer in $64/$65, length in A",
                   registers: "A, X, Y",
                   notes: "Commodore label 'STRLIT'. This is how a machine-code routine hands a string back to BASIC."),
            Symbol(address: 0xB4CA, name: "STRSAV", description: "Push the descriptor built in $61-$63 onto the temporary-string descriptor stack.", category: .stringHandling,
                   notes: "Commodore label 'PUTNEW'. There is room for three temporaries; overflow raises ?FORMULA TOO COMPLEX."),
            Symbol(address: 0xB526, name: "GARBAG", description: "Garbage-collect string space: compact all live strings toward the top of memory and reclaim the rest.", category: .memoryManage,
                   registers: "A, X, Y",
                   notes: "The BASIC V2 collector is O(n^2) in the number of string variables, which is why a program with thousands of strings can appear to hang for tens of seconds.",
                   example: """
                   jsr $B526          ; force a collection now
                   """),
            Symbol(address: 0xB63D, name: "STRCAT", description: "Concatenate two strings for the + operator.", category: .stringHandling,
                   notes: "Commodore label 'CAT'. Raises ?STRING TOO LONG if the result exceeds 255 characters."),
            Symbol(address: 0xB67A, name: "STRMOV", description: "Copy a string into freshly allocated string space, then discard the source temporary.", category: .stringHandling,
                   notes: "Commodore label 'MOVINS'."),
            Symbol(address: 0xB688, name: "STRMOV_AXY", description: "Copy A bytes from the address in X (low) / Y (high) to the block at FRESPC ($35/$36).", category: .stringHandling,
                   input: "A = length, X/Y = source address",
                   registers: "A, X, Y",
                   notes: "Commodore label 'MOVSTR'."),
            Symbol(address: 0xB6A3, name: "FRESTR", description: "Check that the last expression was a string, then free its temporary descriptor.", category: .stringHandling,
                   output: "A = length, $22/$23 = pointer to the text",
                   registers: "A, X, Y",
                   notes: "Raises ?TYPE MISMATCH on a numeric value. $B6A6 (FREFAC) is the same routine without the type check."),
            Symbol(address: 0xB6A6, name: "FREFAC", description: "Free the temporary string described in FAC1 and return its length and address.", category: .stringHandling,
                   output: "A = length, $22/$23 = pointer to the text",
                   registers: "A, X, Y",
                   notes: "Commodore label 'FREFAC'. The classic way to read a string argument in a BASIC extension.",
                   example: """
                   jsr $AD9E          ; FRMEVL - evaluate the argument
                   jsr $B6A3          ; FRESTR - insist it is a string
                   tax                ; X = length
                   ldy #$00
                   lda ($22),y        ; first character
                   """),
            Symbol(address: 0xB6EC, name: "FN_CHR", description: "CHR$(): build a one-character string from a value 0-255.", category: .basicFunction,
                   input: "The argument in FAC1",
                   notes: "Raises ?ILLEGAL QUANTITY above 255."),
            Symbol(address: 0xB700, name: "FN_LEFT", description: "LEFT$(): return the first N characters of a string.", category: .basicFunction),
            Symbol(address: 0xB72C, name: "FN_RIGHT", description: "RIGHT$(): return the last N characters of a string.", category: .basicFunction),
            Symbol(address: 0xB737, name: "FN_MID", description: "MID$(): return N characters starting at position P (1-based).", category: .basicFunction,
                   notes: "A start position of 0 raises ?ILLEGAL QUANTITY."),
            Symbol(address: 0xB77C, name: "FN_LEN", description: "LEN(): return the length of a string.", category: .basicFunction,
                   output: "FAC1 = length 0-255"),
            Symbol(address: 0xB78B, name: "FN_ASC", description: "ASC(): return the PETSCII code of a string's first character.", category: .basicFunction,
                   notes: "Raises ?ILLEGAL QUANTITY on the empty string -- unlike later BASICs, which return 0."),
        ])

        // ── Numeric argument helpers ─────────────────────
        s.append(contentsOf: [
            Symbol(address: 0xB79E, name: "GETBYT", description: "Evaluate an expression from BASIC text and return it as a byte in X.", category: .basicInternal,
                   input: "TXTPTR points at the expression",
                   output: "X = value 0-255, A = the character that terminated the expression",
                   registers: "A, X, Y",
                   notes: "FRMNUM followed by CONINT. Raises ?ILLEGAL QUANTITY above 255. The standard way to read a byte parameter in a SYS or a BASIC extension.",
                   example: """
                   jsr $AEFD          ; CHKCOM - require a comma
                   jsr $B79E          ; GETBYT - X = the byte
                   stx $D020          ; ...use it
                   """),
            Symbol(address: 0xB7A1, name: "CONINT", description: "Convert the value already in FAC1 to a byte in X.", category: .basicInternal,
                   input: "FAC1 = the value",
                   output: "X = value 0-255",
                   registers: "A, X, Y",
                   notes: "Raises ?ILLEGAL QUANTITY if negative or above 255."),
            Symbol(address: 0xB7AD, name: "FN_VAL", description: "VAL(): parse the leading number out of a string.", category: .basicFunction,
                   output: "FAC1 = the value, or 0 if the string does not start with a number"),
            Symbol(address: 0xB7EB, name: "GETNUM", description: "Read a 16-bit address into $14/$15, then a comma, then a byte into X.", category: .basicInternal,
                   input: "TXTPTR points at the first expression",
                   output: "$14/$15 = the address (low/high), X = the byte",
                   registers: "A, X, Y",
                   notes: "Commodore label 'GETNUM'. This is the argument reader POKE and WAIT share. Earlier versions of this table called it GETADR; the real GETADR is at $B7F7."),
            Symbol(address: 0xB7F1, name: "COMBYT", description: "Require a comma, then evaluate a byte argument into X.", category: .basicInternal,
                   output: "X = value 0-255",
                   registers: "A, X, Y"),
            Symbol(address: 0xB7F7, name: "GETADR", description: "Convert FAC1 to an unsigned 16-bit address in $14/$15.", category: .basicInternal,
                   input: "FAC1 = the value, 0..65535",
                   output: "$14 = low byte, $15 = high byte; also A = high byte, Y = low byte",
                   registers: "A, X, Y",
                   notes: "Raises ?ILLEGAL QUANTITY if negative or >= 65536. Little-endian in memory, unlike AYINT ($B1BF) which stores high byte first at $64/$65.",
                   example: """
                   jsr $AD8A          ; FRMNUM - evaluate the argument
                   jsr $B7F7          ; GETADR - $14/$15 = address
                   ldy #$00
                   lda ($14),y        ; read that byte
                   """),
            Symbol(address: 0xB80D, name: "FN_PEEK", description: "PEEK(): read one byte from memory.", category: .basicFunction,
                   notes: "Reads with the current $01 banking, so PEEK($D000) sees the VIC register, not the character ROM."),
            Symbol(address: 0xB824, name: "CMD_POKE", description: "POKE: write a byte to memory.", category: .basicCommand),
            Symbol(address: 0xB82D, name: "CMD_WAIT", description: "WAIT: spin until (PEEK(addr) XOR mask2) AND mask1 is non-zero.", category: .basicCommand,
                   notes: "Commodore label 'FNWAIT'. With no third argument mask2 is 0. A WAIT on a condition that never comes true can only be broken by RESTORE, since it does not test the STOP key."),
        ])

        // ══════════════════════════════════════════════════
        // Floating-point package
        // FAC1 = $61-$66, FAC2/ARG = $69-$6E, FACOV = $70.
        // Routines that take a 'float at A/Y' expect A = low byte
        // and Y = high byte of a 5-byte packed float.
        // ══════════════════════════════════════════════════
        s.append(contentsOf: [
            Symbol(address: 0xB849, name: "FADDH", description: "Add 0.5 to FAC1.", category: .floatingPoint,
                   output: "FAC1 = FAC1 + 0.5",
                   registers: "A, X, Y",
                   notes: "Used by INT() to round rather than truncate."),
            Symbol(address: 0xB850, name: "FSUB", description: "Load the float at A/Y into FAC2, then compute FAC1 = FAC2 - FAC1.", category: .floatingPoint,
                   input: "A/Y = pointer to a 5-byte float, FAC1 = the subtrahend",
                   output: "FAC1 = *(A/Y) - FAC1",
                   registers: "A, X, Y",
                   notes: "Note the operand order -- the value in FAC1 is subtracted FROM the one in memory."),
            Symbol(address: 0xB853, name: "FSUBT", description: "FAC1 = FAC2 - FAC1, with both operands already loaded.", category: .floatingPoint,
                   output: "FAC1 = FAC2 - FAC1",
                   registers: "A, X, Y"),
            Symbol(address: 0xB867, name: "FADD_AY", description: "Load the float at A/Y into FAC2, then add: FAC1 = FAC1 + FAC2.", category: .floatingPoint,
                   input: "A/Y = pointer to a 5-byte float",
                   output: "FAC1 = FAC1 + *(A/Y)",
                   registers: "A, X, Y",
                   example: """
                   lda #<value        ; FAC1 = FAC1 + value
                   ldy #>value
                   jsr $B867
                   """),
            Symbol(address: 0xB86A, name: "FADD", description: "FAC1 = FAC1 + FAC2, with both operands already loaded.", category: .floatingPoint,
                   output: "FAC1 = FAC1 + FAC2",
                   registers: "A, X, Y",
                   notes: "Commodore label 'FADDT'."),
            Symbol(address: 0xB8F7, name: "FZERO", description: "Set FAC1 to zero by clearing its exponent.", category: .floatingPoint,
                   output: "FAC1 = 0",
                   registers: "A",
                   notes: "Commodore label 'ZEROFC'. A zero exponent is what makes a float zero, so the mantissa is left alone."),
            Symbol(address: 0xB947, name: "NEGFAC", description: "Negate FAC1 by flipping its sign byte.", category: .floatingPoint,
                   output: "FAC1 = -FAC1",
                   registers: "A",
                   notes: "Negating zero leaves it zero because the sign byte is ignored when the exponent is 0."),
            Symbol(address: 0xB97E, name: "OVERR", description: "Raise ?OVERFLOW (error 15).", category: .floatingPoint,
                   registers: "Does not return"),
            Symbol(address: 0xB9EA, name: "FN_LOG", description: "LOG(): natural logarithm of FAC1.", category: .basicFunction,
                   notes: "Raises ?ILLEGAL QUANTITY for arguments <= 0."),
            Symbol(address: 0xBA28, name: "FMULT", description: "Load the float at A/Y into FAC2, then multiply: FAC1 = FAC1 * FAC2.", category: .floatingPoint,
                   input: "A/Y = pointer to a 5-byte float",
                   output: "FAC1 = FAC1 * *(A/Y)",
                   registers: "A, X, Y",
                   notes: "Commodore label 'FMULT'. This is the entry that takes a memory operand; $BA2B skips the load."),
            Symbol(address: 0xBA2B, name: "FMULTT", description: "FAC1 = FAC1 * FAC2, with both operands already loaded.", category: .floatingPoint,
                   output: "FAC1 = FAC1 * FAC2",
                   registers: "A, X, Y"),
            Symbol(address: 0xBA8C, name: "CONUPK", description: "Load the 5-byte float at A/Y into FAC2 (ARG), unpacking the implicit mantissa bit.", category: .floatingPoint,
                   input: "A = low byte, Y = high byte of the float's address",
                   output: "FAC2 ($69-$6E) = the value; $6F = FAC1 sign XOR FAC2 sign",
                   registers: "A, X, Y",
                   notes: "Commodore label 'CONUPK'. Older versions of this table listed it as LDARG_AY. Use it to preload the dividend before FDIVT ($BB12)."),
            Symbol(address: 0xBAE2, name: "FMUL10", description: "Multiply FAC1 by 10.", category: .floatingPoint,
                   output: "FAC1 = FAC1 * 10",
                   registers: "A, X, Y",
                   notes: "Commodore label 'MUL10'. Faster and shorter than loading a constant and calling FMULT."),
            Symbol(address: 0xBAFE, name: "FDIV10", description: "Divide FAC1 by 10.", category: .floatingPoint,
                   output: "FAC1 = FAC1 / 10",
                   registers: "A, X, Y"),
            Symbol(address: 0xBB0F, name: "FDIV_AY", description: "Load the float at A/Y into FAC2, then divide: FAC1 = FAC2 / FAC1.", category: .floatingPoint,
                   input: "A/Y = pointer to the dividend, FAC1 = the divisor",
                   output: "FAC1 = *(A/Y) / FAC1",
                   registers: "A, X, Y",
                   notes: "Note the operand order -- FAC1 is the DIVISOR. Raises ?DIVISION BY ZERO if FAC1 is zero."),
            Symbol(address: 0xBB12, name: "FDIV", description: "FAC1 = FAC2 / FAC1, with both operands already loaded.", category: .floatingPoint,
                   output: "FAC1 = FAC2 / FAC1",
                   registers: "A, X, Y",
                   notes: "Commodore label 'FDIVT'. Preload the dividend into FAC2 with CONUPK ($BA8C)."),
            Symbol(address: 0xBBA2, name: "LDFAC_AY", description: "Load the 5-byte float at A/Y into FAC1.", category: .floatingPoint,
                   input: "A = low byte, Y = high byte of the float's address",
                   output: "FAC1 = the value",
                   registers: "A, X, Y",
                   notes: "Commodore label 'MOVFM'.",
                   example: """
                   lda #<value        ; FAC1 = value
                   ldy #>value
                   jsr $BBA2
                   """),
            Symbol(address: 0xBBC7, name: "STFAC_TEMP", description: "Round FAC1 and store it in BASIC's second temporary float area (TEMPF2).", category: .floatingPoint,
                   notes: "Commodore label 'MOV2F'; $BBCA ('MOV1F') is the same for TEMPF1. Used by the polynomial evaluator."),
            Symbol(address: 0xBBD0, name: "STFAC_FORPNT", description: "Round FAC1 and store it at the address held in FORPNT ($49/$4A).", category: .floatingPoint,
                   input: "$49/$4A = destination address",
                   registers: "A, X, Y",
                   notes: "Commodore label 'MOVVF'. Earlier versions of this table described this as the X/Y form -- that is $BBD4."),
            Symbol(address: 0xBBD4, name: "STFAC_XY", description: "Round FAC1 and store it as a 5-byte float at the address in X (low) / Y (high).", category: .floatingPoint,
                   input: "X = low byte, Y = high byte of the destination",
                   registers: "A, X, Y",
                   notes: "Commodore label 'MOVMF'. Rounds via $BC1B first, so the stored value can differ in the last bit from FAC1's raw mantissa.",
                   example: """
                   ldx #<value        ; value = FAC1
                   ldy #>value
                   jsr $BBD4
                   """),
            Symbol(address: 0xBBFC, name: "LDFAC_ARG", description: "Copy FAC2 (ARG) into FAC1.", category: .floatingPoint,
                   registers: "A, X",
                   notes: "Commodore label 'MOVFA'."),
            Symbol(address: 0xBC0C, name: "STFAC_ARG", description: "Round FAC1, then copy it into FAC2 (ARG).", category: .floatingPoint,
                   registers: "A, X",
                   notes: "Commodore label 'MOVAF'. $BC0F ('MOVEF') is the same copy without the rounding step."),
            Symbol(address: 0xBC1B, name: "ROUND", description: "Round FAC1 using its overflow byte FACOV ($70).", category: .floatingPoint,
                   output: "FAC1 rounded; FACOV cleared",
                   registers: "A",
                   notes: "Commodore label 'ROUND'. Earlier versions of this table listed $BC1B as the sign routine -- that is $BC2B."),
            Symbol(address: 0xBC2B, name: "SIGN", description: "Return the sign of FAC1 in A.", category: .floatingPoint,
                   output: "A = $01 if positive, $00 if zero, $FF if negative (N and Z set to match)",
                   registers: "A",
                   notes: "Commodore label 'SIGN'.",
                   example: """
                   jsr $BC2B          ; A = -1 / 0 / +1
                   bmi negative
                   """),
            Symbol(address: 0xBC39, name: "FN_SGN", description: "SGN(): replace FAC1 with -1, 0 or +1 according to its sign.", category: .basicFunction),
            Symbol(address: 0xBC3C, name: "FLOAT", description: "Convert the signed 8-bit value in A to floating point in FAC1.", category: .floatingPoint,
                   input: "A = signed byte, -128..127",
                   output: "FAC1 = the value",
                   registers: "A, X, Y",
                   notes: "The value is treated as SIGNED. For an unsigned 0-255 byte, clear Y and call GIVAYF ($B391) with A=0, Y=the byte -- or load A=0 first.",
                   example: """
                   ; an UNSIGNED byte (0-255) -> FAC1:
                   lda #$00           ; high byte = 0
                   ldy $D012          ; low byte = the value
                   jsr $B391          ; GIVAYF
                   """),
            Symbol(address: 0xBC44, name: "FLOATS", description: "Convert the signed 16-bit value already in $62/$63 (high/low) to floating point, with X preset to the exponent.", category: .floatingPoint,
                   notes: "Commodore label 'FLOATS'. An internal entry point; call GIVAYF ($B391) instead unless you know the exponent convention."),
            Symbol(address: 0xBC4F, name: "FLOATB", description: "Final stage of the integer-to-float conversion: store X as the exponent and normalise.", category: .floatingPoint,
                   notes: "Commodore label 'FLOATB'. Internal; earlier versions of this table mislabelled it GIVAYF, which is at $B391."),
            Symbol(address: 0xBC58, name: "FN_ABS", description: "ABS(): clear FAC1's sign byte.", category: .basicFunction,
                   registers: "A"),
            Symbol(address: 0xBC5B, name: "FCOMP", description: "Compare FAC1 with the 5-byte float at A/Y.", category: .floatingPoint,
                   input: "A = low byte, Y = high byte of the float's address",
                   output: "A = $00 if equal, $01 if FAC1 is greater, $FF if FAC1 is smaller (N and Z set to match)",
                   registers: "A, X, Y",
                   notes: "Commodore label 'FCOMP'. FAC1 is left unchanged. Earlier versions of this table put FCOMP at $BC2B, which is really SIGN.",
                   example: """
                   lda #<limit        ; if FAC1 > limit ...
                   ldy #>limit
                   jsr $BC5B
                   cmp #$01
                   beq greater
                   """),
            Symbol(address: 0xBC9B, name: "QINT", description: "Truncate FAC1 to a 32-bit integer in $62-$65, high byte first.", category: .floatingPoint,
                   output: "$62-$65 = the integer, MSB first",
                   registers: "A, X, Y",
                   notes: "Commodore label 'QINT'. No range check -- AYINT ($B1BF) and GETADR ($B7F7) add one."),
            Symbol(address: 0xBCCC, name: "FN_INT", description: "INT(): truncate FAC1 toward minus infinity.", category: .basicFunction,
                   notes: "INT(-2.5) is -3, not -2."),
            Symbol(address: 0xBCF3, name: "ASCFLT", description: "Parse an ASCII decimal number from BASIC text into FAC1, accepting a sign, a decimal point and an E exponent.", category: .floatingPoint,
                   input: "TXTPTR ($7A/$7B) points at the number, A = its first digit",
                   output: "FAC1 = the value, TXTPTR advanced past the number",
                   registers: "A, X, Y",
                   notes: "Commodore label 'FIN'. This is what VAL() and the tokeniser both use."),
            Symbol(address: 0xBDC2, name: "INPRT", description: "Print ' IN ' followed by the current BASIC line number.", category: .basicInternal,
                   input: "CURLIN ($39/$3A) = the line number",
                   registers: "A, X, Y",
                   notes: "Commodore label 'INPRT'. Part of the error reporter -- it is not a general integer printer; that is LINPRT at $BDCD."),
            Symbol(address: 0xBDCD, name: "LINPRT", description: "Print the unsigned 16-bit integer in A (high) / X (low) as decimal, with no leading spaces.", category: .floatingPoint,
                   input: "A = high byte, X = low byte",
                   registers: "A, X, Y",
                   notes: "Note the register order: A is the HIGH byte. Handy for printing scores and counters from machine code.",
                   example: """
                   lda score+1        ; print a 16-bit score
                   ldx score
                   jsr $BDCD
                   """),
            Symbol(address: 0xBDDD, name: "FOUT", description: "Convert FAC1 to a $00-terminated PETSCII decimal string in the buffer at $0100.", category: .floatingPoint,
                   input: "FAC1 = the value",
                   output: "A = $00, Y = $01 (a pointer to $0100); the string is at $0100",
                   registers: "A, X, Y",
                   notes: "Commodore label 'FOUT'. It formats, it does not print -- follow it with STROUT ($AB1E). Positive numbers get a leading space. The buffer overlaps the 6502 stack page, which is safe only because BASIC keeps the stack pointer high.",
                   example: """
                   jsr $BDDD          ; FAC1 -> string at $0100
                   jsr $AB1E          ; ...and print it (A/Y already set)
                   """),
            Symbol(address: 0xBDDF, name: "FOUTC", description: "FOUT entry point that expects Y to already hold the buffer index.", category: .floatingPoint,
                   notes: "Internal; use $BDDD."),
            Symbol(address: 0xBF71, name: "FN_SQR", description: "SQR(): square root of FAC1, computed as FAC1^0.5.", category: .basicFunction,
                   notes: "Raises ?ILLEGAL QUANTITY for negative arguments."),
            Symbol(address: 0xBF7B, name: "FPWRT", description: "FAC1 = FAC2 ^ FAC1.", category: .floatingPoint,
                   input: "FAC2 = the base, FAC1 = the exponent",
                   output: "FAC1 = FAC2 raised to the power in FAC1",
                   registers: "A, X, Y",
                   notes: "Commodore label 'FPWRT'. Implemented as EXP(exponent * LOG(base)), so it is slow and inexact; a negative base is only legal with an integral exponent."),
            Symbol(address: 0xBFED, name: "FN_EXP", description: "EXP(): e raised to the power in FAC1.", category: .basicFunction,
                   notes: "The routine continues past the end of the BASIC ROM into $E000, which is why the KERNAL ROM opens with BASIC code."),
        ])

        // ══════════════════════════════════════════════════
        // KERNAL ROM $E000-$FFFF
        // ══════════════════════════════════════════════════

        // ── BASIC code that spilled into the KERNAL ROM ──
        s.append(contentsOf: [
            Symbol(address: 0xE000, name: "EXP_CONT", description: "Continuation of the BASIC EXP() routine, which starts at $BFED and runs off the end of the BASIC ROM.", category: .floatingPoint,
                   notes: "Commodore label 'STOLD'. Both ROMs must be banked in for EXP, SQR and the trig functions to work."),
            Symbol(address: 0xE043, name: "POLYX", description: "Evaluate an odd-power polynomial: result = x * (c0 + c1*x^2 + c2*x^4 + ...).", category: .floatingPoint,
                   input: "FAC1 = x, A/Y = pointer to a coefficient table (count byte, then 5-byte floats, highest power first)",
                   output: "FAC1 = the result",
                   registers: "A, X, Y",
                   notes: "Used by SIN, TAN and ATN. A ready-made polynomial engine if you need one."),
            Symbol(address: 0xE059, name: "POLY", description: "Evaluate a general polynomial: result = c0 + c1*x + c2*x^2 + ...", category: .floatingPoint,
                   input: "FAC1 = x, A/Y = pointer to a coefficient table (count byte, then 5-byte floats, highest power first)",
                   output: "FAC1 = the result",
                   registers: "A, X, Y",
                   notes: "Used by EXP and LOG."),
            Symbol(address: 0xE097, name: "FN_RND", description: "RND(): pseudo-random number generator.", category: .basicFunction,
                   input: "FAC1 = the argument: >0 next in sequence, 0 seed from the CIA #1 timers, <0 reseed from the argument",
                   output: "FAC1 = a value in [0,1)",
                   notes: "RND(0) reads CIA #1 timer A and B, so it is only as random as the moment you call it. The seed lives at $008B-$008F."),
            Symbol(address: 0xE10C, name: "BSOUT", description: "BASIC's wrapper around CHROUT: print A, and raise the matching BASIC error if the KERNAL reports one.", category: .kernalIO,
                   input: "A = character",
                   notes: "Commodore label 'OUTCH'. Machine code should normally call $FFD2 directly; this entry exists so BASIC gets ?DEVICE NOT PRESENT instead of a silent carry."),
            Symbol(address: 0xE112, name: "BASIN", description: "BASIC's wrapper around CHRIN, with KERNAL errors turned into BASIC errors.", category: .kernalIO,
                   output: "A = character read",
                   notes: "Commodore label 'INCHR'."),
            Symbol(address: 0xE118, name: "COOUT", description: "BASIC's wrapper around CHKOUT: set the output channel and convert KERNAL errors to BASIC errors.", category: .kernalIO,
                   input: "X = logical file number",
                   notes: "Commodore label 'COOUT'. Earlier versions of this table described this as 'setup for character output'."),
            Symbol(address: 0xE11E, name: "COIN", description: "BASIC's wrapper around CHKIN: set the input channel and convert KERNAL errors to BASIC errors.", category: .kernalIO,
                   input: "X = logical file number",
                   notes: "Commodore label 'COIN'."),
            Symbol(address: 0xE124, name: "CGETL", description: "BASIC's wrapper around GETIN, with KERNAL errors turned into BASIC errors.", category: .kernalIO,
                   output: "A = character, or 0 if none is waiting",
                   notes: "Commodore label 'CGETL'."),
            Symbol(address: 0xE12A, name: "CMD_SYS", description: "SYS: load A, X, Y and the status register from $030C-$030F, JSR to the address, then store the registers back.", category: .basicCommand,
                   input: "$030C = A, $030D = X, $030E = Y, $030F = P",
                   output: "The same locations hold the register values the routine returned",
                   notes: "STMDSP stores $E129. Your routine must end in RTS. Passing parameters through $030C-$030F is the only register interface SYS offers; everything else has to go through POKE or a parameter list.",
                   example: """
                   ; BASIC: POKE 780,65 : SYS 65490   (CHROUT 'A')
                   ; 780 = $030C = A, 781 = $030D = X, 782 = $030E = Y
                   """),
            Symbol(address: 0xE156, name: "CMD_SAVE", description: "SAVE: collect the filename and device parameters, then call the KERNAL SAVE.", category: .basicCommand,
                   notes: "STMDSP stores $E155."),
            Symbol(address: 0xE165, name: "CMD_VERIFY", description: "VERIFY: set the verify flag, then fall into LOAD.", category: .basicCommand,
                   notes: "STMDSP stores $E164."),
            Symbol(address: 0xE168, name: "CMD_LOAD", description: "LOAD: collect the parameters, call the KERNAL LOAD, then relink the program and CLR if it loaded into BASIC text.", category: .basicCommand,
                   notes: "STMDSP stores $E167. LOAD from inside a running program restarts it with the variables intact -- the classic BASIC chaining trick."),
            Symbol(address: 0xE1BE, name: "CMD_OPEN", description: "OPEN: collect the logical file, device and secondary address plus the filename, then call the KERNAL OPEN.", category: .basicCommand,
                   notes: "STMDSP stores $E1BD."),
            Symbol(address: 0xE1C7, name: "CMD_CLOSE", description: "CLOSE: close the logical file given by the argument.", category: .basicCommand,
                   notes: "STMDSP stores $E1C6."),
            Symbol(address: 0xE264, name: "FN_COS", description: "COS(): add pi/2 to FAC1 and fall into SIN.", category: .basicFunction),
            Symbol(address: 0xE26B, name: "FN_SIN", description: "SIN(): sine of FAC1, in radians, via range reduction and a polynomial.", category: .basicFunction),
            Symbol(address: 0xE2B4, name: "FN_TAN", description: "TAN(): tangent of FAC1, computed as SIN/COS.", category: .basicFunction,
                   notes: "Raises ?DIVISION BY ZERO at odd multiples of pi/2."),
            Symbol(address: 0xE30E, name: "FN_ATN", description: "ATN(): arctangent of FAC1, in radians.", category: .basicFunction),
            Symbol(address: 0xE37B, name: "WARM_ENTRY", description: "Warm-start BASIC: close all channels, reset the runtime stack, enable interrupts, then report BREAK and return to READY.", category: .kernalInternal,
                   notes: "Commodore label 'PANIC'. This is where the NMI handler goes when RUN/STOP+RESTORE is pressed, and where BRK ends up. The word at $A002 points here.",
                   example: """
                   jmp $E37B          ; abandon everything, back to READY.
                   """),
            Symbol(address: 0xE386, name: "READY_ERR", description: "Error/READY entry: load X with $80 and jump through IERROR ($0300), which prints READY. without an error message.", category: .kernalInternal,
                   notes: "Commodore label 'READY'."),
            Symbol(address: 0xE394, name: "COLD_START", description: "BASIC cold start: initialise the BASIC vectors and zero page, clear memory, print the power-up banner, then drop into READY.", category: .kernalInternal,
                   notes: "Commodore label 'INIT'. The word at $A000 points here, and the KERNAL reset code jumps here once the hardware is up.",
                   example: """
                   jmp $E394          ; full BASIC restart (loses the program)
                   """),
            Symbol(address: 0xE3A2, name: "CHRGET_IMAGE", description: "The ROM master copy of the CHRGET routine that gets copied into zero page at $0073-$008A during cold start.", category: .romTable,
                   notes: "CHRGET ($0073) fetches the next BASIC text byte and sets Z for ':' or end-of-line and C for a digit; CHRGOT ($0079) re-reads the current one. TXTPTR is the operand at $007A/$007B. Patching the zero-page copy is the classic way to hook the interpreter."),
            Symbol(address: 0xE3BF, name: "INIT_BASIC_RAM", description: "Initialise BASIC's zero page and page 3 vectors, set TXTTAB to $0801, and clear the program.", category: .kernalInternal,
                   notes: "Commodore label 'INITCZ'."),
            Symbol(address: 0xE422, name: "INIT_MSG", description: "Print the power-up banner and the free-memory count.", category: .kernalInternal,
                   notes: "Commodore label 'INITMS'."),
            Symbol(address: 0xE447, name: "BVTRS", description: "Table of default BASIC vectors, copied to $0300-$030B at cold start.", category: .romTable,
                   notes: "In order: IERROR $0300, IMAIN $0302, ICRNCH $0304, IQPLOP $0306, IGONE $0308, IEVAL $030A."),
            Symbol(address: 0xE453, name: "INITV", description: "Copy the six default BASIC vectors from $E447 into $0300-$030B.", category: .kernalInternal,
                   registers: "A, Y",
                   notes: "Call this to undo a botched vector patch without a full cold start.",
                   example: """
                   jsr $E453          ; restore $0300-$030B
                   """),
        ])

        // ── Screen editor ────────────────────────────────
        s.append(contentsOf: [
            Symbol(address: 0xE500, name: "IOBASE_INT", description: "Return the CIA #1 base address in X/Y. The routine behind $FFF3.", category: .kernalInternal,
                   output: "X = $00, Y = $DC"),
            Symbol(address: 0xE505, name: "SCREEN_INT", description: "Return the screen size in X/Y. The routine behind $FFED.", category: .kernalInternal,
                   output: "X = 40 columns, Y = 25 rows",
                   notes: "Commodore label 'SCRORG'. Hard-coded on the C64; on the C128 and Plus/4 it reports the real geometry, which is why portable code should call it rather than assume 40x25."),
            Symbol(address: 0xE50A, name: "PLOT_INT", description: "Read or set the cursor position. The routine behind $FFF0.", category: .kernalInternal,
                   input: "Carry = 1 to read, Carry = 0 to set with X = row, Y = column",
                   output: "When reading: X = row (0-24), Y = column (0-39)",
                   notes: "Note that X is the ROW, not the column."),
            Symbol(address: 0xE518, name: "CINT", description: "Initialise the screen editor: VIC registers, screen and colour pointers, keyboard tables, then clear the screen.", category: .kernalEditor,
                   registers: "A, X, Y",
                   notes: "The routine behind $FF81."),
            Symbol(address: 0xE544, name: "CLRSCR", description: "Clear the screen and home the cursor.", category: .kernalEditor,
                   registers: "A, X, Y",
                   notes: "Commodore label 'CLSR'. Fills the screen with spaces in the current character colour. Printing CHR$(147) via $FFD2 does the same thing without needing the KERNAL entry point.",
                   example: """
                   jsr $E544          ; clear screen
                   ; or, portably:
                   lda #$93
                   jsr $FFD2
                   """),
            Symbol(address: 0xE566, name: "HOME", description: "Move the cursor to the top left of the screen without clearing it.", category: .kernalEditor,
                   registers: "A, X, Y",
                   notes: "Commodore label 'NXTD'."),
            Symbol(address: 0xE56C, name: "SETCURSOR", description: "Recalculate the screen and colour RAM pointers ($D1/$D2 and $F3/$F4) from the cursor row TBLX ($D6) and column PNTR ($D3).", category: .kernalEditor,
                   input: "$D6 = row, $D3 = column",
                   registers: "A, X, Y",
                   notes: "Commodore label 'STUPT'. Call it after poking $D3/$D6 by hand so the next PRINT lands where you expect."),
            Symbol(address: 0xE5B4, name: "GETKEY", description: "Remove the oldest character from the keyboard buffer at $0277.", category: .kernalEditor,
                   output: "A = the character; the buffer count at $C6 is decremented",
                   notes: "Commodore label 'LP2'. Assumes the buffer is not empty -- check $C6 first, or use GETIN ($FFE4)."),
            Symbol(address: 0xE716, name: "PRINT_SCREEN", description: "The screen editor's character output: print the PETSCII code in A at the cursor, handling colour codes, cursor movement, quote mode, insert mode and RVS.", category: .kernalEditor,
                   input: "A = PETSCII character",
                   registers: "A, X, Y",
                   notes: "Commodore label 'PRT'. This is where CHROUT ends up when the output channel is the screen."),
            Symbol(address: 0xE8EA, name: "SCROLL", description: "Scroll the whole screen up one line and clear the bottom line.", category: .kernalEditor,
                   registers: "A, X, Y",
                   notes: "Commodore label 'SCROL'. Moves both screen and colour RAM, so it is slow -- roughly two frames."),
        ])

        // ── KERNAL jump table $FF81-$FFF3 ────────────────
        // The only official, version-stable API. Every entry is a JMP,
        // so the real code can move between ROM revisions and machines.
        s.append(contentsOf: [
            Symbol(address: 0xFF81, name: "SCINIT", description: "Initialise the screen editor and VIC-II: default I/O to keyboard and screen, clear the screen, set up the keyboard tables, detect PAL vs NTSC, and re-enable the CIA #1 timer interrupt.", category: .kernalJumpTable,
                   output: "Screen cleared, cursor home, $02A6 set to 1 for PAL or 0 for NTSC",
                   registers: "A, X, Y",
                   notes: "JMP $FF5B. Called CINT in Commodore documentation. The screen-editor half alone is $E518.",
                   example: """
                   jsr $FF81          ; reset the screen editor
                   """),
            Symbol(address: 0xFF84, name: "IOINIT", description: "Initialise the CIAs and the SID volume, set the memory configuration, and start the 60 Hz timer interrupt.", category: .kernalJumpTable,
                   registers: "A, X",
                   notes: "JMP $FDA3. Also detects PAL vs NTSC by counting raster lines against CIA timer B."),
            Symbol(address: 0xFF87, name: "RAMTAS", description: "Clear $0002-$0101 and $0200-$03FF, size RAM, set the BASIC memory pointers, and point screen memory at $0400 and the tape buffer at $033C.", category: .kernalJumpTable,
                   registers: "A, X, Y",
                   notes: "JMP $FD50. The RAM test writes and reads back every page, so it destroys everything above $0400."),
            Symbol(address: 0xFF8A, name: "RESTOR", description: "Restore the default KERNAL indirect vectors at $0314-$0333.", category: .kernalJumpTable,
                   registers: "A, X, Y",
                   notes: "JMP $FD15. The quick way to undo an IRQ or CHROUT hook.",
                   example: """
                   jsr $FF8A          ; put $0314-$0333 back to normal
                   """),
            Symbol(address: 0xFF8D, name: "VECTOR", description: "Copy the KERNAL vector table at $0314-$0333 to or from a user buffer.", category: .kernalJumpTable,
                   input: "Carry = 0 to load the vectors from the buffer, Carry = 1 to save them into it; X = low byte, Y = high byte of the buffer",
                   output: "With Carry = 1 the 16 vectors are copied to the buffer",
                   registers: "A, Y",
                   notes: "JMP $FD1A. Save-then-modify-then-restore is the tidy way to install a temporary set of hooks.",
                   example: """
                   ldx #<save         ; save the current vectors
                   ldy #>save
                   sec
                   jsr $FF8D
                   """),
            Symbol(address: 0xFF90, name: "SETMSG", description: "Control which KERNAL messages are printed.", category: .kernalJumpTable,
                   input: "A: bit 7 = 1 enables control messages (SEARCHING, LOADING), bit 6 = 1 enables error messages (I/O ERROR #n)",
                   registers: "None",
                   notes: "JMP $FE18. Store $00 to silence the KERNAL entirely -- what you want before a LOAD in a game.",
                   example: """
                   lda #$00           ; silence SEARCHING/LOADING
                   jsr $FF90
                   """),
            Symbol(address: 0xFF93, name: "LSTNSA", description: "Send a secondary address on the serial bus after LISTEN.", category: .kernalJumpTable,
                   input: "A = secondary address (usually $60 + channel)",
                   registers: "A",
                   notes: "JMP $EDB9. Called SECOND in Commodore documentation. Must follow LISTEN ($FFB1)."),
            Symbol(address: 0xFF96, name: "TALKSA", description: "Send a secondary address on the serial bus after TALK.", category: .kernalJumpTable,
                   input: "A = secondary address (usually $60 + channel)",
                   registers: "A",
                   notes: "JMP $EDC7. Called TKSA in Commodore documentation. Must follow TALK ($FFB4)."),
            Symbol(address: 0xFF99, name: "MEMTOP", description: "Read or set the top of BASIC/system memory held at $0283/$0284.", category: .kernalJumpTable,
                   input: "Carry = 1 to read, Carry = 0 to set from X (low) / Y (high)",
                   output: "With Carry = 1: X = low byte, Y = high byte of the current top of memory",
                   registers: "X, Y",
                   notes: "JMP $FE25. This is MEMTOP, not MEMBOT -- $FF9C is the bottom. Lowering the top is how you reserve space for machine code above BASIC.",
                   example: """
                   sec                ; read the current top
                   jsr $FF99
                   dey                ; reserve one page
                   clc
                   jsr $FF99          ; and write it back
                   """),
            Symbol(address: 0xFF9C, name: "MEMBOT", description: "Read or set the bottom of BASIC/system memory held at $0281/$0282.", category: .kernalJumpTable,
                   input: "Carry = 1 to read, Carry = 0 to set from X (low) / Y (high)",
                   output: "With Carry = 1: X = low byte, Y = high byte of the current bottom of memory",
                   registers: "X, Y",
                   notes: "JMP $FE34. Default is $0800. BASIC only re-reads this at cold start, so raising it later does not move an existing program."),
            Symbol(address: 0xFF9F, name: "SCNKEY", description: "Scan the keyboard matrix once: update the matrix code at $CB, the shift state at $028D, and push any new PETSCII code into the keyboard buffer.", category: .kernalJumpTable,
                   registers: "A, X, Y",
                   notes: "JMP $EA87. The normal 60 Hz IRQ already calls this. Call it yourself only if you have taken over the interrupt and still want the buffer to fill."),
            Symbol(address: 0xFFA2, name: "SETTMO", description: "Enable or disable the IEEE-488 bus timeout.", category: .kernalJumpTable,
                   input: "A: bit 7 = 0 enables timeouts, bit 7 = 1 disables them",
                   registers: "None",
                   notes: "JMP $FE21. Only used by the IEEE-488 cartridge; it has no effect on the serial bus."),
            Symbol(address: 0xFFA5, name: "IECIN", description: "Read one byte from the serial bus.", category: .kernalJumpTable,
                   output: "A = the byte; check ST ($FFB7) afterwards for EOF or error",
                   registers: "A",
                   notes: "JMP $EE13. Called ACPTR in Commodore documentation. TALK and TALKSA must have been sent first.",
                   example: """
                   lda #$08           ; TALK to device 8
                   jsr $FFB4
                   lda #$60           ; channel 0
                   jsr $FF96
                   jsr $FFA5          ; A = first byte
                   """),
            Symbol(address: 0xFFA8, name: "IECOUT", description: "Send one byte to the serial bus.", category: .kernalJumpTable,
                   input: "A = the byte",
                   registers: "None",
                   notes: "JMP $EDDD. Called CIOUT in Commodore documentation. LISTEN and LSTNSA must have been sent first. The byte is buffered and only sent when the next one arrives or UNLSTN is called."),
            Symbol(address: 0xFFAB, name: "UNTALK", description: "Send UNTALK to the serial bus, telling the current talker to stop.", category: .kernalJumpTable,
                   registers: "A",
                   notes: "JMP $EDEF."),
            Symbol(address: 0xFFAE, name: "UNLSTN", description: "Send UNLISTEN to the serial bus, which also flushes the last buffered IECOUT byte.", category: .kernalJumpTable,
                   registers: "A",
                   notes: "JMP $EDFE. Forgetting this after a series of IECOUT calls is the classic reason a disk command never arrives."),
            Symbol(address: 0xFFB1, name: "LISTEN", description: "Command a device on the serial bus to listen.", category: .kernalJumpTable,
                   input: "A = device number (0-31; 8-11 are the usual disk drives)",
                   registers: "A",
                   notes: "JMP $ED0C.",
                   example: """
                   lda #$08           ; send I0 to drive 8
                   jsr $FFB1          ; LISTEN
                   lda #$6F           ; command channel 15
                   jsr $FF93          ; LSTNSA
                   lda #'I'
                   jsr $FFA8          ; IECOUT
                   jsr $FFAE          ; UNLSTN - flushes it
                   """),
            Symbol(address: 0xFFB4, name: "TALK", description: "Command a device on the serial bus to talk.", category: .kernalJumpTable,
                   input: "A = device number (0-31)",
                   registers: "A",
                   notes: "JMP $ED09."),
            Symbol(address: 0xFFB7, name: "READST", description: "Read the I/O status byte ST ($0090).", category: .kernalJumpTable,
                   output: "A = status: $40 = EOF, $80 = device not present (serial) or no more data (tape), other bits are timeouts and checksum errors",
                   registers: "A",
                   notes: "JMP $FE07. Reading RS-232 status clears it; serial and tape status is not cleared. Test it after every CHRIN or IECIN.",
                   example: """
                   jsr $FFCF          ; CHRIN
                   pha
                   jsr $FFB7          ; READST
                   bne done           ; EOF or error
                   pla
                   """),
            Symbol(address: 0xFFBA, name: "SETLFS", description: "Set the logical file number, device number and secondary address for the next OPEN, LOAD or SAVE.", category: .kernalJumpTable,
                   input: "A = logical file number (1-255), X = device number, Y = secondary address ($FF for none)",
                   registers: "None",
                   notes: "JMP $FE00. For LOAD, Y = 0 means 'load at the address in X/Y', Y = 1 means 'load at the address stored in the file'. Logical file numbers above 127 make CHROUT insert a line feed after every carriage return."),
            Symbol(address: 0xFFBD, name: "SETNAM", description: "Set the filename for the next OPEN, LOAD or SAVE.", category: .kernalJumpTable,
                   input: "A = name length (0 for none), X = low byte, Y = high byte of the name",
                   registers: "None",
                   notes: "JMP $FDF9. The name is PETSCII and is NOT copied -- the buffer must stay put until the operation finishes.",
                   example: """
                   lda #name_end-name
                   ldx #<name
                   ldy #>name
                   jsr $FFBD          ; SETNAM
                   name: .byte "DATA,S,R"
                   name_end:
                   """),
            Symbol(address: 0xFFC0, name: "OPEN", description: "Open a logical file using the parameters set by SETLFS and SETNAM.", category: .kernalJumpTable,
                   output: "Carry = 1 on error with A = KERNAL error code (1 too many files, 2 file already open, 4 file not found, 5 device not present)",
                   registers: "A, X, Y",
                   notes: "Vectored: JMP ($031A), default $F34A. Up to 10 files may be open at once.",
                   example: """
                   lda #$01           ; logical file 1
                   ldx #$08           ; device 8
                   ldy #$02           ; channel 2
                   jsr $FFBA          ; SETLFS
                   jsr $FFBD          ; SETNAM (set up beforehand)
                   jsr $FFC0          ; OPEN
                   bcs error
                   """),
            Symbol(address: 0xFFC3, name: "CLOSE", description: "Close a logical file.", category: .kernalJumpTable,
                   input: "A = logical file number",
                   output: "Carry = 1 on error, A = error code",
                   registers: "A, X, Y",
                   notes: "Vectored: JMP ($031C), default $F291. Closing a write channel is what makes the drive flush the file -- skip it and the file is left unclosed (a splat file)."),
            Symbol(address: 0xFFC6, name: "CHKIN", description: "Make an already-open logical file the current input channel.", category: .kernalJumpTable,
                   input: "X = logical file number",
                   output: "Carry = 1 on error, A = error code (3 = file not open)",
                   registers: "A, X",
                   notes: "Vectored: JMP ($031E), default $F20E. Sends TALK and the secondary address for a serial device.",
                   example: """
                   ldx #$01           ; read from logical file 1
                   jsr $FFC6          ; CHKIN
                   jsr $FFCF          ; CHRIN
                   jsr $FFCC          ; CLRCHN when done
                   """),
            Symbol(address: 0xFFC9, name: "CHKOUT", description: "Make an already-open logical file the current output channel.", category: .kernalJumpTable,
                   input: "X = logical file number",
                   output: "Carry = 1 on error, A = error code",
                   registers: "A, X",
                   notes: "Vectored: JMP ($0320), default $F250. Sends LISTEN and the secondary address for a serial device."),
            Symbol(address: 0xFFCC, name: "CLRCHN", description: "Restore the default channels: input from the keyboard, output to the screen. Sends UNTALK/UNLISTEN on the serial bus.", category: .kernalJumpTable,
                   registers: "A, X",
                   notes: "Vectored: JMP ($0322), default $F333. Always pair it with CHKIN/CHKOUT, or the next PRINT goes to the disk drive."),
            Symbol(address: 0xFFCF, name: "CHRIN", description: "Read one byte from the current input channel.", category: .kernalJumpTable,
                   output: "A = the byte; Carry = 1 on error",
                   registers: "A, Y",
                   notes: "Vectored: JMP ($0324), default $F157. From the keyboard this BLOCKS: it runs the full screen editor and only returns characters once RETURN is pressed, one per call, ending with CHR$(13). Use GETIN ($FFE4) for a non-blocking read."),
            Symbol(address: 0xFFD2, name: "CHROUT", description: "Write one byte to the current output channel.", category: .kernalJumpTable,
                   input: "A = PETSCII character",
                   output: "Carry = 1 on error, A = error code",
                   registers: "None (A is preserved)",
                   notes: "Vectored: JMP ($0326), default $F1CA. The single most useful KERNAL call. To the screen it honours all the control codes: $93 clear, $13 home, $0D return, $11/$91 cursor down/up, $1D/$9D right/left, $12/$92 RVS on/off, $05/$1C/$1E/$9F etc. for colours.",
                   example: """
                   lda #$93           ; clear screen
                   jsr $FFD2
                   ldx #$00
                   loop:
                     lda text,x
                     beq done
                     jsr $FFD2
                     inx
                     bne loop
                   done:
                   text: .byte "HELLO WORLD", 0
                   """),
            Symbol(address: 0xFFD5, name: "LOAD", description: "Load or verify a file, using the parameters set by SETLFS and SETNAM.", category: .kernalJumpTable,
                   input: "A = 0 to load, 1-255 to verify; X = low byte, Y = high byte of the load address (used only when the secondary address is 0)",
                   output: "Carry = 0 on success with X/Y = the address after the last byte loaded; Carry = 1 with A = error code on failure",
                   registers: "A, X, Y",
                   notes: "JMP $F49E, which dispatches through ILOAD ($0330), default $F4A5. Secondary address 1 uses the two-byte load address stored in the file; secondary address 0 ignores it and uses X/Y. LOAD cannot cross a bank boundary and will not load under the ROMs.",
                   example: """
                   lda #$01           ; SETLFS: file 1, drive 8, sa 1
                   ldx #$08
                   ldy #$01
                   jsr $FFBA
                   lda #$04           ; SETNAM
                   ldx #<name
                   ldy #>name
                   jsr $FFBD
                   lda #$00           ; 0 = load (not verify)
                   jsr $FFD5
                   bcs error
                   name: .byte "DATA"
                   """),
            Symbol(address: 0xFFD8, name: "SAVE", description: "Save a block of memory to a file, using the parameters set by SETLFS and SETNAM.", category: .kernalJumpTable,
                   input: "A = zero-page address holding the two-byte start address; X = low byte, Y = high byte of the end address + 1",
                   output: "Carry = 1 on error with A = error code",
                   registers: "A, X, Y",
                   notes: "JMP $F5DD, dispatching through ISAVE ($0332). A is an INDIRECT pointer: the start address lives in zero page, not in registers. A filename is mandatory for disk.",
                   example: """
                   lda #<start        ; put the start address in $FB/$FC
                   sta $FB
                   lda #>start
                   sta $FC
                   lda #$FB           ; A = the zero-page pointer
                   ldx #<end
                   ldy #>end
                   jsr $FFD8
                   """),
            Symbol(address: 0xFFDB, name: "SETTIM", description: "Set the software jiffy clock at $A0-$A2.", category: .kernalJumpTable,
                   input: "A = most significant byte, X = middle, Y = least significant",
                   registers: "None",
                   notes: "JMP $F6E4. The clock counts 1/60 s ticks on NTSC and 1/50 s on PAL, and wraps after 24 hours.",
                   example: """
                   lda #$00           ; TI$ = \"000000\"
                   tax
                   tay
                   jsr $FFDB
                   """),
            Symbol(address: 0xFFDE, name: "RDTIM", description: "Read the software jiffy clock at $A0-$A2.", category: .kernalJumpTable,
                   output: "A = most significant byte, X = middle, Y = least significant",
                   registers: "A, X, Y",
                   notes: "JMP $F6DD. Only accurate while interrupts are enabled, since UDTIM does the counting."),
            Symbol(address: 0xFFE1, name: "STOP", description: "Test whether the STOP key is being held down.", category: .kernalJumpTable,
                   output: "Zero flag = 1 (and Carry = 1) if STOP is pressed; if so, channels are cleared and the keyboard buffer emptied",
                   registers: "A, X",
                   notes: "Vectored: JMP ($0328), default $F6ED. It reads the flag at $91 that UDTIM sets, so it only works while the normal IRQ runs. Repointing $0328 at an RTS is the usual way to disable RUN/STOP.",
                   example: """
                   jsr $FFE1          ; abort on STOP
                   beq abort
                   """),
            Symbol(address: 0xFFE4, name: "GETIN", description: "Read one character from the keyboard buffer, or from the current input channel if it is not the keyboard.", category: .kernalJumpTable,
                   output: "A = the character, or $00 if nothing is waiting",
                   registers: "A, X, Y",
                   notes: "Vectored: JMP ($032A), default $F13E. Non-blocking, which makes it the right call for a game loop. On a serial device it behaves like CHRIN and does block.",
                   example: """
                   wait:
                     jsr $FFE4        ; poll the keyboard
                     beq wait
                     cmp #$20         ; space?
                   """),
            Symbol(address: 0xFFE7, name: "CLALL", description: "Close every open file and reset to the default channels.", category: .kernalJumpTable,
                   registers: "A, X",
                   notes: "Vectored: JMP ($032C), default $F32F. It forgets the files rather than closing them properly on the device, so a disk file left open this way stays unclosed."),
            Symbol(address: 0xFFEA, name: "UDTIM", description: "Advance the jiffy clock by one tick and update the STOP key flag at $91.", category: .kernalJumpTable,
                   registers: "A, X",
                   notes: "JMP $F69B. The normal IRQ calls this 50 or 60 times a second. If you install your own IRQ handler that does not chain to $EA31, call this yourself or TI and STOP both freeze.",
                   example: """
                   ; in a custom raster IRQ:
                   jsr $FFEA          ; keep TI and the STOP key alive
                   """),
            Symbol(address: 0xFFED, name: "SCREEN", description: "Report the screen size.", category: .kernalJumpTable,
                   output: "X = number of columns (40), Y = number of rows (25)",
                   registers: "X, Y",
                   notes: "JMP $E505. Constant on the C64, but the same call returns 80x25 on a C128 in 80-column mode."),
            Symbol(address: 0xFFF0, name: "PLOT", description: "Read or set the cursor position.", category: .kernalJumpTable,
                   input: "Carry = 1 to read; Carry = 0 to set, with X = row (0-24) and Y = column (0-39)",
                   output: "With Carry = 1: X = row, Y = column",
                   registers: "X, Y",
                   notes: "JMP $E50A. X is the ROW and Y the COLUMN, which is the opposite of what most people expect.",
                   example: """
                   ldx #$0A           ; row 10, column 5
                   ldy #$05
                   clc
                   jsr $FFF0
                   """),
            Symbol(address: 0xFFF3, name: "IOBASE", description: "Return the base address of the I/O area (CIA #1).", category: .kernalJumpTable,
                   output: "X = $00, Y = $DC, i.e. $DC00",
                   registers: "X, Y",
                   notes: "JMP $E500. Provided so portable code can find the CIA without hard-coding $DC00.",
                   example: """
                   jsr $FFF3          ; X/Y = CIA #1 base
                   stx $FB
                   sty $FC
                   """),
        ])

        // ── KERNAL internals: serial bus ─────────────────
        s.append(contentsOf: [
            Symbol(address: 0xEA31, name: "IRQ_MAIN", description: "The default 60 Hz interrupt handler: update the jiffy clock, blink the cursor, scan the keyboard, and run the tape motor logic.", category: .kernalIRQ,
                   notes: "Commodore label 'KEY'. This is what CINV ($0314) points at. A custom IRQ that ends with JMP $EA31 keeps the keyboard and clock working; one that ends with JMP $EA81 only restores the registers and skips all of it.",
                   example: """
                   ; chain a raster IRQ into the KERNAL handler
                   myirq:
                     inc $D019        ; acknowledge the raster IRQ
                     ; ...your code...
                     jmp $EA31        ; let the KERNAL finish up
                   """),
            Symbol(address: 0xEA81, name: "IRQ_EXIT", description: "Interrupt epilogue: pull Y, X and A off the stack and RTI.", category: .kernalIRQ,
                   notes: "Unnamed in the ROM source, but a fixed landmark: $EA7E clears the CIA #1 interrupt flags and $EA81 is the bare PLA/TAY/PLA/TAX/PLA/RTI. End a raster IRQ at $EA81 when you do NOT want the keyboard scan and jiffy update -- but acknowledge the VIC interrupt in $D019 yourself first."),
            Symbol(address: 0xEA87, name: "SCNKEY_INT", description: "Scan the keyboard matrix through CIA #1 and decode the result. The routine behind $FF9F.", category: .kernalInternal,
                   notes: "Decodes through the tables at $EB81 (unshifted), $EBC2 (shifted), $EC03 (Commodore key) and $EC78 (CTRL). The $028F/$0290 vector points at the routine that picks between them, so redefining the keyboard means pointing it at your own table selector."),
            Symbol(address: 0xED09, name: "TALK_INT", description: "Send a TALK command on the serial bus. The routine behind $FFB4.", category: .kernalIO),
            Symbol(address: 0xED0C, name: "LISTEN_INT", description: "Send a LISTEN command on the serial bus. The routine behind $FFB1.", category: .kernalIO),
            Symbol(address: 0xEDB9, name: "LSTNSA_INT", description: "Send a LISTEN secondary address. The routine behind $FF93.", category: .kernalIO),
            Symbol(address: 0xEDC7, name: "TALKSA_INT", description: "Send a TALK secondary address. The routine behind $FF96.", category: .kernalIO),
            Symbol(address: 0xEDDD, name: "IECOUT_INT", description: "Send one byte on the serial bus, bit-banging CIA #2's port A. The routine behind $FFA8.", category: .kernalIO,
                   notes: "The C64's serial routines are software-timed because the 6522 shift-register hardware the design assumed was dropped, which is why the 1541 is famously slow."),
            Symbol(address: 0xEDEF, name: "UNTALK_INT", description: "Send UNTALK on the serial bus. The routine behind $FFAB.", category: .kernalIO),
            Symbol(address: 0xEDFE, name: "UNLSTN_INT", description: "Send UNLISTEN on the serial bus. The routine behind $FFAE.", category: .kernalIO),
            Symbol(address: 0xEE13, name: "IECIN_INT", description: "Receive one byte from the serial bus. The routine behind $FFA5.", category: .kernalIO),
        ])

        // ── KERNAL internals: channel and file I/O ───────
        s.append(contentsOf: [
            Symbol(address: 0xF13E, name: "GETIN_INT", description: "Default GETIN handler. The target of IGETIN ($032A) and so of $FFE4.", category: .kernalIO),
            Symbol(address: 0xF157, name: "CHRIN_INT", description: "Default CHRIN handler. The target of IBASIN ($0324) and so of $FFCF.", category: .kernalIO),
            Symbol(address: 0xF1CA, name: "CHROUT_INT", description: "Default CHROUT handler. The target of IBSOUT ($0326) and so of $FFD2.", category: .kernalIO,
                   notes: "Repointing $0326 here after your own hook is how you chain onto CHROUT rather than replacing it.",
                   example: """
                   ; hook CHROUT
                   lda #<myout
                   sta $0326
                   lda #>myout
                   sta $0327
                   myout:
                     ; ...inspect A...
                     jmp $F1CA        ; then do the real thing
                   """),
            Symbol(address: 0xF20E, name: "CHKIN_INT", description: "Default CHKIN handler. The target of ICHKIN ($031E).", category: .kernalIO),
            Symbol(address: 0xF250, name: "CHKOUT_INT", description: "Default CHKOUT handler. The target of ICKOUT ($0320).", category: .kernalIO),
            Symbol(address: 0xF291, name: "CLOSE_INT", description: "Default CLOSE handler. The target of ICLOSE ($031C).", category: .kernalIO),
            Symbol(address: 0xF32F, name: "CLALL_INT", description: "Default CLALL handler: empty the file table, then fall into CLRCHN. The target of ICLALL ($032C).", category: .kernalIO),
            Symbol(address: 0xF333, name: "CLRCHN_INT", description: "Default CLRCHN handler. The target of ICLRCH ($0322).", category: .kernalIO),
            Symbol(address: 0xF34A, name: "OPEN_INT", description: "Default OPEN handler. The target of IOPEN ($031A).", category: .kernalIO),
            Symbol(address: 0xF49E, name: "LOAD_INT", description: "KERNAL LOAD entry: the target of $FFD5, which immediately dispatches through ILOAD ($0330).", category: .kernalIO,
                   notes: "Commodore label 'LOADSP'. The default ILOAD target is $F4A5."),
            Symbol(address: 0xF4A5, name: "NLOAD", description: "Default LOAD implementation: serial or tape, load or verify.", category: .kernalIO,
                   notes: "Fastloaders replace ILOAD ($0330) with their own routine and fall back here for anything they do not handle."),
            Symbol(address: 0xF5DD, name: "SAVE_INT", description: "KERNAL SAVE entry: the target of $FFD8, which dispatches through ISAVE ($0332).", category: .kernalIO,
                   notes: "Commodore label 'SAVESP'. The default ISAVE target is $F5ED."),
            Symbol(address: 0xF5ED, name: "NSAVE", description: "Default SAVE implementation: serial or tape.", category: .kernalIO),
        ])

        // ── KERNAL internals: time, system, reset ────────
        s.append(contentsOf: [
            Symbol(address: 0xF69B, name: "UDTIM_INT", description: "Advance the jiffy clock and update the STOP key flag. The routine behind $FFEA.", category: .kernalInternal),
            Symbol(address: 0xF6DD, name: "RDTIM_INT", description: "Read the jiffy clock. The routine behind $FFDE.", category: .kernalInternal),
            Symbol(address: 0xF6E4, name: "SETTIM_INT", description: "Set the jiffy clock. The routine behind $FFDB.", category: .kernalInternal),
            Symbol(address: 0xF6ED, name: "STOP_INT", description: "Default STOP handler: test $91 for the STOP key. The target of ISTOP ($0328).", category: .kernalInternal),
            Symbol(address: 0xFCE2, name: "RESET", description: "Hardware reset entry: set up the stack and $01, test for a cartridge with the 'CBM80' signature at $8004, then run IOINIT, RAMTAS, RESTOR and SCINIT before jumping through $A000 into BASIC.", category: .kernalInternal,
                   notes: "Commodore label 'START'. The $FFFC vector points here.",
                   example: """
                   jmp ($FFFC)        ; a soft reset from machine code
                   """),
            Symbol(address: 0xFD15, name: "RESTOR_INT", description: "Copy the default KERNAL vectors into $0314-$0333. The routine behind $FF8A.", category: .kernalInternal,
                   notes: "The defaults live in the table at $FD30."),
            Symbol(address: 0xFD1A, name: "VECTOR_INT", description: "Copy the KERNAL vector table to or from a user buffer. The routine behind $FF8D.", category: .kernalInternal),
            Symbol(address: 0xFD30, name: "VECTAB", description: "Table of the 16 default KERNAL vectors for $0314-$0333.", category: .romTable,
                   notes: "In order: CINV $0314, CBINV $0316, NMINV $0318, IOPEN $031A, ICLOSE $031C, ICHKIN $031E, ICKOUT $0320, ICLRCH $0322, IBASIN $0324, IBSOUT $0326, ISTOP $0328, IGETIN $032A, ICLALL $032C, USRCMD $032E, ILOAD $0330, ISAVE $0332."),
            Symbol(address: 0xFD50, name: "RAMTAS_INT", description: "Clear low memory, size RAM from the top down, and set the memory pointers. The routine behind $FF87.", category: .kernalInternal),
            Symbol(address: 0xFDA3, name: "IOINIT_INT", description: "Initialise the CIAs, the SID volume and the interrupt timer. The routine behind $FF84.", category: .kernalInternal),
            Symbol(address: 0xFDF9, name: "SETNAM_INT", description: "Store the filename length and pointer in $B7 and $BB/$BC. The routine behind $FFBD.", category: .kernalInternal),
            Symbol(address: 0xFE00, name: "SETLFS_INT", description: "Store the logical file, device and secondary address in $B8, $BA and $B9. The routine behind $FFBA.", category: .kernalInternal),
            Symbol(address: 0xFE07, name: "READST_INT", description: "Return the I/O status byte. The routine behind $FFB7.", category: .kernalInternal),
            Symbol(address: 0xFE18, name: "SETMSG_INT", description: "Store the KERNAL message control flags at $9D. The routine behind $FF90.", category: .kernalInternal),
            Symbol(address: 0xFE21, name: "SETTMO_INT", description: "Store the IEEE-488 timeout flag at $0285. The routine behind $FFA2.", category: .kernalInternal),
            Symbol(address: 0xFE25, name: "MEMTOP_INT", description: "Read or set the top of memory at $0283/$0284. The routine behind $FF99.", category: .kernalInternal,
                   notes: "This is MEMTOP. Earlier versions of this table had MEMTOP and MEMBOT the wrong way round."),
            Symbol(address: 0xFE34, name: "MEMBOT_INT", description: "Read or set the bottom of memory at $0281/$0282. The routine behind $FF9C.", category: .kernalInternal,
                   notes: "This is MEMBOT."),
            Symbol(address: 0xFE43, name: "NMI_HANDLER", description: "NMI entry: save the registers, then jump through NMINV ($0318).", category: .kernalIRQ,
                   notes: "The $FFFA vector points here. NMIs cannot be masked, so RESTORE always gets through -- which is why RUN/STOP+RESTORE works even when a program has disabled IRQs.",
                   example: """
                   ; make RESTORE harmless
                   lda #<nmi_rti
                   sta $0318
                   lda #>nmi_rti
                   sta $0319
                   nmi_rti: rti
                   """),
            Symbol(address: 0xFE47, name: "NMI_DEFAULT", description: "Default NMI handler: check the CIA #2 interrupt source, service RS-232 if that caused it, otherwise treat it as RESTORE and warm-start BASIC.", category: .kernalIRQ,
                   notes: "Commodore label 'NNMI'. This is what NMINV ($0318) points at after a reset."),
            Symbol(address: 0xFE66, name: "BRK_ENTRY", description: "BRK handler: restore the default I/O, reset the stack, and warm-start BASIC.", category: .kernalIRQ,
                   notes: "Commodore label 'TIMB'. CBINV ($0316) points here; repoint it to catch BRK yourself, which is how machine-language monitors implement breakpoints."),
            Symbol(address: 0xFF43, name: "SIMIRQ", description: "Simulate an interrupt: push a fake status byte and fall into the IRQ handler.", category: .kernalIRQ,
                   notes: "Used by the tape routines to enter the interrupt code without a real interrupt."),
            Symbol(address: 0xFF48, name: "IRQ_ENTRY", description: "IRQ/BRK entry: save the registers, then jump through CINV ($0314) for an IRQ or CBINV ($0316) for a BRK.", category: .kernalIRQ,
                   input: "The stacked status register's B flag decides which vector is used",
                   notes: "The $FFFE vector points here. Because it tests the B flag, a BRK inside your own IRQ handler still ends up in the debugger vector.",
                   example: """
                   ; install a raster IRQ
                   sei
                   lda #<myirq
                   sta $0314
                   lda #>myirq
                   sta $0315
                   cli
                   """),
            Symbol(address: 0xFF5B, name: "SCINIT_INT", description: "Call CINT ($E518), then read the VIC raster registers to set the PAL/NTSC flag at $02A6 and re-enable the CIA #1 timer interrupt. The routine behind $FF81.", category: .kernalInternal,
                   notes: "Commodore label 'PCINT'."),
        ])

        // ── Hardware vectors ─────────────────────────────
        s.append(contentsOf: [
            Symbol(address: 0xFFFA, name: "VEC_NMI", description: "6510 NMI vector. Contains $FE43.", category: .hardwareVector,
                   notes: "Read from RAM when the KERNAL is banked out, so a program that switches to a full 64K RAM map must provide its own vector at $FFFA."),
            Symbol(address: 0xFFFC, name: "VEC_RESET", description: "6510 RESET vector. Contains $FCE2.", category: .hardwareVector,
                   notes: "Read at power-on and on the reset line; a cartridge with 'CBM80' at $8004 gets control before BASIC does."),
            Symbol(address: 0xFFFE, name: "VEC_IRQ", description: "6510 IRQ/BRK vector. Contains $FF48.", category: .hardwareVector,
                   notes: "With the KERNAL banked out ($01 bit 1 = 0) this word comes from RAM, which is how demos take over interrupts completely."),
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
