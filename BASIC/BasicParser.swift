import Foundation

// MARK: - BasicParser

/// A recursive-descent parser for Commodore 64 BASIC V2.
///
/// Converts a raw BASIC program string into a structured AST (`[ParsedLine]`).
/// Errors are collected rather than thrown, allowing the parser to continue
/// through malformed lines and report all issues at once.
///
/// **C64 BASIC Notes:**
/// - `REM` bodies are consumed by the lexer and never reach this parser.
/// - `ELSE` is not a native V2 keyword; it is lexed as an identifier and
///   handled here for extended compatibility. Strict C64 BASIC only supports
///   `IF cond THEN line` or `IF cond THEN stmt`.
/// - Line numbers are stored as `Int`. The C64 ROM limits them to 0–65023,
///   but validation is deferred to the code generator/assembler.
public struct BasicParser {

    // MARK: - State

    /// Token stream for the current line being parsed.
    private var tokens: [BasicToken] = []
    /// Current position in `tokens`.
    private var pos = 0
    /// Line number of the current source line.
    private(set) var currentLineNumber = 0
    /// Collected parse errors. Never throws; errors are accumulated here.
    private(set) var errors: [ParseError] = []

    // MARK: - Entry Point

    /// Parses a complete BASIC program string into a list of parsed lines.
    ///
    /// - Parameter source: Multi-line BASIC source code. Blank lines are skipped.
    /// - Returns: An array of `ParsedLine` representing the AST.
    /// - Note: `tokenize(_:)` must be implemented in the same module or imported.
    mutating func parse(_ source: String) -> [ParsedLine] {
        var lines: [ParsedLine] = []

        for rawLine in source.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Extract leading line number
            var numStr = ""
            var charIdx = trimmed.startIndex
            while charIdx < trimmed.endIndex && trimmed[charIdx].isNumber {
                numStr.append(trimmed[charIdx])
                charIdx = trimmed.index(after: charIdx)
            }
            guard let lineNum = Int(numStr), !numStr.isEmpty else { continue }
            currentLineNumber = lineNum

            // Tokenize the statement content (after the line number)
            let content = String(trimmed[charIdx...]).trimmingCharacters(in: .whitespaces)
            tokens = tokenize(content)
            pos = 0

            let stmts = parseStatementList()
            lines.append(ParsedLine(number: lineNum, stmts: stmts))
        }

