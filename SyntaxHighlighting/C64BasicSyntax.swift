import Foundation
import AppKit

// MARK: - Token Types

/// Semantic classification of tokens for C64 BASIC syntax highlighting.
enum C64TokenType {
    case keyword          // PRINT, GOTO, IF, etc.
    case function         // ABS(), CHR$(), etc.
    case operator_        // +, -, *, /, AND, OR, NOT
    case number           // Numeric literals
    case string           // String literals in quotes
    case comment          // REM statements
    case lineNumber       // Line numbers at start of lines
    case variable         // Variable names
    case systemVariable   // TI, TI$, ST, etc.
    case poke             // POKE/PEEK (special because they're so important on C64)
    case sid              // SID-related addresses
    case vic              // VIC-II related addresses
    case separator        // :, ;, ,
    case plain            // Everything else

    /// Returns the appropriate syntax color for this token type based on the current theme.
    var color: NSColor {
        let t = AppTheme.current
        switch self {
        case .keyword:        return t.syntaxKeyword
        case .function:       return t.syntaxFunction
        case .operator_:      return t.syntaxOperator
        case .number:         return t.syntaxNumber
        case .string:         return t.syntaxString
        case .comment:        return t.syntaxComment
        case .lineNumber:     return t.syntaxLineNumber
        case .variable:       return t.syntaxVariable
        case .systemVariable: return t.syntaxSystemVariable
        case .poke:           return t.syntaxPoke
        case .sid:            return t.syntaxSID
        case .vic:            return t.syntaxVIC
        case .separator:      return t.syntaxSeparator
        case .plain:          return t.syntaxPlain
        }
    }
}

// MARK: - Syntax Token

/// Represents a single token identified by the BASIC syntax highlighter.
struct SyntaxToken {
    let range: NSRange
    let type: C64TokenType
    let text: String
}

// MARK: - Command Reference Entry

/// One parameter of a BASIC V2 command or function.
///
/// Mirrors `ParameterDef` in the dialect plugin schema so that built-in V2
/// entries and plugin-supplied entries render identically in the reference
/// panel and in editor tooltips.
struct C64ParamRef {
    let name: String
    let type: String?
    let range: String?
    let description: String?
    let optional: Bool

    /// Name and description are positional because every entry supplies them;
    /// the rest are keyword arguments so the table stays readable.
    init(_ name: String,
         type: String? = nil,
         range: String? = nil,
         _ description: String? = nil,
         optional: Bool = false) {
        self.name = name
        self.type = type
        self.range = range
        self.description = description
        self.optional = optional
    }
}

/// Documentation entry for a single BASIC V2 command or function.
struct C64CommandRef {
    let keyword: String
    let category: CommandCategory
    let syntax: String
    let description: String
    let example: String?
    let notes: String?
    /// Per-parameter documentation, matching what dialect plugins supply.
    /// `nil` for keywords that take no arguments.
    let parameters: [C64ParamRef]?
    /// The BASIC V2 token byte ($80-$CB), or `nil` for entries the ROM does not
    /// tokenize: the reserved variables TI/TI$/ST, and GET#, which crunches as
    /// GET followed by a literal "#".
    let token: UInt8?

    init(keyword: String,
         category: CommandCategory,
         syntax: String,
         description: String,
         example: String? = nil,
         notes: String? = nil,
         parameters: [C64ParamRef]? = nil,
         token: UInt8? = nil) {
        self.keyword = keyword
        self.category = category
        self.syntax = syntax
        self.description = description
        self.example = example
        self.notes = notes
        self.parameters = parameters
        self.token = token
    }

    /// Categorizes BASIC commands for reference documentation.
    enum CommandCategory: String {
        case statement = "Statement"
        case function = "Function"
        case operator_ = "Operator"
        case systemVar = "System Variable"
        case ioCommand = "I/O Command"
        case diskCommand = "Disk Command"
    }
}

// MARK: - C64 BASIC Syntax Definition

/// Central repository for C64 BASIC V2 syntax rules, command references, and tokenization.
struct C64BasicSyntax {

    /// Look up a keyword in the command reference.
    /// - Parameter keyword: The keyword to look up.
    /// - Returns: A `C64CommandRef` if found, otherwise `nil`.
    static func lookup(_ keyword: String) -> C64CommandRef? {
        return commandReference[keyword.uppercased()]
    }

    // MARK: - Keywords

    /// All C64 BASIC V2 keywords (statements/commands).
    static let keywords: Set<String> = [
        // Program flow
        "GOTO", "GOSUB", "RETURN", "IF", "THEN",
        // Note: ELSE is NOT a BASIC V2 token. Token $CB is GO (the "GO TO" alternate form).
        // ELSE first appeared in BASIC 3.5 (C16/Plus/4). Do not add it here.
        "FOR", "TO", "STEP", "NEXT",
        "ON", "RUN", "STOP", "END", "CONT",
        // GO ($CB) exists only so that "GO TO" typed with a space is accepted.
        "GO",

        // I/O
        "PRINT", "INPUT", "GET", "READ", "DATA", "RESTORE",
        "OPEN", "CLOSE", "CMD", "GET#", "INPUT#", "PRINT#",

        // Variables & Memory
        "LET", "DIM", "DEF", "FN",
        "POKE", "PEEK", "SYS", "USR", "WAIT",

        // Program management
        "NEW", "CLR", "LIST", "SAVE", "LOAD", "VERIFY",
        "REM",

        // Screen
        "TAB", "SPC",
    ]

    /// BASIC functions that return values.
    static let functions: Set<String> = [
        // Math functions
        "ABS", "ATN", "COS", "EXP", "INT", "LOG",
        "RND", "SGN", "SIN", "SQR", "TAN",

        // String functions
        "ASC", "CHR$", "LEFT$", "LEN", "MID$", "RIGHT$",
        "STR$", "VAL",

        // Other functions
        // Note: PEEK, TAB, and SPC are listed in `keywords` above. Because the tokenizer
        // checks `keywords` before `functions`, listing them here is dead code. They live
        // in `keywords` to get their special highlight treatment (.poke / .keyword).
        "FRE", "POS",
    ]

    /// Logical and bitwise operators.
    static let operators: Set<String> = [
        "AND", "OR", "NOT",
    ]

    /// Built-in system variables.
    static let systemVariables: Set<String> = [
        "TI", "TI$", "ST",
    ]

    /// Cached keyword matcher — rebuilt only when the dialect changes.
    /// Combines all standard BASIC V2 keywords with any active dialect extensions.
    private static var _keywordMatcher: BasicKeywordMatcher?

    static var keywordMatcher: BasicKeywordMatcher {
        if let m = _keywordMatcher { return m }
        let all = BasicKeywordMatcher.basicV2Keywords +
                  Array(BasicDialectManager.shared.allKeywordNames)
        let matcher = BasicKeywordMatcher(keywords: all)
        _keywordMatcher = matcher
        return matcher
    }

    /// Call this when the active dialect changes so the matcher is rebuilt.
    static func invalidateKeywordMatcher() {
        _keywordMatcher = nil
    }

    // MARK: - Complete Command Reference

