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

/// Documentation entry for a single BASIC V2 command or function.
struct C64CommandRef {
    let keyword: String
    let category: CommandCategory
    let syntax: String
    let description: String
    let example: String?
    let notes: String?

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

    /// Encyclopedic reference for every BASIC V2 command and function.
    static let commandReference: [String: C64CommandRef] = [
        // ── Program Flow ──────────────────────────────────────────
        "GOTO": C64CommandRef(
            keyword: "GOTO",
            category: .statement,
            syntax: "GOTO line_number",
            description: "Transfers program execution to the specified line number. Unconditional branch.",
            example: "GOTO 100",
            notes: "Using computed GOTO via ON..GOTO is generally preferred for readability."
        ),
        "GOSUB": C64CommandRef(
            keyword: "GOSUB",
            category: .statement,
            syntax: "GOSUB line_number",
            description: "Calls a subroutine at the specified line number. Pushes the return address onto the BASIC runtime stack. Use RETURN to come back.",
            example: "GOSUB 5000",
            notes: "GOSUB frames are stored in the BASIC heap (not the 256-byte hardware stack). Nesting depth is therefore limited by available program memory -- each frame consumes a small number of bytes. Deep or unbounded recursion will eventually cause ?OUT OF MEMORY ERROR."
        ),
        "RETURN": C64CommandRef(
            keyword: "RETURN",
            category: .statement,
            syntax: "RETURN",
            description: "Returns from a GOSUB subroutine to the statement after the calling GOSUB.",
            example: "5099 RETURN",
            notes: "RETURN without a prior GOSUB causes ?RETURN WITHOUT GOSUB ERROR."
        ),
        "IF": C64CommandRef(
            keyword: "IF",
            category: .statement,
            syntax: "IF expression THEN statement(s)",
            description: "Conditional execution. If expression is true (non-zero), executes the THEN clause. BASIC V2 evaluates 0 as false, any non-zero as true.",
            example: "IF X > 10 THEN PRINT \"BIG\" : GOTO 200",
            notes: "C64 BASIC V2 does NOT support ELSE -- it is not a token in the V2 table. Use IF/GOTO patterns instead: IF X=0 THEN GOTO 300. ELSE first appeared in BASIC 3.5 (C16/Plus/4) and was carried into BASIC 7.0 (C128)."
        ),
        "THEN": C64CommandRef(
            keyword: "THEN",
            category: .statement,
            syntax: "IF expression THEN line_number_or_statement",
            description: "Part of IF..THEN conditional. Can be followed by a line number (implicit GOTO) or statements.",
            example: "IF A=1 THEN 500",
            notes: "THEN followed by a number is equivalent to THEN GOTO number."
        ),
        "FOR": C64CommandRef(
            keyword: "FOR",
            category: .statement,
            syntax: "FOR variable = start TO end [STEP increment]",
            description: "Begins a counted loop. The variable is incremented by STEP (default 1) each iteration until it exceeds the end value.",
            example: "FOR I = 0 TO 255 STEP 2",
            notes: "The loop body always executes at least once. STEP can be negative for counting down."
        ),
        "TO": C64CommandRef(
            keyword: "TO",
            category: .statement,
            syntax: "FOR var = start TO end",
            description: "Specifies the end value of a FOR loop.",
            example: "FOR I = 1 TO 100",
            notes: nil
        ),
        "STEP": C64CommandRef(
            keyword: "STEP",
            category: .statement,
            syntax: "FOR var = start TO end STEP increment",
            description: "Specifies the increment for a FOR loop. Default is 1 if omitted.",
            example: "FOR I = 100 TO 0 STEP -1",
            notes: "STEP 0 creates an infinite loop."
        ),
        "NEXT": C64CommandRef(
            keyword: "NEXT",
            category: .statement,
            syntax: "NEXT [variable[, variable...]]",
            description: "Marks the end of a FOR loop. Increments the loop variable and branches back to the FOR if not done.",
            example: "NEXT I",
            notes: "NEXT without a variable closes the most recent FOR. Multiple variables can be specified: NEXT J,I"
        ),
        "ON": C64CommandRef(
            keyword: "ON",
            category: .statement,
            syntax: "ON expression GOTO line1[,line2,...] | ON expression GOSUB line1[,line2,...]",
            description: "Computed branch. Evaluates expression (1-based), then GOTOs or GOSUBs the corresponding line number.",
            example: "ON X GOTO 100,200,300",
            notes: "If expression is 0 or greater than the number of line numbers, execution falls through to the next statement."
        ),
        "RUN": C64CommandRef(
            keyword: "RUN",
            category: .statement,
            syntax: "RUN [line_number]",
            description: "Executes the program from the beginning or from the specified line number. Clears all variables first.",
            example: "RUN 100",
            notes: "RUN clears all variables. Use GOTO to resume without clearing."
        ),
        "STOP": C64CommandRef(
            keyword: "STOP",
            category: .statement,
            syntax: "STOP",
            description: "Halts program execution and prints BREAK IN line. Program can be resumed with CONT.",
            example: "IF ERR THEN STOP",
            notes: "Useful for debugging. CONT resumes from where STOP occurred."
        ),
        "END": C64CommandRef(
            keyword: "END",
            category: .statement,
            syntax: "END",
            description: "Terminates program execution. Similar to STOP but doesn't print BREAK message.",
            example: "999 END",
            notes: "Program can be resumed with CONT."
        ),
        "CONT": C64CommandRef(
            keyword: "CONT",
            category: .statement,
            syntax: "CONT",
            description: "Continues execution after a STOP or pressing RUN/STOP key.",
            example: "CONT",
            notes: "Cannot CONT if the program has been edited since stopping."
        ),

        // ── I/O ──────────────────────────────────────────────────
        "PRINT": C64CommandRef(
            keyword: "PRINT",
            category: .statement,
            syntax: "PRINT [expression[{;|,}expression...]]",
            description: "Outputs to the current device (screen by default). Semicolon suppresses spacing; comma advances to next tab column (every 10 chars).",
            example: "PRINT \"SCORE: \";SC",
            notes: "? is an abbreviation for PRINT. PRINT with no arguments outputs a blank line."
        ),
        "INPUT": C64CommandRef(
            keyword: "INPUT",
            category: .statement,
            syntax: "INPUT [\"prompt\";] variable[,variable...]",
            description: "Reads input from the keyboard. Displays a ? prompt. Optional prompt string before semicolon.",
            example: "INPUT \"YOUR NAME\";N$",
            notes: "If the user presses comma without providing a variable name, BASIC returns ?COMMA EXPECTED."
        ),
        "GET": C64CommandRef(
            keyword: "GET",
            category: .statement,
            syntax: "GET variable",
            description: "Reads a single character from the keyboard buffer without waiting. Returns empty string if no key pressed.",
            example: "100 GET A$:IF A$=\"\" THEN 100",
            notes: "Does not echo to screen. The classic 'wait for keypress' pattern is the example shown."
        ),
        "READ": C64CommandRef(
            keyword: "READ",
            category: .statement,
            syntax: "READ variable[,variable...]",
            description: "Reads the next value(s) from DATA statements into variables.",
            example: "READ X,Y,C$",
            notes: "The DATA pointer is shared globally. Use RESTORE to reset it."
        ),
        "DATA": C64CommandRef(
            keyword: "DATA",
            category: .statement,
            syntax: "DATA value[,value...]",
            description: "Stores constant data to be read by READ statements. Values are separated by commas. Strings don't need quotes unless they contain commas or colons.",
            example: "500 DATA 10,20,\"HELLO\",3.14",
            notes: "DATA statements can be placed anywhere in the program. They are read in order of line number."
        ),
        "RESTORE": C64CommandRef(
            keyword: "RESTORE",
            category: .statement,
            syntax: "RESTORE",
            description: "Resets the DATA read pointer back to the first DATA statement, allowing data to be re-read.",
            example: "RESTORE",
            notes: "C64 BASIC V2 does not support RESTORE to a specific line number (some enhanced BASICs do)."
        ),

        // ── File I/O ─────────────────────────────────────────────
        "OPEN": C64CommandRef(
            keyword: "OPEN",
            category: .ioCommand,
            syntax: "OPEN file#, device#[, secondary#[, \"filename[,type[,mode]]\"]]",
            description: "Opens a logical file for I/O. Device 1=tape, 4-7=printer, 8-15=disk drive, 2=RS-232.",
            example: "OPEN 1,8,15,\"S:OLDFILE\":CLOSE 1",
            notes: "Common: OPEN 2,8,2,\"FILE,S,R\" for sequential read. OPEN 1,8,15 for disk command channel."
        ),
        "CLOSE": C64CommandRef(
            keyword: "CLOSE",
            category: .ioCommand,
            syntax: "CLOSE file#",
            description: "Closes a previously opened logical file.",
            example: "CLOSE 2",
            notes: "Always CLOSE files when done, especially disk files, or data may be lost."
        ),
        "CMD": C64CommandRef(
            keyword: "CMD",
            category: .ioCommand,
            syntax: "CMD file#",
            description: "Redirects output from PRINT to the specified file/device instead of the screen.",
            example: "CMD 4:PRINT \"TO PRINTER\"",
            notes: "Use PRINT# to the file and CLOSE to restore screen output. Forgetting to close causes issues."
        ),
        "GET#": C64CommandRef(
            keyword: "GET#",
            category: .ioCommand,
            syntax: "GET# file#, variable",
            description: "Reads a single character from an open file.",
            example: "GET#2, A$",
            notes: "Check ST (status variable) after each read. ST=64 means end of file. Note: unlike INPUT# ($84) and PRINT# ($98), GET# is not a distinct token in the BASIC V2 table -- the ROM tokenizes it as GET ($A1) followed by the file number. It is listed here for documentation completeness."
        ),
        "INPUT#": C64CommandRef(
            keyword: "INPUT#",
            category: .ioCommand,
            syntax: "INPUT# file#, variable[,variable...]",
            description: "Reads data from an open file, similar to INPUT but from a file instead of keyboard.",
            example: "INPUT#2, N$, A",
            notes: "Reads up to comma, colon, or end of line."
        ),
        "PRINT#": C64CommandRef(
            keyword: "PRINT#",
            category: .ioCommand,
            syntax: "PRINT# file#, expression[;expression...]",
            description: "Writes data to an open file.",
            example: "PRINT#2, N$;\",\";A",
            notes: "Use CHR$(13) for carriage return in sequential files."
        ),

        // ── Variables & Memory ───────────────────────────────────
        "LET": C64CommandRef(
            keyword: "LET",
            category: .statement,
            syntax: "LET variable = expression",
            description: "Assigns a value to a variable. The LET keyword is optional — A=5 works the same as LET A=5.",
            example: "LET X = 42",
            notes: "LET is rarely used in practice since it's optional, but it's valid BASIC."
        ),
        "DIM": C64CommandRef(
            keyword: "DIM",
            category: .statement,
            syntax: "DIM variable(size[,size...])[,variable(size)...]",
            description: "Declares array dimensions. Arrays default to size 10 (indices 0-10) if not DIMmed.",
            example: "DIM A(100), B$(20,5)",
            notes: "Arrays cannot be re-dimensioned without CLR. Maximum subscript is 32767."
        ),
        "DEF": C64CommandRef(
            keyword: "DEF",
            category: .statement,
            syntax: "DEF FN name(variable) = expression",
            description: "Defines a user function. Function names must start with FN followed by a valid variable name.",
            example: "DEF FN SQ(X) = X*X",
            notes: "Only single-argument functions are supported. The function body is a single expression."
        ),
        "FN": C64CommandRef(
            keyword: "FN",
            category: .function,
            syntax: "FN name(argument)",
            description: "Calls a user-defined function previously declared with DEF FN. The argument is passed to the function's parameter variable and the expression is evaluated.",
            example: "DEF FN SQ(X) = X*X\nPRINT FN SQ(7)  : REM PRINTS 49",
            notes: "FN is its own token ($A5), distinct from DEF ($96). The name after FN must match a prior DEF FN definition. Only single-argument functions are supported in BASIC V2. Attempting to call an undefined function causes ?UNDEFINED FUNCTION ERROR."
        ),
        "POKE": C64CommandRef(
            keyword: "POKE",
            category: .statement,
            syntax: "POKE address, value",
            description: "Writes a byte value (0-255) to the specified memory address (0-65535). The primary way to directly manipulate hardware on the C64.",
            example: "POKE 53280,0 : REM BLACK BORDER",
            notes: "Key addresses: 53280=border color, 53281=background, 646=cursor color, 1024-2023=screen memory, 55296-56295=color RAM."
        ),
        "PEEK": C64CommandRef(
            keyword: "PEEK",
            category: .function,
            syntax: "PEEK(address)",
            description: "Returns the byte value (0-255) at the specified memory address.",
            example: "X = PEEK(53280) : REM READ BORDER COLOR",
            notes: "Useful for reading hardware registers, joystick ports (56320/56321), keyboard, etc."
        ),
        "SYS": C64CommandRef(
            keyword: "SYS",
            category: .statement,
            syntax: "SYS address",
            description: "Executes machine language routine starting at the given address. Processor registers can be set via locations 780-783.",
            example: "SYS 49152 : REM RUN ML AT $C000",
            notes: "780=A register, 781=X register, 782=Y register, 783=status register before SYS call."
        ),
        "USR": C64CommandRef(
            keyword: "USR",
            category: .function,
            syntax: "USR(value)",
            description: "Calls a machine language routine (address stored at 785-786) passing a floating point value. Returns a floating point result.",
            example: "A = USR(42)",
            notes: "Set the USR vector at 785-786 (low/high byte) before calling. Less commonly used than SYS."
        ),
        "WAIT": C64CommandRef(
            keyword: "WAIT",
            category: .statement,
            syntax: "WAIT address, mask[, invertmask]",
            description: "Pauses execution until a memory location's value ANDed with mask (XORed with invertmask if given) is non-zero.",
            example: "WAIT 198,1 : REM WAIT FOR KEYPRESS",
            notes: "Blocks completely. The condition is: (PEEK(addr) XOR invertmask) AND mask <> 0."
        ),

        // ── Program Management ───────────────────────────────────
        "NEW": C64CommandRef(
            keyword: "NEW",
            category: .statement,
            syntax: "NEW",
            description: "Erases the current program from memory and clears all variables.",
            example: "NEW",
            notes: "Unrecoverable! Though the memory isn't immediately overwritten — heroic recovery is sometimes possible with a monitor."
        ),
        "CLR": C64CommandRef(
            keyword: "CLR",
            category: .statement,
            syntax: "CLR",
            description: "Clears all variables, arrays, and stacks without erasing the program.",
            example: "CLR",
            notes: "Also resets the DATA pointer and clears the subroutine/FOR-NEXT stacks."
        ),
        "LIST": C64CommandRef(
            keyword: "LIST",
            category: .statement,
            syntax: "LIST [start_line][-[end_line]]",
            description: "Displays program lines. Can specify a range.",
            example: "LIST 100-200",
            notes: "Press RUN/STOP to stop a long listing."
        ),
        "SAVE": C64CommandRef(
            keyword: "SAVE",
            category: .statement,
            syntax: "SAVE \"filename\"[,device#[,secondary]]",
            description: "Saves the current program to tape or disk.",
            example: "SAVE \"MYGAME\",8",
            notes: "Device 1=tape (default), 8=disk. Secondary address 1 saves with relocate address for ML."
        ),
        "LOAD": C64CommandRef(
            keyword: "LOAD",
            category: .statement,
            syntax: "LOAD \"filename\"[,device#[,secondary]]",
            description: "Loads a program from tape or disk into memory.",
            example: "LOAD \"MYGAME\",8,1",
            notes: "Secondary 0 loads to BASIC start ($0801). Secondary 1 loads to the address stored in the file (for ML programs)."
        ),
        "VERIFY": C64CommandRef(
            keyword: "VERIFY",
            category: .statement,
            syntax: "VERIFY \"filename\"[,device#]",
            description: "Compares program in memory with program on tape/disk to verify a SAVE was successful.",
            example: "VERIFY \"MYGAME\",8",
            notes: "Good practice after saving important work, especially to tape."
        ),
        "REM": C64CommandRef(
            keyword: "REM",
            category: .statement,
            syntax: "REM [comment text]",
            description: "Remark. Everything after REM on the same line is ignored by the interpreter.",
            example: "100 REM === MAIN GAME LOOP ===",
            notes: "Uses memory and slows execution slightly since BASIC must skip over them. Use sparingly in tight code."
        ),

        // ── Math Functions ───────────────────────────────────────
        "ABS": C64CommandRef(
            keyword: "ABS",
            category: .function,
            syntax: "ABS(number)",
            description: "Returns the absolute value of a number.",
            example: "PRINT ABS(-42)  : REM PRINTS 42",
            notes: nil
        ),
        "ATN": C64CommandRef(
            keyword: "ATN",
            category: .function,
            syntax: "ATN(number)",
            description: "Returns the arctangent in radians.",
            example: "PI = 4*ATN(1)",
            notes: "The classic way to get PI on the C64: PI = 4*ATN(1)"
        ),
        "COS": C64CommandRef(
            keyword: "COS",
            category: .function,
            syntax: "COS(angle)",
            description: "Returns the cosine of an angle in radians.",
            example: "X = COS(A) * R",
            notes: nil
        ),
        "EXP": C64CommandRef(
            keyword: "EXP",
            category: .function,
            syntax: "EXP(number)",
            description: "Returns e raised to the given power.",
            example: "PRINT EXP(1) : REM PRINTS 2.71828183",
            notes: "Overflow error if number > 88.0296919."
        ),
        "INT": C64CommandRef(
            keyword: "INT",
            category: .function,
            syntax: "INT(number)",
            description: "Returns the largest integer not greater than the number (floor function).",
            example: "PRINT INT(3.7)  : REM PRINTS 3\nPRINT INT(-3.7) : REM PRINTS -4",
            notes: "Note: INT(-3.7) returns -4, not -3. It always rounds toward negative infinity."
        ),
        "LOG": C64CommandRef(
            keyword: "LOG",
            category: .function,
            syntax: "LOG(number)",
            description: "Returns the natural logarithm (base e) of a number.",
            example: "PRINT LOG(10) : REM PRINTS 2.30258509",
            notes: "For base-10 log: LOG(X)/LOG(10). ?ILLEGAL QUANTITY if number <= 0."
        ),
        "RND": C64CommandRef(
            keyword: "RND",
            category: .function,
            syntax: "RND(number)",
            description: "Returns a pseudo-random float in the range 0 to (but not including) 1. The argument controls behavior: if positive, advances and returns the next value from the PRNG sequence; if zero, derives a value from the CIA hardware timer registers (true randomness); if negative, seeds the PRNG from the argument's absolute value and returns the first value of that deterministic sequence.",
            example: "X = INT(RND(1)*6)+1 : REM DICE ROLL",
            notes: "RND(1) (or any positive value) is the standard usage. RND(0) is useful for seeding from hardware entropy before a game starts. RND(-n) resets to a known sequence -- handy for reproducing test cases. Typical game pattern: RND(-TI) once at startup to seed from the clock, then RND(1) for all subsequent calls."
        ),
        "SGN": C64CommandRef(
            keyword: "SGN",
            category: .function,
            syntax: "SGN(number)",
            description: "Returns the sign of a number: -1 if negative, 0 if zero, 1 if positive.",
            example: "ON SGN(X)+2 GOTO 100,200,300",
            notes: "Useful for ON..GOTO dispatch based on sign."
        ),
        "SIN": C64CommandRef(
            keyword: "SIN",
            category: .function,
            syntax: "SIN(angle)",
            description: "Returns the sine of an angle in radians.",
            example: "Y = SIN(A) * R",
            notes: nil
        ),
        "SQR": C64CommandRef(
            keyword: "SQR",
            category: .function,
            syntax: "SQR(number)",
            description: "Returns the square root.",
            example: "PRINT SQR(144) : REM PRINTS 12",
            notes: "?ILLEGAL QUANTITY if number < 0."
        ),
        "TAN": C64CommandRef(
            keyword: "TAN",
            category: .function,
            syntax: "TAN(angle)",
            description: "Returns the tangent of an angle in radians.",
            example: "PRINT TAN(0.785398) : REM ~1",
            notes: nil
        ),

        // ── String Functions ─────────────────────────────────────
        "ASC": C64CommandRef(
            keyword: "ASC",
            category: .function,
            syntax: "ASC(string$)",
            description: "Returns the PETSCII code of the first character of a string.",
            example: "PRINT ASC(\"A\") : REM PRINTS 65",
            notes: "?ILLEGAL QUANTITY if string is empty. PETSCII, not ASCII — though uppercase letters share the same codes."
        ),
        "CHR$": C64CommandRef(
            keyword: "CHR$",
            category: .function,
            syntax: "CHR$(code)",
            description: "Returns the character for a given PETSCII code (0-255).",
            example: "PRINT CHR$(147) : REM CLEAR SCREEN",
            notes: "Common codes: 13=Return, 147=Clear Screen, 18=Reverse On, 146=Reverse Off, 14=Lowercase mode."
        ),
        "LEFT$": C64CommandRef(
            keyword: "LEFT$",
            category: .function,
            syntax: "LEFT$(string$, count)",
            description: "Returns the leftmost 'count' characters of a string.",
            example: "PRINT LEFT$(\"HELLO\",3) : REM HEL",
            notes: "If count >= string length, returns the whole string."
        ),
        "LEN": C64CommandRef(
            keyword: "LEN",
            category: .function,
            syntax: "LEN(string$)",
            description: "Returns the length of a string (0-255).",
            example: "IF LEN(N$) > 16 THEN PRINT \"TOO LONG\"",
            notes: "Maximum string length on C64 is 255 characters."
        ),
        "MID$": C64CommandRef(
            keyword: "MID$",
            category: .function,
            syntax: "MID$(string$, start[, count])",
            description: "Returns a substring starting at position 'start' (1-based), optionally limited to 'count' characters.",
            example: "PRINT MID$(\"HELLO\",2,3) : REM ELL",
            notes: "Start position is 1-based, not 0-based."
        ),
        "RIGHT$": C64CommandRef(
            keyword: "RIGHT$",
            category: .function,
            syntax: "RIGHT$(string$, count)",
            description: "Returns the rightmost 'count' characters of a string.",
            example: "PRINT RIGHT$(\"HELLO\",3) : REM LLO",
            notes: nil
        ),
        "STR$": C64CommandRef(
            keyword: "STR$",
            category: .function,
            syntax: "STR$(number)",
            description: "Converts a number to its string representation. Positive numbers get a leading space.",
            example: "A$ = STR$(42) : REM A$ = \" 42\"",
            notes: "Use MID$(STR$(X),2) to strip the leading space from positive numbers."
        ),
        "VAL": C64CommandRef(
            keyword: "VAL",
            category: .function,
            syntax: "VAL(string$)",
            description: "Converts a string to a number. Parses as much of the string as possible.",
            example: "PRINT VAL(\"3.14ABC\") : REM 3.14",
            notes: "Returns 0 if the string doesn't start with a digit, decimal point, or sign."
        ),

        // ── Other Functions ──────────────────────────────────────
        "FRE": C64CommandRef(
            keyword: "FRE",
            category: .function,
            syntax: "FRE(0)",
            description: "Returns the number of free bytes available for BASIC. Forces garbage collection of strings first.",
            example: "PRINT FRE(0) : REM SHOW FREE MEMORY",
            notes: "The argument is ignored but required. String garbage collection can cause noticeable pauses."
        ),
        "POS": C64CommandRef(
            keyword: "POS",
            category: .function,
            syntax: "POS(0)",
            description: "Returns the current cursor column position (0-39).",
            example: "IF POS(0) > 35 THEN PRINT",
            notes: "The argument is ignored but required."
        ),

        // ── System Variables ─────────────────────────────────────
        "TI": C64CommandRef(
            keyword: "TI",
            category: .systemVar,
            syntax: "TI",
            description: "The jiffy clock. Increments by 1 every 1/60th of a second. Counts up from 0 at power-on. Wraps after 24 hours (5184000 jiffies).",
            example: "T=TI : REM SAVE START TIME",
            notes: "Read-only in BASIC (set via TI$). Resets on tape/disk operations."
        ),
        "TI$": C64CommandRef(
            keyword: "TI$",
            category: .systemVar,
            syntax: "TI$",
            description: "String form of the jiffy clock in HHMMSS format (24-hour). Can be set.",
            example: "TI$ = \"120000\" : REM SET TO NOON",
            notes: "Setting TI$ also updates TI. Not battery-backed — resets at power-on."
        ),
        "ST": C64CommandRef(
            keyword: "ST",
            category: .systemVar,
            syntax: "ST",
            description: "I/O status variable. Updated after every I/O operation. Bit-field with different meanings per device.",
            example: "IF ST AND 64 THEN PRINT \"END OF FILE\"",
            notes: "For disk: bit 6 (64) = EOF. Check after GET#/INPUT# operations. For serial: various timeout/error bits."
        ),

        // ── Operators ────────────────────────────────────────────
        "AND": C64CommandRef(
            keyword: "AND",
            category: .operator_,
            syntax: "expression AND expression",
            description: "Bitwise AND operator. In boolean context, combines two conditions.",
            example: "IF X>0 AND X<100 THEN PRINT \"IN RANGE\"",
            notes: "Also works as bitwise AND: PRINT 255 AND 15 gives 15."
        ),
        "OR": C64CommandRef(
            keyword: "OR",
            category: .operator_,
            syntax: "expression OR expression",
            description: "Bitwise OR operator. In boolean context, true if either condition is true.",
            example: "IF A=1 OR A=2 THEN PRINT \"ONE OR TWO\"",
            notes: "Also works as bitwise OR: PRINT 240 OR 15 gives 255."
        ),
        "NOT": C64CommandRef(
            keyword: "NOT",
            category: .operator_,
            syntax: "NOT expression",
            description: "Bitwise NOT (complement). In boolean context, inverts true/false.",
            example: "IF NOT A THEN PRINT \"A IS ZERO\"",
            notes: "NOT 0 = -1 (all bits set). NOT -1 = 0. Bitwise complement of 16-bit integer."
        ),

        // ── Screen/Output ────────────────────────────────────────
        "TAB": C64CommandRef(
            keyword: "TAB",
            category: .function,
            syntax: "TAB(column)",
            description: "Used in PRINT to move to a specific column position (0-255).",
            example: "PRINT TAB(10);\"HELLO\"",
            notes: "Only works in PRINT statements. If current position is past the specified column, does nothing (doesn't go backwards)."
        ),
        "SPC": C64CommandRef(
            keyword: "SPC",
            category: .function,
            syntax: "SPC(count)",
            description: "Used in PRINT to output a specified number of spaces.",
            example: "PRINT SPC(5);\"INDENTED\"",
            notes: "Only works in PRINT statements."
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