        return lines
    }

    // MARK: - Statement List

    private mutating func parseStatementList() -> [Stmt] {
        var stmts: [Stmt] = []
        while !atEOF {
            // Bare colon is a legal no-op separator in C64 BASIC
            if peek == .colon { advance(); continue }
            if let s = parseOneStatement() {
                stmts.append(s)
            }
            // Consume trailing colon between statements
            if peek == .colon { advance() }
        }
        return stmts
    }

    // MARK: - Statement Dispatch

    /// Parses a single statement. Returns `nil` only for `REM` (handled by lexer).
    private mutating func parseOneStatement() -> Stmt? {
        switch peek {
        // ── Simple one-token statements ─────────────────
        case .keyword("RETURN"):  advance(); return .returnStmt
        case .keyword("END"):     advance(); return .endStmt
        case .keyword("STOP"):    advance(); return .stopStmt
        case .keyword("CLR"):     advance(); return .clrStmt
        case .keyword("RESTORE"): advance(); return .restoreStmt

        // ── REM — lexer already consumed the body ───────
        case .keyword("REM"):     advance(); return .remStmt

        // ── Complex statements ─────────────────────────
        case .keyword("PRINT"):   return parsePrint()
        case .keyword("PRINT#"):  return parsePrintHash()
        case .keyword("POKE"):    return parsePoke()
        case .keyword("GOTO"):    return parseGoto()
        case .keyword("GOSUB"):   return parseGosub()
        case .keyword("IF"):      return parseIf()
        case .keyword("FOR"):     return parseFor()
        case .keyword("NEXT"):    return parseNext()
        case .keyword("LET"):     advance(); return parseLet()   // optional LET
        case .keyword("INPUT"):   return parseInput()
        case .keyword("INPUT#"):  return parseInputHash()
        case .keyword("GET"):     return parseGet()
        case .keyword("GET#"):    return parseGetHash()
        case .keyword("SYS"):     return parseSys()
        case .keyword("WAIT"):    return parseWait()
        case .keyword("DATA"):    return parseData()
        case .keyword("READ"):    return parseRead()
        case .keyword("DIM"):     return parseDim()
        case .keyword("ON"):      return parseOn()
        case .keyword("OPEN"):    return parseOpen()
        case .keyword("CLOSE"):   return parseClose()
        case .keyword("CMD"):     return parseCmd()
        case .keyword("LOAD"):    return parseLoad()
        case .keyword("SAVE"):    return parseSave()
        case .keyword("DEF"):     return parseDef()

        // ── Implicit LET: identifier = expr ─────────────
        case .identifier, .identifierStr, .identifierInt:
            return parseLet()

        default:
            recordError("Expected statement, got \(peek)")
            advance()
            return nil
        }
    }

    // MARK: - Statement Parsers

    private mutating func parsePrint() -> Stmt {
        advance() // PRINT
        var items: [PrintItem] = []

        while !atEOF && peek != .colon {
            // ELSE is not a keyword — stop here so IF parser can claim it.
            if case .identifier("ELSE") = peek { break }
            switch peek {
            case .semicolon:
                advance()
                items.append(.noNewline)
            case .comma:
                advance()
                items.append(.tab)
            default:
                items.append(.expr(parseExpr()))
            }
        }
        return .printStmt(items)
    }

    private mutating func parsePrintHash() -> Stmt {
        advance() // PRINT#
        let logNum = parseExpr()
        consumeComma()
        var items: [PrintItem] = []
        while !atEOF && peek != .colon {
            if case .identifier("ELSE") = peek { break }
            switch peek {
            case .semicolon: advance(); items.append(.noNewline)
            case .comma:     advance(); items.append(.tab)
            default:         items.append(.expr(parseExpr()))
            }
        }
        return .printHashStmt(logNum, items)
    }

    private mutating func parsePoke() -> Stmt {
        advance() // POKE
        let addr = parseExpr()
        consumeComma()
        let value = parseExpr()
        return .pokeStmt(addr, value)
    }

    private mutating func parseGoto() -> Stmt {
        advance() // GOTO
        let n = parseLineNumber(context: "GOTO")
        return .gotoStmt(n)
    }

    private mutating func parseGosub() -> Stmt {
        advance() // GOSUB
        let n = parseLineNumber(context: "GOSUB")
        return .gosubStmt(n)
    }

    /// Parses `IF` statements. Handles:
    ///   • `IF cond THEN line`
    ///   • `IF cond THEN GOTO line`
    ///   • `IF cond THEN stmt [:stmt...] [ELSE stmt [:stmt...] | line]`
    ///
    /// Note: In C64 BASIC, `ELSE` is not a keyword. It is lexed as an identifier
    /// and matched here for extended compatibility. Strict V2 only supports
    /// `IF...THEN GOTO/line` or `IF...THEN stmt`.
    private mutating func parseIf() -> Stmt {
        advance() // IF
        let cond = parseExpr()

        // THEN is required in BASIC V2
        if case .keyword("THEN") = peek { advance() }

        // THEN followed directly by a line number → ifGoto
        if case .integer(let n) = peek {
            advance()
            skipUnreachableThenTail()
            if let elseStmts = parseOptionalElse() {
                return .ifThen(cond, [.gotoStmt(n)], elseStmts)
            }
            return .ifGoto(cond, n)
        }

        // THEN GOTO lineno
        if case .keyword("GOTO") = peek {
            advance()
            let n = parseLineNumber(context: "IF...THEN GOTO")
            skipUnreachableThenTail()
            if let elseStmts = parseOptionalElse() {
                return .ifThen(cond, [.gotoStmt(n)], elseStmts)
            }
            return .ifGoto(cond, n)
        }

        // THEN followed by inline statements
        let thenStmts = parseIfBody()
        let elseStmts = parseOptionalElse()
        return .ifThen(cond, thenStmts, elseStmts)
    }

    /// Discards statements following `THEN <line>` or `THEN GOTO <line>`.
    ///
    /// On a real C64, a false IF skips the ENTIRE remainder of the line, and
    /// a true `THEN <line>` jumps away immediately — so any statements after
    /// the line-number target are unreachable in both cases and the
    /// interpreter never executes them. Compiling them as unconditional
    /// siblings (the previous behavior) made them run whenever the condition
    /// was false. Stops at ELSE so the extension syntax
    /// `IF cond THEN 100 ELSE ...` still works.
    private mutating func skipUnreachableThenTail() {
        while !atEOF {
            if case .identifier("ELSE") = peek { return }
            advance()
        }
    }

    /// Consume and parse an ELSE branch if present. Returns `nil` otherwise.
    private mutating func parseOptionalElse() -> [Stmt]? {
        guard case .identifier("ELSE") = peek else { return nil }
        advance() // ELSE
        if case .integer(let n) = peek {
            advance()
            return [.gotoStmt(n)]
        }
        return parseIfBody()
    }

    /// Parse statements for IF body, stopping before ELSE, colon at top level, or EOF.
    /// In C64 BASIC, colons inside `IF...THEN` separate statements that all execute
    /// if the condition is true. This parser correctly consumes them as part of the
    /// THEN clause unless an ELSE is encountered.
    private mutating func parseIfBody() -> [Stmt] {
        var stmts: [Stmt] = []
        while !atEOF {
            if case .identifier("ELSE") = peek { break }
            if peek == .colon {
                advance()
                if case .identifier("ELSE") = peek { break }
                continue
            }
            if let s = parseOneStatement() { stmts.append(s) }
            if peek == .colon { advance(); continue }
            break
        }
        return stmts
    }

    private mutating func parseFor() -> Stmt {
        advance() // FOR
        guard case .identifier(let varName) = peek else {
            recordError("Expected variable name after FOR")
            return skipToColon()
        }
        advance()
        consumeOp("=", context: "FOR")
        let from = parseExpr()
        consumeKeyword("TO", context: "FOR")
        let to = parseExpr()
        var step: Expr? = nil
        if case .keyword("STEP") = peek { advance(); step = parseExpr() }
        return .forStmt(varName, from, to, step)
    }

    private mutating func parseNext() -> Stmt {
        advance() // NEXT
        switch peek {
        case .identifier(let v): advance(); return .nextStmt(v)
        default: return .nextStmt(nil)
        }
    }

    private mutating func parseLet() -> Stmt {
        switch peek {
        case .identifier(let name):
            advance()
            if peek == .lparen {
                advance()
                let indices = parseExprList(until: .rparen)
                consumeRParen()
                consumeOp("=", context: "array assignment")
                let rhs = parseExpr()
                return .arrayWrite(name, indices, rhs)
            }
            consumeOp("=", context: "LET")
            return .letFloat(name, parseExpr())

        case .identifierStr(let name):
            advance()
            if peek == .lparen {
                advance()
                let indices = parseExprList(until: .rparen)
                consumeRParen()
                consumeOp("=", context: "string array assignment")
                return .arrayWrite(name, indices, parseExpr())
            }
            consumeOp("=", context: "LET string")
            return .letStr(name, parseExpr())

        case .identifierInt(let name):
            advance()
            if peek == .lparen {
                advance()
                let indices = parseExprList(until: .rparen)
                consumeRParen()
                consumeOp("=", context: "integer array assignment")
                return .arrayWrite(name, indices, parseExpr())
            }
            consumeOp("=", context: "LET integer")
            return .letInt(name, parseExpr())

        default:
            recordError("Expected variable name in assignment")
            return skipToColon()
        }
    }

    private mutating func parseInput() -> Stmt {
        advance() // INPUT
        var prompt: String? = nil
        if case .stringLiteral(let s) = peek {
            prompt = s; advance()
            if peek == .semicolon { advance() }
        }
        let varName = parseVarName(context: "INPUT")
        return .inputStmt(prompt, varName)
    }

    private mutating func parseInputHash() -> Stmt {
        advance() // INPUT#
        let logNum = parseExpr()
        consumeComma()
        var names: [String] = []
        while !atEOF && peek != .colon {
            if peek == .comma { advance(); continue }
            names.append(parseVarName(context: "INPUT#"))
        }
        return .inputHashStmt(logNum, names)
    }

    private mutating func parseGet() -> Stmt {
        advance() // GET
        // GET# is not a ROM token: real hardware crunches it as the GET
        // token followed by a literal '#', and our lexer does the same.
        // The .keyword("GET#") dispatch case can only fire if a dialect
        // table defines GET# as its own keyword; this path handles V2.
        if peek == .hash {
            advance() // #
            let logNum = parseExpr()
            consumeComma()
            let v = parseVarName(context: "GET#")
            return .getHashStmt(logNum, v)
        }
        let v = parseVarName(context: "GET")
        return .getStmt(v)
    }

    private mutating func parseGetHash() -> Stmt {
        advance() // GET#
        let logNum = parseExpr()
        consumeComma()
        let v = parseVarName(context: "GET#")
        return .getHashStmt(logNum, v)
    }

    private mutating func parseSys() -> Stmt {
        advance(); return .sysStmt(parseExpr())
    }

    private mutating func parseWait() -> Stmt {
        advance() // WAIT
        let addr = parseExpr(); consumeComma()
        let mask = parseExpr()
        var xor: Expr? = nil
        if peek == .comma { advance(); xor = parseExpr() }
        return .waitStmt(addr, mask, xor)
    }

    private mutating func parseData() -> Stmt {
        advance() // DATA
        var values: [DataValue] = []
        while !atEOF && peek != .colon {
            if peek == .comma { advance(); continue }
            switch peek {
            case .integer(let n):   advance(); values.append(.integer(n))
            case .float(let f):     advance(); values.append(.float(f))
            case .stringLiteral(let s): advance(); values.append(.string(s))
            case .op("-"):
                advance()
                if case .integer(let n) = peek { advance(); values.append(.negative(n)) }
                else if case .float(let f) = peek { advance(); values.append(.float(-f)) }
                else { recordError("Expected number after - in DATA") }
            default:
                advance() // skip unexpected
            }
        }
        return .dataStmt(values)
    }

    private mutating func parseRead() -> Stmt {
        advance() // READ
        var names: [String] = []
        while !atEOF && peek != .colon {
            if peek == .comma { advance(); continue }
            names.append(parseVarName(context: "READ"))
        }
        return .readStmt(names)
    }

    private mutating func parseDim() -> Stmt {
        advance() // DIM
        var entries: [DimEntry] = []
        while !atEOF && peek != .colon {
            if peek == .comma { advance(); continue }
            let name = parseVarName(context: "DIM")
            guard peek == .lparen else {
                recordError("Expected '(' after array name in DIM")
                break
            }
            advance() // (
            let dims = parseExprList(until: .rparen)
            consumeRParen()
            entries.append(DimEntry(name: name, dims: dims))
        }
        return .dimStmt(entries)
    }

    private mutating func parseOn() -> Stmt {
        advance() // ON
        let expr = parseExpr()
        var isGosub = false
        if case .keyword("GOSUB") = peek { isGosub = true; advance() }
        else { consumeKeyword("GOTO", context: "ON") }
        var targets: [Int] = []
        while !atEOF && peek != .colon {
            if peek == .comma { advance(); continue }
            if case .integer(let n) = peek { targets.append(n); advance() }
            else { break }
        }
        return isGosub ? .onGosub(expr, targets) : .onGoto(expr, targets)
    }

    private mutating func parseOpen() -> Stmt {
        advance() // OPEN
        let log = parseExpr(); consumeComma()
        let dev = parseExpr()
        var sec: Expr = .intLit(0)
        var name: Expr? = nil
        if peek == .comma {
            advance(); sec = parseExpr()
            if peek == .comma { advance(); name = parseExpr() }
        }
        return .openStmt(log, dev, sec, name)
    }

    private mutating func parseClose() -> Stmt {
        advance(); return .closeStmt(parseExpr())
    }

    private mutating func parseCmd() -> Stmt {
        advance(); return .cmdStmt(parseExpr())
    }

    private mutating func parseLoad() -> Stmt {
        advance() // LOAD
        let name = parseExpr(); consumeComma()
        let dev = parseExpr()
        var flag: Expr? = nil
        if peek == .comma { advance(); flag = parseExpr() }
        return .loadStmt(name, dev, flag)
    }

    private mutating func parseSave() -> Stmt {
        advance() // SAVE
        let name = parseExpr(); consumeComma()
        let dev = parseExpr()
        return .saveStmt(name, dev)
    }

    private mutating func parseDef() -> Stmt {
        advance() // DEF
        guard case .keyword("FN") = peek else {
            recordError("Expected FN after DEF"); return skipToColon()
        }
        advance() // FN
        guard case .identifier(let fnName) = peek else {
            recordError("Expected function name after DEF FN"); return skipToColon()
        }
        advance()
        guard peek == .lparen else {
            recordError("Expected '(' in DEF FN \(fnName)"); return skipToColon()
        }
        advance() // (
        guard case .identifier(let param) = peek else {
            recordError("Expected parameter in DEF FN \(fnName)"); return skipToColon()
        }
        advance()
        consumeRParen()
        consumeOp("=", context: "DEF FN")
        let body = parseExpr()
        return .defFn(fnName, param, body)
    }

    // MARK: - Expression Parser

    /// Parses expressions with correct C64 BASIC operator precedence.
    mutating func parseExpr() -> Expr { parseOr() }

    private mutating func parseOr() -> Expr {
        var left = parseAnd()
        while case .keyword("OR") = peek {
            advance()
            left = .binaryOp("OR", left, parseAnd())
        }
        return left
    }

    private mutating func parseAnd() -> Expr {
        var left = parseNot()
        while case .keyword("AND") = peek {
            advance()
            left = .binaryOp("AND", left, parseNot())
        }
        return left
    }

    private mutating func parseNot() -> Expr {
        if case .keyword("NOT") = peek {
            advance()
            return .notOp(parseNot())
        }
        return parseComparison()
    }

    private mutating func parseComparison() -> Expr {
        let left = parseAddSub()
        if case .op(let op) = peek,
           ["=","<",">","<=",">=","<>"].contains(op) {
            advance()
            return .compareOp(op, left, parseAddSub())
        }
        return left
    }

    private mutating func parseAddSub() -> Expr {
        var left = parseMulDiv()
        while case .op(let op) = peek, op == "+" || op == "-" {
            advance()
            left = .binaryOp(op, left, parseMulDiv())
        }
        return left
    }

    private mutating func parseMulDiv() -> Expr {
        var left = parsePower()
        while case .op(let op) = peek, op == "*" || op == "/" {
            advance()
            left = .binaryOp(op, left, parsePower())
        }
        return left
    }

    private mutating func parsePower() -> Expr {
        let base = parseUnary()
        if case .op("^") = peek {
            advance()
            return .binaryOp("^", base, parsePower()) // right-associative
        }
        return base
    }

    private mutating func parseUnary() -> Expr {
        if case .op("-") = peek { advance(); return .unaryMinus(parseUnary()) }
        return parsePrimary()
    }

    private mutating func parsePrimary() -> Expr {
        switch peek {
        case .integer(let n):
            advance(); return .intLit(n)
        case .float(let f):
            advance(); return .floatLit(f)
        case .stringLiteral(let s):
            advance(); return .strLit(s)
        case .lparen:
            advance()
            let e = parseExpr()
            if peek == .rparen { advance() }
            return e
        case .identifier(let name):
            advance()
            if peek == .lparen {
                advance()
                let idxs = parseExprList(until: .rparen)
                consumeRParen()
                return .arrayRead(name, idxs)
            }
            return .floatVar(name)
        case .identifierStr(let name):
            advance()
            if peek == .lparen {
                advance()
                let idxs = parseExprList(until: .rparen)
                consumeRParen()
                return .arrayRead(name, idxs)
            }
            return .strVar(name)
        case .identifierInt(let name):
            advance()
            if peek == .lparen {
                advance()
                let idxs = parseExprList(until: .rparen)
                consumeRParen()
                return .arrayRead(name, idxs)
            }
            return .intVar(name)
        case .keyword(let kw):
            return parseFuncOrSysVar(kw)
        default:
            recordError("Expected expression, got \(peek)")
            advance()
            return .intLit(0)
        }
    }

    private static let numericFunctions: Set<String> = [
        "ABS","ATN","COS","EXP","FRE","INT","LOG","PEEK",
        "POS","RND","SGN","SIN","SQR","TAN","USR","LEN",
        "ASC","VAL"
    ]
    private static let stringFunctions: Set<String> = [
        "CHR$","LEFT$","RIGHT$","MID$","STR$"
    ]
    private static let noArgFunctions: Set<String> = ["TI","ST"]

    private mutating func parseFuncOrSysVar(_ kw: String) -> Expr {
        switch kw {
        case "TI": advance(); return .tiVar
        case "ST": advance(); return .stVar
        case "TAB(", "SPC(":
            advance()
            let arg = parseExpr()
            if peek == .rparen { advance() }
            return .funcCall(kw, [arg])
        case "FN":
            advance() // FN
            guard case .identifier(let fnName) = peek else {
                recordError("Expected function name after FN")
                return .intLit(0)
            }
            advance()
            guard peek == .lparen else {
                recordError("Expected '(' after FN \(fnName)")
                return .funcCall("FN\(fnName)", [])
            }
            advance() // (
            let arg = parseExpr()
            consumeRParen()
            return .funcCall("FN\(fnName)", [arg])
        default:
            let name = kw
            advance()
            guard peek == .lparen else {
                recordError("Expected '(' after \(kw)")
                return .funcCall(name, [])
            }
            advance() // (
            var args: [Expr] = []
            if peek != .rparen {
                args = parseExprList(until: .rparen)
            }
            consumeRParen()
            return .funcCall(name, args)
        }
    }

    private mutating func parseExprList(until terminator: BasicToken) -> [Expr] {
        var exprs: [Expr] = []
        while !atEOF && peek != terminator && peek != .colon {
            exprs.append(parseExpr())
            if peek == .comma { advance() }
        }
        return exprs
    }

    // MARK: - Helpers

    private var peek: BasicToken { tokens[safe: pos] ?? .eof }
    private var atEOF: Bool { peek == .eof }

    @discardableResult
    private mutating func advance() -> BasicToken {
        let t = peek
        if pos < tokens.count { pos += 1 }
        return t
    }

    private mutating func consumeComma() {
        if peek == .comma { advance() }
        else { recordError("Expected ','") }
    }

    private mutating func consumeRParen() {
        if peek == .rparen { advance() }
        else { recordError("Expected ')'") }
    }

    private mutating func consumeOp(_ op: String, context: String) {
        if case .op(let o) = peek, o == op { advance() }
        else { recordError("Expected '\(op)' in \(context)") }
    }

    private mutating func consumeKeyword(_ kw: String, context: String) {
        if case .keyword(let k) = peek, k == kw { advance() }
        else { recordError("Expected \(kw) in \(context)") }
    }

    private mutating func parseLineNumber(context: String) -> Int {
        if case .integer(let n) = peek { advance(); return n }
        recordError("Expected line number after \(context)")
        return 0
    }

    private mutating func parseVarName(context: String) -> String {
        switch peek {
        case .identifier(let n):    advance(); return n
        case .identifierStr(let n): advance(); return n
        case .identifierInt(let n): advance(); return n
        default:
            recordError("Expected variable name in \(context)")
            return "_err"
        }
    }

    @discardableResult
    private mutating func skipToColon() -> Stmt {
        while !atEOF && peek != .colon { advance() }
        return .remStmt
    }

    private mutating func recordError(_ message: String) {
        errors.append(ParseError(line: currentLineNumber, message: message))
    }
}

// MARK: - Safe Subscript
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