    /// Encyclopedic reference for every BASIC V2 keyword, operator and system
    /// variable.
    ///
    /// Every entry in the ROM's $80-$CB token table (see
    /// `BasicTokenizer.tokenTable`) has an entry here, plus the three system
    /// variables (TI, TI$, ST) and GET#, which the ROM crunches as GET followed
    /// by "#" rather than as a token of its own.
    ///
    /// Entries carry the same fields a dialect plugin supplies for its own
    /// keywords -- syntax, description, parameters, example, notes and token --
    /// so the reference panel renders built-in and plugin keywords identically.
    static let commandReference: [String: C64CommandRef] = [
        // ── Program Flow ──────────────────────────────────────────
        "GOTO": C64CommandRef(
            keyword: "GOTO",
            category: .statement,
            syntax: "GOTO line_number",
            description: "Transfers program execution to the specified line number. Unconditional branch.",
            example: "GOTO 100",
            notes: "When the target is a higher line number than the current one the ROM searches forward from the current line; otherwise it restarts the search at the beginning of the program. Backward jumps into a long program are therefore the slowest. GO TO written with a space also works -- it tokenizes as GO ($CB) followed by TO ($A4).",
            parameters: [
                C64ParamRef("line_number", type: "integer", range: "0-63999", "Destination line. ?UNDEF'D STATEMENT ERROR if that line does not exist")
            ],
            token: 0x89
        ),
        "GOSUB": C64CommandRef(
            keyword: "GOSUB",
            category: .statement,
            syntax: "GOSUB line_number",
            description: "Calls a subroutine at the specified line number, remembering where to come back to. Use RETURN to return to the statement following the GOSUB.",
            example: "GOSUB 5000",
            notes: "Each GOSUB pushes a 5-byte frame onto the 6502 hardware stack at $0100-$01FF, which BASIC shares with FOR (18 bytes per loop). Roughly 23 GOSUBs can be nested on an otherwise empty stack, fewer when FOR loops are also open; overflowing it gives ?OUT OF MEMORY ERROR. Jumping out of a subroutine with GOTO instead of returning leaves its frame on the stack, so a loop that does so will eventually overflow.",
            parameters: [
                C64ParamRef("line_number", type: "integer", range: "0-63999", "First line of the subroutine. ?UNDEF'D STATEMENT ERROR if that line does not exist")
            ],
            token: 0x8D
        ),
        "RETURN": C64CommandRef(
            keyword: "RETURN",
            category: .statement,
            syntax: "RETURN",
            description: "Returns from a GOSUB subroutine to the statement after the calling GOSUB.",
            example: "5099 RETURN",
            notes: "RETURN without a prior GOSUB causes ?RETURN WITHOUT GOSUB ERROR. RETURN also discards any FOR loops opened inside the subroutine.",
            token: 0x8E
        ),
        "IF": C64CommandRef(
            keyword: "IF",
            category: .statement,
            syntax: "IF expression THEN statement(s) | IF expression GOTO line_number",
            description: "Conditional execution. If the expression is true (non-zero), the THEN clause runs; otherwise the rest of the line is skipped entirely. BASIC V2 treats 0 as false and any non-zero value as true.",
            example: "IF X > 10 THEN PRINT \"BIG\" : GOTO 200",
            notes: "C64 BASIC V2 has no ELSE -- it is not a token in the V2 table. Use an IF/GOTO pattern instead: IF X=0 THEN GOTO 300. ELSE first appeared in BASIC 3.5 (C16/Plus/4) and carried into BASIC 7.0 (C128). Because a false condition skips the whole remainder of the line, statements after a colon on an IF line only run when the condition is true. IF..GOTO is the one form where THEN may be omitted.",
            parameters: [
                C64ParamRef("expression", type: "numeric", "Any numeric or relational expression; zero is false, non-zero is true")
            ],
            token: 0x8B
        ),
        "THEN": C64CommandRef(
            keyword: "THEN",
            category: .statement,
            syntax: "IF expression THEN line_number | IF expression THEN statement(s)",
            description: "Introduces the true branch of an IF. It may be followed by a line number (an implicit GOTO) or by one or more statements.",
            example: "IF A=1 THEN 500",
            notes: "THEN followed by a number behaves exactly like THEN GOTO number, and saves a token. THEN is only valid inside an IF statement.",
            token: 0xA7
        ),
        "FOR": C64CommandRef(
            keyword: "FOR",
            category: .statement,
            syntax: "FOR variable = start TO end [STEP increment]",
            description: "Begins a counted loop. The loop variable is set to start, and each NEXT adds the increment (default 1) and loops back until the variable passes the end value.",
            example: "FOR I = 0 TO 255 STEP 2",
            notes: "The test happens at NEXT, so the body always runs at least once -- FOR I=1 TO 0 still executes once. The loop variable must be a simple numeric variable, not an array element. Each open FOR uses 18 bytes of the 6502 stack, limiting nesting to about nine loops. The start, end and step values are evaluated once, when the FOR is executed.",
            parameters: [
                C64ParamRef("variable", type: "numeric variable", "Simple (non-array) loop counter"),
                C64ParamRef("start", type: "numeric", "Initial value"),
                C64ParamRef("end", type: "numeric", "Final value, tested at NEXT"),
                C64ParamRef("increment", type: "numeric", "Amount added at each NEXT; defaults to 1", optional: true)
            ],
            token: 0x81
        ),
        "TO": C64CommandRef(
            keyword: "TO",
            category: .statement,
            syntax: "FOR var = start TO end",
            description: "Separates the start and end values of a FOR loop. Also forms the two-word GO TO when written after GO.",
            example: "FOR I = 1 TO 100",
            notes: "TO is only meaningful inside FOR (or directly after GO). Note that the C64 tokenizes the TO inside a variable name too, so avoid names like TOTAL -- they crunch to T + TO + AL and cause ?SYNTAX ERROR.",
            token: 0xA4
        ),
        "STEP": C64CommandRef(
            keyword: "STEP",
            category: .statement,
            syntax: "FOR var = start TO end STEP increment",
            description: "Specifies the amount added to the loop variable at each NEXT. Defaults to 1 when omitted.",
            example: "FOR I = 100 TO 0 STEP -1",
            notes: "A negative STEP counts down and the loop ends when the variable drops below the end value. STEP 0 loops forever. Fractional steps work but accumulate floating-point error over many iterations.",
            parameters: [
                C64ParamRef("increment", type: "numeric", "Added to the loop variable at each NEXT; may be negative or fractional")
            ],
            token: 0xA9
        ),
        "NEXT": C64CommandRef(
            keyword: "NEXT",
            category: .statement,
            syntax: "NEXT [variable[, variable...]]",
            description: "Marks the end of a FOR loop. Adds STEP to the loop variable and branches back to the statement after the FOR unless the end value has been passed.",
            example: "NEXT I",
            notes: "NEXT with no variable closes the innermost open loop and is slightly faster. Multiple variables close several loops at once and must be listed innermost first: NEXT J,I. A NEXT with no matching FOR gives ?NEXT WITHOUT FOR ERROR.",
            parameters: [
                C64ParamRef("variable", type: "numeric variable", "Loop variable to advance; omit to close the innermost loop", optional: true)
            ],
            token: 0x82
        ),
        "ON": C64CommandRef(
            keyword: "ON",
            category: .statement,
            syntax: "ON expression GOTO line1[,line2,...] | ON expression GOSUB line1[,line2,...]",
            description: "Computed branch. The expression is truncated to an integer and used as a 1-based index into the list of line numbers, which is then jumped to or called.",
            example: "ON X GOTO 100,200,300",
            notes: "An index of 0, or one larger than the list, falls through to the next statement rather than erroring. A negative index or one above 255 gives ?ILLEGAL QUANTITY ERROR. ON..GOSUB returns to the statement after the whole ON line.",
            parameters: [
                C64ParamRef("expression", type: "integer", range: "0-255", "1-based selector; 0 or out-of-range falls through"),
                C64ParamRef("line1,line2,...", type: "integer list", range: "0-63999", "Destination line numbers, in selector order")
            ],
            token: 0x91
        ),
        "GO": C64CommandRef(
            keyword: "GO",
            category: .statement,
            syntax: "GO TO line_number",
            description: "Alternate spelling of GOTO that allows a space between the two words. GO exists purely so that GO TO typed with a space is accepted.",
            example: "GO TO 100",
            notes: "GO is its own token ($CB), the last token in the BASIC V2 table. It is only valid immediately before TO; anything else after GO gives ?SYNTAX ERROR. GO TO costs one more byte than GOTO and lists back as GO TO, so most code uses GOTO.",
            parameters: [
                C64ParamRef("line_number", type: "integer", range: "0-63999", "Destination line, introduced by TO")
            ],
            token: 0xCB
        ),
        "RUN": C64CommandRef(
            keyword: "RUN",
            category: .statement,
            syntax: "RUN [line_number]",
            description: "Starts the program from the beginning, or from the specified line number. All variables and arrays are cleared first.",
            example: "RUN 100",
            notes: "RUN performs a CLR, so variables do not survive it -- use GOTO to resume without clearing. RUN also resets the DATA pointer and closes open files. It may be used inside a program, which restarts it.",
            parameters: [
                C64ParamRef("line_number", type: "integer", range: "0-63999", "Line to start at; defaults to the first line of the program", optional: true)
            ],
            token: 0x8A
        ),
        "STOP": C64CommandRef(
            keyword: "STOP",
            category: .statement,
            syntax: "STOP",
            description: "Halts the program and prints BREAK IN line. Variables are preserved, and execution can be resumed with CONT.",
            example: "1200 IF E<>0 THEN STOP",
            notes: "The standard way to drop into the READY prompt for debugging: inspect or change variables, then type CONT. STOP inside a subroutine leaves the GOSUB stack intact, so CONT still returns correctly.",
            token: 0x90
        ),
        "END": C64CommandRef(
            keyword: "END",
            category: .statement,
            syntax: "END",
            description: "Terminates the program normally. Like STOP, but prints no BREAK message.",
            example: "999 END",
            notes: "Variables are preserved and CONT can resume after it. Falling off the last line of a program ends it just as END does; END is mainly used to stop execution before a block of subroutines.",
            token: 0x80
        ),
        "CONT": C64CommandRef(
            keyword: "CONT",
            category: .statement,
            syntax: "CONT",
            description: "Resumes a program halted by STOP, END, or the RUN/STOP key, continuing with the statement after the one that stopped it.",
            example: "CONT",
            notes: "?CAN'T CONTINUE ERROR if the program has been edited since it stopped, if it stopped on an error, or if no program has been run. Direct-mode assignments made while stopped are kept, so CONT is useful for patching a variable mid-run.",
            token: 0x9A
        ),

        // ── I/O ──────────────────────────────────────────────────
        "PRINT": C64CommandRef(
            keyword: "PRINT",
            category: .statement,
            syntax: "PRINT [expression[{;|,}expression...]]",
            description: "Outputs to the current output device (the screen by default). A semicolon joins items with no spacing; a comma advances to the next 10-column tab stop.",
            example: "PRINT \"SCORE: \";SC",
            notes: "? is the accepted abbreviation and tokenizes to the same $99 byte. PRINT with no arguments outputs an empty line. A trailing semicolon or comma suppresses the carriage return so the next PRINT continues on the same line. Numbers print with a leading space (or a minus sign) and a trailing space.",
            parameters: [
                C64ParamRef("expression", type: "numeric or string", "Value to output; separate items with ; or ,", optional: true)
            ],
            token: 0x99
        ),
        "INPUT": C64CommandRef(
            keyword: "INPUT",
            category: .statement,
            syntax: "INPUT [\"prompt\";] variable[,variable...]",
            description: "Reads one or more values typed at the keyboard, showing a ? prompt (preceded by the optional prompt string) and waiting for RETURN.",
            example: "INPUT \"YOUR NAME\";N$",
            notes: "The prompt literal must be followed by a semicolon; a comma there is ?SYNTAX ERROR. Typing something non-numeric for a numeric variable prints ?REDO FROM START and re-asks; supplying more values than variables prints ?EXTRA IGNORED; supplying fewer prints ?? and waits for the rest. INPUT cannot be used in direct mode (?ILLEGAL DIRECT ERROR), and commas or colons in typed text split it into separate values -- use GET in a loop when that matters.",
            parameters: [
                C64ParamRef("prompt", type: "string literal", "Text shown before the ? prompt; must be followed by a semicolon", optional: true),
                C64ParamRef("variable", type: "numeric or string variable", "Receives the typed value; several may be listed, comma-separated")
            ],
            token: 0x85
        ),
        "GET": C64CommandRef(
            keyword: "GET",
            category: .statement,
            syntax: "GET variable",
            description: "Takes one character from the keyboard buffer without waiting and without echoing it. A string variable receives an empty string when no key is pending.",
            example: "100 GET A$:IF A$=\"\" THEN 100",
            notes: "The example is the classic wait-for-keypress loop. GET into a numeric variable returns 0 when no key is pending and raises ?SYNTAX ERROR if a non-numeric key is pressed, so GET A$ is almost always the right form. GET cannot be used in direct mode (?ILLEGAL DIRECT ERROR). The pending-key count lives at 198 and the buffer at 631-640; POKE 198,0 flushes it.",
            parameters: [
                C64ParamRef("variable", type: "string or numeric variable", "Receives one character; empty string when no key is waiting")
            ],
            token: 0xA1
        ),
        "READ": C64CommandRef(
            keyword: "READ",
            category: .statement,
            syntax: "READ variable[,variable...]",
            description: "Assigns the next value(s) from the program's DATA statements to the listed variables, advancing the DATA pointer.",
            example: "READ X,Y,C$",
            notes: "Reading past the last DATA value gives ?OUT OF DATA ERROR; reading a non-numeric DATA item into a numeric variable gives ?SYNTAX ERROR reported at the DATA line, not the READ. The pointer is shared by the whole program -- RESTORE resets it to the first DATA statement.",
            parameters: [
                C64ParamRef("variable", type: "numeric or string variable", "Receives the next DATA value; several may be listed")
            ],
            token: 0x87
        ),
        "DATA": C64CommandRef(
            keyword: "DATA",
            category: .statement,
            syntax: "DATA value[,value...]",
            description: "Holds constant values for READ to consume. Values are comma-separated; strings need quotes only when they contain a comma, colon, quote, or leading/trailing spaces.",
            example: "500 DATA 10,20,\"HELLO\",3.14",
            notes: "DATA may appear anywhere; values are consumed in line-number order. An unquoted colon ends the DATA statement, so a colon inside data must be quoted. Two commas in a row supply an empty value (0 or \"\"). DATA is never executed, so it can safely follow END.",
            parameters: [
                C64ParamRef("value", type: "numeric or string constant", "Constant to be picked up by READ")
            ],
            token: 0x83
        ),
        "RESTORE": C64CommandRef(
            keyword: "RESTORE",
            category: .statement,
            syntax: "RESTORE",
            description: "Resets the DATA read pointer to the first DATA statement in the program so the data can be read again.",
            example: "RESTORE",
            notes: "BASIC V2 cannot RESTORE to a specific line -- that form arrived in BASIC 3.5 and 7.0. To reread part of a table, keep the data in an array, or POKE the DATA pointer at 65-66 directly. RUN and CLR also reset the pointer.",
            token: 0x8C
        ),

        // ── File I/O ─────────────────────────────────────────────
        "OPEN": C64CommandRef(
            keyword: "OPEN",
            category: .ioCommand,
            syntax: "OPEN file#, device#[, secondary#[, \"filename[,type[,mode]]\"]]",
            description: "Opens a logical file for input or output. Devices: 0=keyboard, 1=tape, 2=RS-232, 3=screen, 4-7=printer, 8-15=disk drive.",
            example: "OPEN 2,8,2,\"DATA,S,W\"",
            notes: "OPEN 1,8,15 opens the drive's command channel -- PRINT#1 sends a command, INPUT#1 reads the error channel. Secondary address 15 is always the command channel; 0 and 1 are reserved for LOAD and SAVE, so data files use 2-14. File types are S (sequential), P (program), U (user), R (relative); modes are R, W, A (append). A file number of 128-255 makes the KERNAL add a line feed after each carriage return, which some printers need. Reopening a file number that is already open gives ?FILE OPEN ERROR.",
            parameters: [
                C64ParamRef("file#", type: "integer", range: "1-255", "Logical file number used by later PRINT#/INPUT#/GET#/CLOSE"),
                C64ParamRef("device#", type: "integer", range: "0-15", "Device number; 8 is the first disk drive"),
                C64ParamRef("secondary#", type: "integer", range: "0-15", "Channel number; 15 is the disk command channel", optional: true),
                C64ParamRef("filename", type: "string", "Name plus optional ,type and ,mode -- for example \"DATA,S,W\"", optional: true)
            ],
            token: 0x9F
        ),
        "CLOSE": C64CommandRef(
            keyword: "CLOSE",
            category: .ioCommand,
            syntax: "CLOSE file#",
            description: "Closes a logical file previously opened with OPEN, flushing anything still buffered.",
            example: "CLOSE 2",
            notes: "Always close disk files that were written, or the last buffer never reaches the disk and the file is left unclosed (a splat file). Close data channels before the command channel. CLOSE on a file number that is not open is harmless. CLR, RUN, NEW, and LOAD close all open files.",
            parameters: [
                C64ParamRef("file#", type: "integer", range: "1-255", "Logical file number given to OPEN")
            ],
            token: 0xA0
        ),
        "CMD": C64CommandRef(
            keyword: "CMD",
            category: .ioCommand,
            syntax: "CMD file#[, expression]",
            description: "Redirects everything PRINT (and LIST) would send to the screen to an already-open logical file instead.",
            example: "OPEN 4,4:CMD 4:LIST\nPRINT#4:CLOSE 4",
            notes: "The classic way to print a listing. Redirection stays in effect until a PRINT# to that file releases it -- the bare PRINT#4 in the example does that -- so always follow the pattern PRINT#n:CLOSE n. Forgetting it leaves the machine apparently dead, with all output going to the device. The optional expression is sent to the file first, like a PRINT#.",
            parameters: [
                C64ParamRef("file#", type: "integer", range: "1-255", "Logical file number of an already-open file"),
                C64ParamRef("expression", type: "numeric or string", "Optional value sent to the file before redirection begins", optional: true)
            ],
            token: 0x9D
        ),
        "GET#": C64CommandRef(
            keyword: "GET#",
            category: .ioCommand,
            syntax: "GET# file#, variable",
            description: "Reads exactly one character from an open file, including characters INPUT# would treat as separators.",
            example: "GET#2, A$",
            notes: "The only reliable way to read a byte that may be a comma, colon, or carriage return. A CHR$(0) byte arrives as an empty string, so the usual idiom is A=ASC(A$+CHR$(0)). Check ST after each read: ST=64 means end of file. Unlike INPUT# ($84) and PRINT# ($98), GET# is not a token of its own -- the ROM crunches it as GET ($A1) followed by the \"#\" character. It is listed here for completeness.",
            parameters: [
                C64ParamRef("file#", type: "integer", range: "1-255", "Logical file number given to OPEN"),
                C64ParamRef("variable", type: "string or numeric variable", "Receives the single character read")
            ]
        ),
        "INPUT#": C64CommandRef(
            keyword: "INPUT#",
            category: .ioCommand,
            syntax: "INPUT# file#, variable[,variable...]",
            description: "Reads values from an open file, one per variable, exactly as INPUT does from the keyboard but with no prompt.",
            example: "INPUT#2, N$, A",
            notes: "Each value ends at a comma, colon, or carriage return, and is capped at 88 characters (?STRING TOO LONG ERROR beyond that). Because separators are consumed, text containing commas must be read with GET# instead. Check ST after every read -- ST=64 signals end of file, and reading past it returns garbage.",
            parameters: [
                C64ParamRef("file#", type: "integer", range: "1-255", "Logical file number given to OPEN"),
                C64ParamRef("variable", type: "numeric or string variable", "Receives the next value from the file")
            ],
            token: 0x84
        ),
        "PRINT#": C64CommandRef(
            keyword: "PRINT#",
            category: .ioCommand,
            syntax: "PRINT# file#, expression[{;|,}expression...]",
            description: "Writes data to an open file or device instead of the screen.",
            example: "PRINT#2, N$;\",\";A",
            notes: "The keyboard abbreviation is P followed by SHIFT-R; LIST always expands it back to PRINT#. A carriage return is appended unless the statement ends with a semicolon, so a record written in several PRINT# statements needs trailing semicolons on all but the last. Commas insert the same 10-column padding as on screen and are almost never wanted in a file; use explicit \",\" separators as in the example. PRINT#1 on the command channel of a drive opened with secondary 15 sends a disk command.",
            parameters: [
                C64ParamRef("file#", type: "integer", range: "1-255", "Logical file number given to OPEN"),
                C64ParamRef("expression", type: "numeric or string", "Value to write; separate items with ; or ,")
            ],
            token: 0x98
        ),

        // ── Variables & Memory ───────────────────────────────────
        "LET": C64CommandRef(
            keyword: "LET",
            category: .statement,
            syntax: "LET variable = expression",
            description: "Assigns a value to a variable. The keyword is optional -- A=5 and LET A=5 are identical.",
            example: "LET X = 42",
            notes: "Almost always omitted, since it costs a byte and a little speed. Variable names are significant only in their first two characters, so LOOP and LOSS are the same variable, and a name containing a keyword (such as TOTAL, which holds TO) is a ?SYNTAX ERROR.",
            parameters: [
                C64ParamRef("variable", type: "numeric or string variable", "Target of the assignment, including array elements"),
                C64ParamRef("expression", type: "numeric or string", "Value to store; the type must match the variable")
            ],
            token: 0x88
        ),
        "DIM": C64CommandRef(
            keyword: "DIM",
            category: .statement,
            syntax: "DIM variable(size[,size...])[,variable(size)...]",
            description: "Declares one or more arrays and their maximum subscripts. Subscripts start at 0, so DIM A(10) creates 11 elements.",
            example: "DIM A(100), B$(20,5)",
            notes: "An array used without DIM is created automatically with a maximum subscript of 10 in each dimension. DIMensioning an array that already exists gives ?REDIM'D ARRAY ERROR -- CLR (or RUN) is the only way to resize one. The largest subscript is 32767, but memory runs out long before that: a numeric array costs 5 bytes per element, a string array 3 bytes plus the text.",
            parameters: [
                C64ParamRef("variable", type: "array name", "Array to create; the type suffix ($ or %) decides its element type"),
                C64ParamRef("size", type: "integer", range: "0-32767", "Highest valid subscript for this dimension; element count is size+1")
            ],
            token: 0x86
        ),
        "DEF": C64CommandRef(
            keyword: "DEF",
            category: .statement,
            syntax: "DEF FN name(variable) = expression",
            description: "Defines a single-expression user function that can then be called with FN.",
            example: "DEF FN R(X) = INT(RND(1)*X)+1",
            notes: "Only one parameter is allowed, and only numeric functions -- there is no string equivalent. DEF cannot be used in direct mode (?ILLEGAL DIRECT ERROR) and must execute before the first call. The parameter name is a real variable: calling the function overwrites it. Other variables in the expression are read at call time, so they act as free variables.",
            parameters: [
                C64ParamRef("name", type: "identifier", "Function name, subject to the same two-significant-character rule as variables"),
                C64ParamRef("variable", type: "numeric variable", "The single parameter; the same variable is used to pass the argument"),
                C64ParamRef("expression", type: "numeric", "Body of the function, evaluated at each call")
            ],
            token: 0x96
        ),
        "FN": C64CommandRef(
            keyword: "FN",
            category: .function,
            syntax: "FN name(argument)",
            description: "Calls a user function previously created with DEF FN. The argument is assigned to the function's parameter variable and the body expression is evaluated.",
            example: "DEF FN SQ(X) = X*X\nPRINT FN SQ(7)  : REM PRINTS 49",
            notes: "FN is its own token ($A5), distinct from DEF ($96). Calling a function that was never defined gives ?UNDEF'D FUNCTION ERROR. A function call is somewhat slower than writing the expression inline, but far more readable.",
            parameters: [
                C64ParamRef("name", type: "identifier", "Name used in the matching DEF FN"),
                C64ParamRef("argument", type: "numeric", "Value assigned to the function's parameter variable")
            ],
            token: 0xA5
        ),
        "POKE": C64CommandRef(
            keyword: "POKE",
            category: .statement,
            syntax: "POKE address, value",
            description: "Writes a single byte to a memory address. The primary way to drive C64 hardware from BASIC.",
            example: "POKE 53280,0 : REM BLACK BORDER",
            notes: "Key addresses: 53280=border color, 53281=background, 646=current text color, 1024-2023=screen memory, 55296-56295=color RAM, 53248-53294=VIC-II sprites, 54272-54300=SID. An address outside 0-65535 or a value outside 0-255 gives ?ILLEGAL QUANTITY ERROR. POKEing into 0-1, the I/O area, or over BASIC's own workspace can hang the machine.",
            parameters: [
                C64ParamRef("address", type: "integer", range: "0-65535", "Destination address; writes to RAM under ROM go to the RAM"),
                C64ParamRef("value", type: "integer", range: "0-255", "Byte to store")
            ],
            token: 0x97
        ),
        "PEEK": C64CommandRef(
            keyword: "PEEK",
            category: .function,
            syntax: "PEEK(address)",
            description: "Returns the byte (0-255) stored at a memory address.",
            example: "X = PEEK(53280) AND 15 : REM BORDER COLOR",
            notes: "Reads see whatever is currently banked in, so PEEK in the $A000-$BFFF and $E000-$FFFF ranges returns ROM, not the RAM underneath. Useful addresses: 56320/56321=joystick ports 2/1, 197=key currently held, 198=keyboard buffer length, 53266=raster line low byte. VIC-II registers with a 16-bit meaning need masking, as in the example.",
            parameters: [
                C64ParamRef("address", type: "integer", range: "0-65535", "Address to read")
            ],
            token: 0xC2
        ),
        "SYS": C64CommandRef(
            keyword: "SYS",
            category: .statement,
            syntax: "SYS address",
            description: "Calls a machine language routine at the given address, returning to BASIC when the routine hits RTS.",
            example: "SYS 49152 : REM CALL ML AT $C000",
            notes: "Registers are loaded from 780 (A), 781 (X), 782 (Y) and 783 (status) before the call, and the values on return are stored back into the same locations -- POKE them before SYS to pass arguments. $C000-$CFFF (49152-53247) is the usual home for machine code, since BASIC never touches it. SYS 64738 performs a cold reset.",
            parameters: [
                C64ParamRef("address", type: "integer", range: "0-65535", "Entry point of the routine to call")
            ],
            token: 0x9E
        ),
        "USR": C64CommandRef(
            keyword: "USR",
            category: .function,
            syntax: "USR(value)",
            description: "Calls the machine language routine whose address is stored at 785-786, passing a floating-point argument and returning a floating-point result.",
            example: "POKE 785,0:POKE 786,192 : REM VECTOR TO $C000\nA = USR(42)",
            notes: "Set the vector at 785 (low byte) and 786 (high byte) before the first call; the default vector points at an error routine. The argument arrives in floating-point accumulator 1 at 97-101, and whatever the routine leaves there becomes the result. SYS is simpler and far more common; USR is only worth it when a value has to come back.",
            parameters: [
                C64ParamRef("value", type: "numeric", "Argument passed to the routine in floating-point accumulator 1")
            ],
            token: 0xB7
        ),
        "WAIT": C64CommandRef(
            keyword: "WAIT",
            category: .statement,
            syntax: "WAIT address, mask[, invertmask]",
            description: "Halts the program until a memory location, exclusive-ORed with invertmask and ANDed with mask, becomes non-zero.",
            example: "WAIT 198,1 : REM WAIT FOR A KEYPRESS",
            notes: "The exact test is (PEEK(address) XOR invertmask) AND mask <> 0, with invertmask defaulting to 0. Nothing else runs while waiting and RUN/STOP will not break out, so a condition that never comes true locks the machine -- a GET loop is usually the safer choice. Classic use is WAIT 53265,128 to synchronize with the raster.",
            parameters: [
                C64ParamRef("address", type: "integer", range: "0-65535", "Location to poll"),
                C64ParamRef("mask", type: "integer", range: "0-255", "Bits to test; the wait ends when any of them is set"),
                C64ParamRef("invertmask", type: "integer", range: "0-255", "Bits to invert before testing, so the wait can trigger on a zero bit", optional: true)
            ],
            token: 0x92
        ),

        // ── Program Management ───────────────────────────────────
        "NEW": C64CommandRef(
            keyword: "NEW",
            category: .statement,
            syntax: "NEW",
            description: "Erases the program in memory along with all variables, leaving an empty workspace.",
            example: "NEW",
            notes: "NEW only resets BASIC's pointers and zeroes the first program bytes -- the rest of the text is still in memory, so a program erased by accident can often be recovered with a monitor or an unnew routine. NEW also closes open files. Used inside a program it stops execution.",
            token: 0xA2
        ),
        "CLR": C64CommandRef(
            keyword: "CLR",
            category: .statement,
            syntax: "CLR",
            description: "Clears all variables and arrays, resets the DATA pointer, empties the GOSUB and FOR stacks, and closes open files -- without touching the program.",
            example: "CLR",
            notes: "The only way to redimension an array. Because it discards the GOSUB and FOR stacks, CLR inside a subroutine or loop makes the eventual RETURN or NEXT fail. RUN performs a CLR automatically.",
            token: 0x9C
        ),
        "LIST": C64CommandRef(
            keyword: "LIST",
            category: .statement,
            syntax: "LIST [start_line][-[end_line]]",
            description: "Displays program lines, optionally limited to a range.",
            example: "LIST 100-200",
            notes: "LIST 100- lists from line 100 to the end, LIST -100 from the start to line 100, and LIST 100 just that line. Hold CTRL to slow the listing or press RUN/STOP to abort it. LIST used inside a program lists and then ends the program, which is why CMD..LIST works for printing.",
            parameters: [
                C64ParamRef("start_line", type: "integer", range: "0-63999", "First line to list; defaults to the beginning", optional: true),
                C64ParamRef("end_line", type: "integer", range: "0-63999", "Last line to list; defaults to the end", optional: true)
            ],
            token: 0x9B
        ),
        "SAVE": C64CommandRef(
            keyword: "SAVE",
            category: .statement,
            syntax: "SAVE \"filename\"[,device#[,secondary#]]",
            description: "Writes the BASIC program in memory to tape or disk.",
            example: "SAVE \"MYGAME\",8",
            notes: "The device defaults to 1 (tape); 8 is the first disk drive. Saving over an existing disk file fails with FILE EXISTS on the error channel -- use SAVE \"@0:NAME\",8 to replace it, though the 1541's save-with-replace bug makes scratch-then-save safer. On tape, secondary address 2 (SAVE \"NAME\",1,2) appends an end-of-tape marker; the disk drive ignores the secondary address. Filenames are limited to 16 characters.",
            parameters: [
                C64ParamRef("filename", type: "string", "Name to save under, up to 16 characters"),
                C64ParamRef("device#", type: "integer", range: "1-15", "Device number; defaults to 1 (tape)", optional: true),
                C64ParamRef("secondary#", type: "integer", range: "0-15", "Tape only: 2 appends an end-of-tape marker", optional: true)
            ],
            token: 0x94
        ),
        "LOAD": C64CommandRef(
            keyword: "LOAD",
            category: .statement,
            syntax: "LOAD \"filename\"[,device#[,secondary#]]",
            description: "Loads a program from tape or disk into memory.",
            example: "LOAD \"MYGAME\",8,1",
            notes: "Secondary address 0 (the default) relocates the file to the start of BASIC at $0801; secondary address 1 loads it back to the address stored in the file's first two bytes, which is what machine code needs. LOAD \"$\",8 reads the directory into memory as a BASIC program, destroying whatever was there. LOAD used inside a program loads the new file and restarts it from the first line with the variables intact -- the standard way to chain programs. A pattern such as LOAD \"*\",8,1 loads the first matching file.",
            parameters: [
                C64ParamRef("filename", type: "string", "Name to load; * and ? wildcards are accepted on disk"),
                C64ParamRef("device#", type: "integer", range: "1-15", "Device number; defaults to 1 (tape)", optional: true),
                C64ParamRef("secondary#", type: "integer", range: "0-1", "0 relocates to the BASIC start, 1 loads to the file's own address", optional: true)
            ],
            token: 0x93
        ),
        "VERIFY": C64CommandRef(
            keyword: "VERIFY",
            category: .statement,
            syntax: "VERIFY \"filename\"[,device#[,secondary#]]",
            description: "Compares the program in memory byte for byte with a file on tape or disk.",
            example: "VERIFY \"MYGAME\",8",
            notes: "Prints OK when the two match and ?VERIFY ERROR when they do not. Worth doing after every tape save. A mismatch is also reported if the program has been relocated since it was saved, so VERIFY after a LOAD of machine code is not meaningful.",
            parameters: [
                C64ParamRef("filename", type: "string", "Name of the file to compare against"),
                C64ParamRef("device#", type: "integer", range: "1-15", "Device number; defaults to 1 (tape)", optional: true),
                C64ParamRef("secondary#", type: "integer", range: "0-1", "Matches the secondary address used when saving", optional: true)
            ],
            token: 0x95
        ),
        "REM": C64CommandRef(
            keyword: "REM",
            category: .statement,
            syntax: "REM [comment text]",
            description: "Remark. Everything after REM to the end of the physical line is ignored, including colons.",
            example: "100 REM === MAIN GAME LOOP ===",
            notes: "Because a colon does not end a REM, no statement can follow one on the same line. A GOTO or GOSUB may target a REM line, which is a common way to label a routine. Comments cost memory and a little speed on every pass, so tight loops are usually left bare. Anything typed after REM is stored literally, so keywords inside a comment are not tokenized.",
            parameters: [
                C64ParamRef("comment text", type: "text", "Free text, ignored by the interpreter", optional: true)
            ],
            token: 0x8F
        ),

        // ── Math Functions ───────────────────────────────────────
        "ABS": C64CommandRef(
            keyword: "ABS",
            category: .function,
            syntax: "ABS(number)",
            description: "Returns the absolute value of a number -- the number with any minus sign removed.",
            example: "PRINT ABS(-42)  : REM PRINTS 42",
            notes: "ABS(A-B) is the usual way to test whether two values are within a tolerance of each other: IF ABS(A-B)<.01 THEN ...",
            parameters: [
                C64ParamRef("number", type: "numeric", "Value whose magnitude is wanted")
            ],
            token: 0xB6
        ),
        "ATN": C64CommandRef(
            keyword: "ATN",
            category: .function,
            syntax: "ATN(number)",
            description: "Returns the arctangent of a number, in radians, in the range -PI/2 to PI/2.",
            example: "PI = 4*ATN(1) : REM 3.14159265",
            notes: "The classic way to obtain PI on the C64, though the PI key (shifted up-arrow) is a built-in constant that costs one byte and no computation. ATN alone only covers two quadrants, so recovering a full 0-to-2*PI angle from an X,Y offset needs a quadrant test on the signs of X and Y.",
            parameters: [
                C64ParamRef("number", type: "numeric", "Tangent value to invert")
            ],
            token: 0xC1
        ),
        "COS": C64CommandRef(
            keyword: "COS",
            category: .function,
            syntax: "COS(angle)",
            description: "Returns the cosine of an angle given in radians.",
            example: "X = 160 + COS(A) * R",
            notes: "Angles are radians, not degrees: multiply degrees by PI/180 first. Trigonometric functions are slow in BASIC, so anything animated normally precomputes a table into an array.",
            parameters: [
                C64ParamRef("angle", type: "numeric", "Angle in radians")
            ],
            token: 0xBE
        ),
        "EXP": C64CommandRef(
            keyword: "EXP",
            category: .function,
            syntax: "EXP(number)",
            description: "Returns e (2.71828183) raised to the given power.",
            example: "PRINT EXP(1) : REM PRINTS 2.71828183",
            notes: "?OVERFLOW ERROR for arguments above 88.0296919. EXP and LOG are inverses, so EXP(LOG(X)) returns X for any positive X.",
            parameters: [
                C64ParamRef("number", type: "numeric", range: "up to 88.0296919", "Exponent to raise e to")
            ],
            token: 0xBD
        ),
        "INT": C64CommandRef(
            keyword: "INT",
            category: .function,
            syntax: "INT(number)",
            description: "Returns the largest whole number that is not greater than the argument -- a floor, not a truncation.",
            example: "PRINT INT(3.7)  : REM PRINTS 3\nPRINT INT(-3.7) : REM PRINTS -4",
            notes: "Negative values round away from zero: INT(-3.7) is -4, not -3. To round to the nearest whole number use INT(X+.5), and to truncate toward zero use SGN(X)*INT(ABS(X)). INT(X*100+.5)/100 rounds to two decimal places.",
            parameters: [
                C64ParamRef("number", type: "numeric", "Value to floor")
            ],
            token: 0xB5
        ),
        "LOG": C64CommandRef(
            keyword: "LOG",
            category: .function,
            syntax: "LOG(number)",
            description: "Returns the natural logarithm (base e) of a positive number.",
            example: "PRINT LOG(10) : REM PRINTS 2.30258509",
            notes: "?ILLEGAL QUANTITY ERROR for zero or negative arguments. For a logarithm in another base, divide: base-10 is LOG(X)/LOG(10), base-2 is LOG(X)/LOG(2).",
            parameters: [
                C64ParamRef("number", type: "numeric", range: "greater than 0", "Value whose logarithm is wanted")
            ],
            token: 0xBC
        ),
        "RND": C64CommandRef(
            keyword: "RND",
            category: .function,
            syntax: "RND(number)",
            description: "Returns a pseudo-random value from 0 up to but not including 1. The argument selects the behavior: a positive value advances the generator and returns the next number in the sequence; zero derives a value from the CIA hardware timers; a negative value reseeds the generator from that number and returns the first value of the resulting sequence.",
            example: "X = INT(RND(1)*6)+1 : REM DICE ROLL 1-6",
            notes: "RND(1) is the everyday form. The generator starts from the same seed at every power-on, so an unseeded game deals the same 'random' numbers each run -- call RND(-TI) once at startup to seed from the clock, or RND(0) to seed from the CIA timers, then use RND(1) thereafter. Reseeding with the same negative value reproduces a sequence exactly, which is useful for testing. The general form for an integer in A..B is INT(RND(1)*(B-A+1))+A.",
            parameters: [
                C64ParamRef("number", type: "numeric", "Positive advances the sequence, 0 reads the CIA timers, negative reseeds from the value")
            ],
            token: 0xBB
        ),
        "SGN": C64CommandRef(
            keyword: "SGN",
            category: .function,
            syntax: "SGN(number)",
            description: "Returns the sign of a number: -1 when negative, 0 when zero, 1 when positive.",
            example: "ON SGN(X)+2 GOTO 100,200,300",
            notes: "Adding 2 turns the -1/0/1 result into the 1/2/3 index that ON..GOTO needs, as in the example. SGN(X)*INT(ABS(X)) truncates toward zero rather than flooring like INT.",
            parameters: [
                C64ParamRef("number", type: "numeric", "Value whose sign is wanted")
            ],
            token: 0xB4
        ),
        "SIN": C64CommandRef(
            keyword: "SIN",
            category: .function,
            syntax: "SIN(angle)",
            description: "Returns the sine of an angle given in radians.",
            example: "Y = 100 + SIN(A) * R",
            notes: "Angles are radians: degrees must be multiplied by PI/180 first. As with COS, precompute a table when speed matters.",
            parameters: [
                C64ParamRef("angle", type: "numeric", "Angle in radians")
            ],
            token: 0xBF
        ),
        "SQR": C64CommandRef(
            keyword: "SQR",
            category: .function,
            syntax: "SQR(number)",
            description: "Returns the square root of a non-negative number.",
            example: "PRINT SQR(144) : REM PRINTS 12",
            notes: "?ILLEGAL QUANTITY ERROR for negative arguments. SQR is computed with logarithms internally, so distance tests that only need a comparison run much faster when both sides are squared instead: IF DX*DX+DY*DY < R*R THEN ...",
            parameters: [
                C64ParamRef("number", type: "numeric", range: "0 or greater", "Value whose square root is wanted")
            ],
            token: 0xBA
        ),
        "TAN": C64CommandRef(
            keyword: "TAN",
            category: .function,
            syntax: "TAN(angle)",
            description: "Returns the tangent of an angle given in radians.",
            example: "PRINT TAN(.7853981) : REM APPROXIMATELY 1",
            notes: "Angles are radians. Near PI/2 the true tangent is infinite, so TAN there returns a very large value or gives ?DIVISION BY ZERO ERROR.",
            parameters: [
                C64ParamRef("angle", type: "numeric", "Angle in radians")
            ],
            token: 0xC0
        ),

        // ── String Functions ─────────────────────────────────────
        "ASC": C64CommandRef(
            keyword: "ASC",
            category: .function,
            syntax: "ASC(string$)",
            description: "Returns the PETSCII code of the first character of a string.",
            example: "PRINT ASC(\"A\") : REM PRINTS 65",
            notes: "?ILLEGAL QUANTITY ERROR on an empty string, which is why bytes read with GET# are usually converted as ASC(A$+CHR$(0)). The codes are PETSCII, not ASCII -- unshifted letters and digits happen to agree, but the graphics characters and the case pairs do not.",
            parameters: [
                C64ParamRef("string$", type: "string", "String whose first character is examined; must not be empty")
            ],
            token: 0xC6
        ),
        "CHR$": C64CommandRef(
            keyword: "CHR$",
            category: .function,
            syntax: "CHR$(code)",
            description: "Returns a one-character string for the given PETSCII code.",
            example: "PRINT CHR$(147) : REM CLEAR SCREEN",
            notes: "Common codes: 5=white, 13=return, 14=lower case, 17=cursor down, 18=reverse on, 19=home, 20=delete, 142=upper case, 145=cursor up, 146=reverse off, 147=clear screen, 157=cursor left. CHR$(34) is a quote, and printing it puts the screen editor into quote mode, so cursor controls sent afterwards appear as reverse characters instead of moving the cursor.",
            parameters: [
                C64ParamRef("code", type: "integer", range: "0-255", "PETSCII code of the character to build")
            ],
            token: 0xC7
        ),
        "LEFT$": C64CommandRef(
            keyword: "LEFT$",
            category: .function,
            syntax: "LEFT$(string$, count)",
            description: "Returns the leftmost count characters of a string.",
            example: "PRINT LEFT$(\"HELLO\",3) : REM HEL",
            notes: "A count of 0 returns an empty string, and a count at or beyond the string's length returns the whole string. ?ILLEGAL QUANTITY ERROR if count is above 255. LEFT$(A$+\"          \",10) is the standard way to pad a field to a fixed width.",
            parameters: [
                C64ParamRef("string$", type: "string", "Source string"),
                C64ParamRef("count", type: "integer", range: "0-255", "Number of characters to take from the left")
            ],
            token: 0xC8
        ),
        "LEN": C64CommandRef(
            keyword: "LEN",
            category: .function,
            syntax: "LEN(string$)",
            description: "Returns the number of characters in a string, from 0 to 255.",
            example: "IF LEN(N$) > 16 THEN PRINT \"TOO LONG\"",
            notes: "Strings are limited to 255 characters; building a longer one gives ?STRING TOO LONG ERROR. LEN counts characters including cursor controls and other non-printing codes.",
            parameters: [
                C64ParamRef("string$", type: "string", "String to measure")
            ],
            token: 0xC3
        ),
        "MID$": C64CommandRef(
            keyword: "MID$",
            category: .function,
            syntax: "MID$(string$, start[, count])",
            description: "Returns a substring beginning at position start (1-based), of count characters, or to the end of the string when count is omitted.",
            example: "PRINT MID$(\"HELLO\",2,3) : REM ELL",
            notes: "Positions are 1-based. A start beyond the end of the string returns an empty string; ?ILLEGAL QUANTITY ERROR if start is 0 or above 255. BASIC V2 has no MID$ on the left of an assignment -- to replace characters in place, rebuild the string with LEFT$ and MID$. Scanning a string one character at a time with MID$(A$,I,1) is the usual parsing loop.",
            parameters: [
                C64ParamRef("string$", type: "string", "Source string"),
                C64ParamRef("start", type: "integer", range: "1-255", "1-based position of the first character to take"),
                C64ParamRef("count", type: "integer", range: "0-255", "Number of characters; defaults to the rest of the string", optional: true)
            ],
            token: 0xCA
        ),
        "RIGHT$": C64CommandRef(
            keyword: "RIGHT$",
            category: .function,
            syntax: "RIGHT$(string$, count)",
            description: "Returns the rightmost count characters of a string.",
            example: "PRINT RIGHT$(\"HELLO\",3) : REM LLO",
            notes: "A count of 0 returns an empty string and a count at or beyond the length returns the whole string. ?ILLEGAL QUANTITY ERROR if count is above 255. RIGHT$(\"00\"+MID$(STR$(N),2),2) is a compact way to zero-pad a number to a fixed width.",
            parameters: [
                C64ParamRef("string$", type: "string", "Source string"),
                C64ParamRef("count", type: "integer", range: "0-255", "Number of characters to take from the right")
            ],
            token: 0xC9
        ),
        "STR$": C64CommandRef(
            keyword: "STR$",
            category: .function,
            syntax: "STR$(number)",
            description: "Converts a number to the string BASIC would print for it, including the leading space that stands in for a plus sign.",
            example: "A$ = STR$(42) : REM A$ = \" 42\"",
            notes: "Negative numbers get a leading minus instead of the space. MID$(STR$(X),2) strips the sign position from a positive number. Large or small values come back in exponent form, such as \" 1.5E+09\".",
            parameters: [
                C64ParamRef("number", type: "numeric", "Value to convert to text")
            ],
            token: 0xC4
        ),
        "VAL": C64CommandRef(
            keyword: "VAL",
            category: .function,
            syntax: "VAL(string$)",
            description: "Converts the leading numeric part of a string to a number, stopping at the first character that cannot be part of a number.",
            example: "PRINT VAL(\"3.14ABC\") : REM 3.14",
            notes: "Returns 0 when the string does not begin with a digit, sign, or decimal point, so VAL cannot by itself distinguish \"0\" from \"XYZ\". Leading spaces are skipped, and exponent notation such as \"1E3\" is understood. VAL(STR$(X)) round-trips a number exactly.",
            parameters: [
                C64ParamRef("string$", type: "string", "Text to interpret as a number")
            ],
            token: 0xC5
        ),

        // ── Other Functions ──────────────────────────────────────
        "FRE": C64CommandRef(
            keyword: "FRE",
            category: .function,
            syntax: "FRE(0)",
            description: "Returns the number of bytes still free for BASIC, after first collecting abandoned strings.",
            example: "PRINT FRE(0)-65536*(FRE(0)<0) : REM BYTES FREE",
            notes: "The result is a signed 16-bit value, so anything above 32767 comes back negative -- the example's correction turns it back into the real figure. The argument is ignored but must be present. Calling FRE forces string garbage collection, which on a program with many strings can freeze the machine for several seconds; that is also the point of calling it deliberately at a quiet moment.",
            parameters: [
                C64ParamRef("0", type: "numeric", "Ignored, but required by the syntax")
            ],
            token: 0xB8
        ),
        "POS": C64CommandRef(
            keyword: "POS",
            category: .function,
            syntax: "POS(0)",
            description: "Returns the cursor's column within the current logical line, counting from 0.",
            example: "IF POS(0) > 35 THEN PRINT",
            notes: "A logical line spans two screen rows when text has wrapped, so the value runs 0-39 on an unwrapped line and up to 79 on a wrapped one. The argument is ignored but must be present. Handy for deciding when to break a line of output, as in the example.",
            parameters: [
                C64ParamRef("0", type: "numeric", "Ignored, but required by the syntax")
            ],
            token: 0xB9
        ),

        // ── System Variables ─────────────────────────────────────
        "TI": C64CommandRef(
            keyword: "TI",
            category: .systemVar,
            syntax: "TI",
            description: "The jiffy clock: a counter that increases by one every 1/60 second, starting from 0 at power-on and wrapping after 24 hours (5184000 jiffies).",
            example: "T=TI : REM MARK START\nGOSUB 900\nPRINT (TI-T)/60;\"SECONDS\"",
            notes: "TI cannot be assigned -- set TI$ instead, which resets both. The count is maintained by the 60 Hz interrupt, so it stops advancing during tape operations and any other code that disables interrupts, and time is lost rather than made up. TI is not a token: the ROM recognises it as a reserved variable name, which is why a variable of your own cannot start with TI.",
            token: nil
        ),
        "TI$": C64CommandRef(
            keyword: "TI$",
            category: .systemVar,
            syntax: "TI$ | TI$ = \"HHMMSS\"",
            description: "The jiffy clock as a six-character string in 24-hour HHMMSS form. Unlike TI, it can be assigned.",
            example: "TI$ = \"120000\" : REM SET TO NOON",
            notes: "The value assigned must be exactly six digits, or ?ILLEGAL QUANTITY ERROR follows. Setting TI$ also sets TI, and TI$=\"000000\" is the usual way to zero the clock before timing something. Nothing is battery-backed, so the clock restarts at 000000 at every power-on and loses time during tape I/O.",
            parameters: [
                C64ParamRef("\"HHMMSS\"", type: "string", range: "exactly 6 digits", "New clock value when assigning; hours, minutes, seconds", optional: true)
            ],
            token: nil
        ),
        "ST": C64CommandRef(
            keyword: "ST",
            category: .systemVar,
            syntax: "ST",
            description: "The I/O status byte, updated by the KERNAL after every input or output operation.",
            example: "IF ST AND 64 THEN PRINT \"END OF FILE\"",
            notes: "For serial devices such as disk drives: 2=read timeout, 4=write timeout, 64 (bit 6)=end of file, -128 (bit 7)=device not present. For tape: 4=short block, 8=long block, 16=unrecoverable read error, 32=checksum error. ST must be tested straight after the operation, since the next I/O overwrites it -- including the PRINT that reports it. Like TI, ST is a reserved variable name rather than a token.",
            token: nil
        ),

        // ── Operators ────────────────────────────────────────────
        "+": C64CommandRef(
            keyword: "+",
            category: .operator_,
            syntax: "expression + expression",
            description: "Adds two numbers, or joins (concatenates) two strings.",
            example: "PRINT 2+3 : REM 5\nA$ = \"HELLO \" + \"WORLD\"",
            notes: "Mixing a number and a string gives ?TYPE MISMATCH ERROR. Concatenating past 255 characters gives ?STRING TOO LONG ERROR. Repeated concatenation in a loop leaves abandoned copies behind and eventually triggers a long garbage-collection pause.",
            parameters: [
                C64ParamRef("expression", type: "numeric or string", "Both operands must be the same type")
            ],
            token: 0xAA
        ),
        "-": C64CommandRef(
            keyword: "-",
            category: .operator_,
            syntax: "expression - expression | -expression",
            description: "Subtracts one number from another, or negates a single number when used as a prefix.",
            example: "PRINT 10-3 : REM 7\nX = -Y",
            notes: "Subtraction and negation share the same token ($AB); the ROM decides between them from context. Negation binds more tightly than the arithmetic operators but less tightly than ^, so -2^2 evaluates as -(2^2), which is -4.",
            parameters: [
                C64ParamRef("expression", type: "numeric", "Operand; strings are not accepted")
            ],
            token: 0xAB
        ),
        "*": C64CommandRef(
            keyword: "*",
            category: .operator_,
            syntax: "expression * expression",
            description: "Multiplies two numbers.",
            example: "PRINT 6*7 : REM 42",
            notes: "Multiplication and division bind more tightly than addition and subtraction, and less tightly than ^. Multiplying by a power of two is the fast way to shift bits left, as in V=V*2.",
            parameters: [
                C64ParamRef("expression", type: "numeric", "Operands to multiply")
            ],
            token: 0xAC
        ),
        "/": C64CommandRef(
            keyword: "/",
            category: .operator_,
            syntax: "expression / expression",
            description: "Divides one number by another, always producing a floating-point result.",
            example: "PRINT 7/2 : REM 3.5",
            notes: "There is no integer-division operator: use INT(A/B) for the quotient and A-B*INT(A/B) for the remainder. Dividing by zero gives ?DIVISION BY ZERO ERROR. Division is the slowest of the four arithmetic operations, so a repeated /2 is worth replacing with *.5.",
            parameters: [
                C64ParamRef("expression", type: "numeric", "Dividend and divisor; the divisor must not be zero")
            ],
            token: 0xAD
        ),
        "^": C64CommandRef(
            keyword: "^",
            category: .operator_,
            syntax: "base ^ exponent",
            description: "Raises a number to a power. On the C64 keyboard this is the up-arrow key, to the right of the minus key.",
            example: "PRINT 2^10 : REM 1024",
            notes: "Exponentiation binds most tightly of all the arithmetic operators, so 2*3^2 is 18. It is computed with logarithms, which makes it both slow and slightly inexact, so X*X is far faster and more precise than X^2. A negative base with a fractional exponent gives ?ILLEGAL QUANTITY ERROR. LIST shows the up-arrow character, not a caret.",
            parameters: [
                C64ParamRef("base", type: "numeric", "Value to raise"),
                C64ParamRef("exponent", type: "numeric", "Power to raise it to")
            ],
            token: 0xAE
        ),
        "AND": C64CommandRef(
            keyword: "AND",
            category: .operator_,
            syntax: "expression AND expression",
            description: "Bitwise AND of two values, used both for combining conditions and for masking bits.",
            example: "IF X>0 AND X<100 THEN PRINT \"IN RANGE\"",
            notes: "Comparisons yield -1 for true (all bits set) and 0 for false, so a bitwise AND of two comparisons behaves exactly like a logical one. As a mask it works on 16-bit signed integers: PRINT 255 AND 15 gives 15, and PEEK(53280) AND 15 extracts the border color. Operands outside -32768..32767 give ?ILLEGAL QUANTITY ERROR. AND binds less tightly than the comparison operators, so the example needs no parentheses.",
            parameters: [
                C64ParamRef("expression", type: "integer", range: "-32768 to 32767", "Values to combine bit by bit")
            ],
            token: 0xAF
        ),
        "OR": C64CommandRef(
            keyword: "OR",
            category: .operator_,
            syntax: "expression OR expression",
            description: "Bitwise OR of two values: true when either condition holds, or, as a mask, sets bits.",
            example: "IF A=1 OR A=2 THEN PRINT \"ONE OR TWO\"",
            notes: "As a mask: PRINT 240 OR 15 gives 255, and POKE 53265,PEEK(53265) OR 32 sets the bitmap bit without disturbing the others. Works on 16-bit signed integers, so operands outside -32768..32767 give ?ILLEGAL QUANTITY ERROR. OR binds less tightly than AND.",
            parameters: [
                C64ParamRef("expression", type: "integer", range: "-32768 to 32767", "Values to combine bit by bit")
            ],
            token: 0xB0
        ),
        "NOT": C64CommandRef(
            keyword: "NOT",
            category: .operator_,
            syntax: "NOT expression",
            description: "Bitwise complement of a value, which in a condition inverts true and false.",
            example: "IF NOT A THEN PRINT \"A IS ZERO\"",
            notes: "NOT 0 is -1 and NOT -1 is 0, which is exactly the true/false convention comparisons use. The complement is taken over a 16-bit signed integer, so NOT 5 is -6. Clearing a bit is done with AND and a complemented mask: POKE 53265,PEEK(53265) AND NOT 32.",
            parameters: [
                C64ParamRef("expression", type: "integer", range: "-32768 to 32767", "Value to complement")
            ],
            token: 0xA8
        ),
        "=": C64CommandRef(
            keyword: "=",
            category: .operator_,
            syntax: "variable = expression | expression = expression",
            description: "Assignment in a LET statement, and equality comparison inside an expression. Both use the same token.",
            example: "A = 5 : REM ASSIGNMENT\nIF A = 5 THEN PRINT \"YES\" : REM COMPARISON",
            notes: "The ROM tells the two uses apart by position: the first = in a statement is an assignment, any later one is a comparison, so B = A = 5 stores -1 in B when A is 5. Combined with < or > it forms <= and >=, which are two tokens, not one. Comparing floating-point results for exact equality is unreliable -- compare a difference against a tolerance instead.",
            parameters: [
                C64ParamRef("expression", type: "numeric or string", "Operands must be the same type; strings compare in PETSCII order")
            ],
            token: 0xB2
        ),
        "<": C64CommandRef(
            keyword: "<",
            category: .operator_,
            syntax: "expression < expression",
            description: "Less-than comparison, returning -1 when true and 0 when false.",
            example: "IF X < 10 THEN PRINT \"SMALL\"",
            notes: "<= and <> are written as two characters and stored as two tokens: <= is $B3 $B2 and <> is $B3 $B1. The order of the characters matters -- =< and >< are ?SYNTAX ERROR. Strings compare character by character in PETSCII order, with a shorter string sorting before a longer one that starts the same way.",
            parameters: [
                C64ParamRef("expression", type: "numeric or string", "Operands must be the same type")
            ],
            token: 0xB3
        ),
        ">": C64CommandRef(
            keyword: ">",
            category: .operator_,
            syntax: "expression > expression",
            description: "Greater-than comparison, returning -1 when true and 0 when false.",
            example: "IF SC > HI THEN HI = SC",
            notes: ">= is two tokens ($B1 $B2), as is <> ($B3 $B1). Because true is -1, a comparison can be used arithmetically: S = S - (X>0) adds one to S whenever X is positive, which is faster than an IF.",
            parameters: [
                C64ParamRef("expression", type: "numeric or string", "Operands must be the same type")
            ],
            token: 0xB1
        ),

        // ── Screen/Output ────────────────────────────────────────
        "TAB": C64CommandRef(
            keyword: "TAB",
            category: .function,
            syntax: "PRINT TAB(column);expression",
            description: "Inside a PRINT statement, moves the cursor to an absolute column of the current logical line.",
            example: "PRINT TAB(10);\"HELLO\"",
            notes: "TAB only moves forward -- if the cursor is already past the requested column nothing happens, so a column that has scrolled by is simply ignored. Valid only in PRINT; elsewhere it gives ?SYNTAX ERROR. The token ($A3) includes the opening parenthesis, so TAB (10) with a space is not recognized. Use SPC for a relative move.",
            parameters: [
                C64ParamRef("column", type: "integer", range: "0-255", "Absolute column to move to, counted from 0")
            ],
            token: 0xA3
        ),
        "SPC": C64CommandRef(
            keyword: "SPC",
            category: .function,
            syntax: "PRINT SPC(count);expression",
            description: "Inside a PRINT statement, advances the cursor a number of columns from wherever it currently is.",
            example: "PRINT SPC(5);\"INDENTED\"",
            notes: "Relative, unlike TAB's absolute move. On the screen the skipped columns are left as they were rather than blanked, so SPC does not erase; to overwrite, print actual spaces. Valid only in PRINT. The token ($A6) includes the opening parenthesis, so SPC (5) with a space is not recognized.",
            parameters: [
                C64ParamRef("count", type: "integer", range: "0-255", "Number of columns to skip")
            ],
            token: 0xA6
        ),
    ]

    // MARK: - Tokenization

    /// Tokenizes a line of C64 BASIC for syntax highlighting.
    /// - Parameter line: The raw source line to tokenize.
    /// - Returns: An array of `SyntaxToken` representing the line's structure.
    static func tokenize(_ line: String) -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        let nsLine = line as NSString
        let length = nsLine.length
        var pos = 0

        // Skip leading whitespace
        while pos < length && nsLine.character(at: pos) == 0x20 { pos += 1 }

        // Check for line number at start
        let lineNumStart = pos
        while pos < length && CharacterSet.decimalDigits.contains(Unicode.Scalar(nsLine.character(at: pos))!) {
            pos += 1
        }
        if pos > lineNumStart {
            tokens.append(SyntaxToken(
                range: NSRange(location: lineNumStart, length: pos - lineNumStart),
                type: .lineNumber,
                text: nsLine.substring(with: NSRange(location: lineNumStart, length: pos - lineNumStart))
            ))
        }

        // Skip space after line number
        while pos < length && nsLine.character(at: pos) == 0x20 { pos += 1 }

        // Check for REM — rest of line is a comment
        if pos + 3 <= length {
            let possibleRem = nsLine.substring(with: NSRange(location: pos, length: min(3, length - pos))).uppercased()
            if possibleRem == "REM" {
                // REM keyword
                tokens.append(SyntaxToken(
                    range: NSRange(location: pos, length: 3),
                    type: .comment,
                    text: "REM"
                ))
                // Rest of line is comment
                if pos + 3 < length {
                    tokens.append(SyntaxToken(
                        range: NSRange(location: pos + 3, length: length - (pos + 3)),
                        type: .comment,
                        text: nsLine.substring(from: pos + 3)
                    ))
                }
                return tokens
            }
        }

        // Tokenize the rest of the line
        var isAfterRem = false

        while pos < length {
            let ch = nsLine.character(at: pos)

            if isAfterRem {
                // Everything after REM is a comment
                tokens.append(SyntaxToken(
                    range: NSRange(location: pos, length: length - pos),
                    type: .comment,
                    text: nsLine.substring(from: pos)
                ))
                break
            }

            // String literal
            if ch == 0x22 { // Quote "
                let start = pos
                pos += 1
                while pos < length && nsLine.character(at: pos) != 0x22 {
                    pos += 1
                }
                if pos < length { pos += 1 } // consume closing quote
                tokens.append(SyntaxToken(
                    range: NSRange(location: start, length: pos - start),
                    type: .string,
                    text: nsLine.substring(with: NSRange(location: start, length: pos - start))
                ))
                continue
            }

            // Numbers
            if CharacterSet.decimalDigits.contains(Unicode.Scalar(ch)!) || ch == 0x2E /* . */ {
                let start = pos
                var hasDot = ch == 0x2E
                pos += 1
                while pos < length {
                    let c = nsLine.character(at: pos)
                    if CharacterSet.decimalDigits.contains(Unicode.Scalar(c)!) {
                        pos += 1
                    } else if c == 0x2E && !hasDot {
                        hasDot = true
                        pos += 1
                    } else {
                        break
                    }
                }
                tokens.append(SyntaxToken(
                    range: NSRange(location: start, length: pos - start),
                    type: .number,
                    text: nsLine.substring(with: NSRange(location: start, length: pos - start))
                ))
                continue
            }

            // Separators
            if ch == 0x3A || ch == 0x3B || ch == 0x2C { // : ; ,
                tokens.append(SyntaxToken(
                    range: NSRange(location: pos, length: 1),
                    type: .separator,
                    text: String(Character(UnicodeScalar(ch)!))
                ))
                pos += 1
                continue
            }

            // Math/comparison operators
            if [0x2B, 0x2D, 0x2A, 0x2F, 0x5E, 0x3D, 0x3C, 0x3E].contains(ch) { // + - * / ^ = < >
                tokens.append(SyntaxToken(
                    range: NSRange(location: pos, length: 1),
                    type: .operator_,
                    text: String(Character(UnicodeScalar(ch)!))
                ))
                pos += 1
                continue
            }

            // Parentheses
            if ch == 0x28 || ch == 0x29 { // ( )
                tokens.append(SyntaxToken(
                    range: NSRange(location: pos, length: 1),
                    type: .plain,
                    text: String(Character(UnicodeScalar(ch)!))
                ))
                pos += 1
                continue
            }

            // Whitespace
            if ch == 0x20 {
                let start = pos
                while pos < length && nsLine.character(at: pos) == 0x20 { pos += 1 }
                tokens.append(SyntaxToken(
                    range: NSRange(location: start, length: pos - start),
                    type: .plain,
                    text: String(repeating: " ", count: pos - start)
                ))
                continue
            }

            if CharacterSet.letters.contains(Unicode.Scalar(ch)!) {
                let start = pos
                let remaining = nsLine.substring(from: pos).uppercased()

                // Greedy longest-match WITHOUT letter-lookahead guard.
                // The ROM tokenizes NEXTD as NEXT+D, GETA$ as GET+A$, etc.
                // NOTE: `keywordMatcher.sortedKeywords` MUST be sorted by length descending for this to work correctly.
                var matchedKeyword: String? = nil
                for kw in keywordMatcher.sortedKeywords {
                    if remaining.hasPrefix(kw) {
                        matchedKeyword = kw
                        break
                    }
                }

                if let kw = matchedKeyword {
                    let upper = kw.uppercased()

                    if upper == "REM" {
                        tokens.append(SyntaxToken(
                            range: NSRange(location: start, length: kw.count),
                            type: .comment,
                            text: kw
                        ))
                        pos += kw.count
                        isAfterRem = true
                        continue
                    }

                    let tokenType: C64TokenType
                    if keywords.contains(upper) {
                        tokenType = (upper == "POKE" || upper == "PEEK") ? .poke : .keyword
                    } else if functions.contains(upper) {
                        tokenType = .function
                    } else if operators.contains(upper) {
                        tokenType = .operator_
                    } else if systemVariables.contains(upper) {
                        tokenType = .systemVariable
                    } else if let dialectKW = BasicDialectManager.shared.lookupKeyword(upper) {
                        switch dialectKW.highlightColor {
                        case .function:    tokenType = .function
                        case .conditional: tokenType = .keyword
                        case .loop:        tokenType = .keyword
                        case .operator_:   tokenType = .operator_
                        case .io:          tokenType = .poke
                        case .graphics:    tokenType = .function
                        case .sound:       tokenType = .function
                        case .system:      tokenType = .keyword
                        case .command:     tokenType = .keyword
                        }
                    } else {
                        tokenType = .keyword
                    }

                    tokens.append(SyntaxToken(
                        range: NSRange(location: start, length: kw.count),
                        type: tokenType,
                        text: kw
                    ))
                    pos += kw.count
                    continue
                }

                // No keyword matched — consume a plain identifier
                pos += 1
                while pos < length {
                    let c = nsLine.character(at: pos)
                    if CharacterSet.alphanumerics.contains(Unicode.Scalar(c)!) ||
                       c == 0x24 /* $ */ || c == 0x25 /* % */ || c == 0x23 /* # */ {
                        pos += 1
                    } else {
                        break
                    }
                }
                let word = nsLine.substring(with: NSRange(location: start, length: pos - start))
                tokens.append(SyntaxToken(
                    range: NSRange(location: start, length: pos - start),
                    type: .variable,
                    text: word
                ))
                continue
            }
            // Anything else
            tokens.append(SyntaxToken(
                range: NSRange(location: pos, length: 1),
                type: .plain,
                text: String(Character(UnicodeScalar(ch)!))
            ))
            pos += 1
        }

        return tokens
    }
}

