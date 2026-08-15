//  BasicAST.swift
//  C64 IDE
//
//  Abstract Syntax Tree (AST) definitions for Commodore 64 BASIC V2.
//  Covers expressions, statements, and supporting types used by the parser
//  and compiler.

import Foundation

// MARK: - ParseError

/// Represents a syntax error encountered during BASIC parsing.
struct ParseError: Error, CustomStringConvertible {
    let line: Int       // BASIC line number (0 = unknown)
    let message: String
    
    var description: String {
        line > 0 ? "Line \(line): \(message)" : message
    }
}

// MARK: - Expression AST

/// Represents a C64 BASIC expression in the AST.
indirect enum Expr: Equatable {
    
    // ── Literals ───────────────────────────────────────────
    /// Integer constant (e.g., `42`, `53248`)
    case intLit(Int)
    /// Floating-point constant (e.g., `3.14`)
    case floatLit(Double)
    /// String literal (e.g., `"HELLO"`)
    case strLit(String)
    
    // ── Variables ──────────────────────────────────────────
    /// Plain numeric variable (e.g., `X`, `SCORE`)
    case floatVar(String)
    /// String variable (e.g., `A$`, `K$` — name includes `$`)
    case strVar(String)
    /// Integer variable (e.g., `A%`, `COUNT%` — name includes `%`)
    case intVar(String)
    
    // ── Array element read ─────────────────────────────────
    /// Array subscript read (e.g., `A(I)`, `B$(I,J)`, `C%(K)`)
    case arrayRead(String, [Expr])
    
    // ── Operators ──────────────────────────────────────────
    /// Arithmetic/logical operator (e.g., `+`, `-`, `*`, `/`, `^`, `AND`, `OR`)
    case binaryOp(String, Expr, Expr)
    /// Comparison operator (e.g., `=`, `<`, `>`, `<=`, `>=`, `<>`)
    case compareOp(String, Expr, Expr)
    /// Unary negation (e.g., `-X`)
    case unaryMinus(Expr)
    /// Logical NOT (e.g., `NOT X`)
    case notOp(Expr)
    
    // ── Function calls ─────────────────────────────────────
    /// Built-in BASIC function call (e.g., `CHR$`, `LEFT$`, `PEEK`, `FNA`)
    case funcCall(String, [Expr])
    
    // ── System pseudo-variables (no parens) ───────────────
    /// TI — Jiffy clock
    case tiVar
    /// ST — Status register
    case stVar
}

// MARK: - DimEntry

/// Represents a single array declaration within a `DIM` statement.
/// Example: `A(10)` or `B$(5,3)`.
struct DimEntry: Equatable {
    let name: String
    let dims: [Expr]
}

// MARK: - VarTarget

/// A destination a value can be stored into by an input-style statement
/// (`READ`, `INPUT#`). Either a plain variable or one element of an array —
/// `READ A(I)` and `INPUT#1,M%(J,K)` are both ordinary BASIC.
enum VarTarget: Equatable {
    case scalar(String)                     // A, A$, A%
    case element(String, [Expr])            // A(I), M%(J,K)

    /// The variable name, suffix included, with any subscript dropped.
    var name: String {
        switch self {
        case .scalar(let n):     return n
        case .element(let n, _): return n
        }
    }

    var subscripts: [Expr] {
        switch self {
        case .scalar:            return []
        case .element(_, let s): return s
        }
    }
}

// MARK: - Statement AST

/// Represents a C64 BASIC statement in the AST.
indirect enum Stmt: Equatable {
    
    // ── Assignment ─────────────────────────────────────────
    case letFloat(String, Expr)             // X = expr
    case letStr(String, Expr)               // A$ = expr
    case letInt(String, Expr)               // A% = expr
    case arrayWrite(String, [Expr], Expr)   // A(I) = expr
    
    // ── Control flow ───────────────────────────────────────
    case gotoStmt(Int)
    case gosubStmt(Int)
    case returnStmt
    case endStmt
    case stopStmt
    
    // ── Conditional ────────────────────────────────────────
    // THEN target is either a line number (gotoLine) or inline statements.
    // ELSE is always inline statements (or nil).
    case ifGoto(Expr, Int)                          // IF cond THEN lineno
    case ifThen(Expr, [Stmt], [Stmt]?)              // IF cond THEN stmts [ELSE stmts]
    
    // ── Loops ──────────────────────────────────────────────
    case forStmt(String, Expr, Expr, Expr?)         // FOR var = from TO to [STEP s]
    case nextStmt(String?)                          // NEXT [var]
    
    // ── I/O ────────────────────────────────────────────────
    case printStmt([PrintItem])
    case printHashStmt(Expr, [PrintItem])           // PRINT# lognum, items
    case inputStmt(String?, VarTarget)              // INPUT [prompt;] target
    case inputHashStmt(Expr, [VarTarget])           // INPUT# lognum, targets
    case getStmt([VarTarget])                       // GET target [, target ...]
    case getHashStmt(Expr, [VarTarget])             // GET# lognum, target [, ...]
    
    // ── Memory ─────────────────────────────────────────────
    case pokeStmt(Expr, Expr)
    case sysStmt(Expr)
    case waitStmt(Expr, Expr, Expr?)
    
    // ── Data ───────────────────────────────────────────────
    case dataStmt([DataValue])
    case readStmt([VarTarget])                      // READ target [, target ...]
    case restoreStmt
    
    // ── Arrays ─────────────────────────────────────────────
    case dimStmt([DimEntry])                // DIM A(10), B$(5,3)
    
    // ── ON GOTO / ON GOSUB ─────────────────────────────────
    case onGoto(Expr, [Int])
    case onGosub(Expr, [Int])
    
    // ── File I/O ───────────────────────────────────────────
    case openStmt(Expr, Expr, Expr, Expr?)          // OPEN log, dev, sec [, name$]
    case closeStmt(Expr)
    case cmdStmt(Expr)
    
    // ── Misc ───────────────────────────────────────────────
    case clrStmt
    case remStmt                                    // REM — no content stored (lexer swallowed it)
    case loadStmt(Expr, Expr, Expr?)               // LOAD name$, dev [, flag]
    case saveStmt(Expr, Expr)                      // SAVE name$, dev
    
    // ── User-defined functions ─────────────────────────────
    // DEF FN A(X) = X * X + 1
    // fnName is the single letter (e.g. "A"), param is the dummy variable name.
    // At call sites, FNA(expr) is represented as .funcCall("FNA", [expr]).
    case defFn(String, String, Expr)               // DEF FN name(param) = expr
}

// MARK: - Supporting Types

/// Represents a single item within a `PRINT` statement.
enum PrintItem: Equatable {
    /// Expression to print.
    case expr(Expr)
    /// Tab stop (produced by comma `,`).
    case tab
    /// Suppresses automatic CRLF after the print (produced by trailing semicolon `;`).
    case noNewline
}

/// Represents a single value from a `DATA` statement.
/// Stored as raw string initially, typed later during analysis.
enum DataValue: Equatable {
    /// Sign included: DATA -5 parses as .integer(-5), the same as the
    /// float path folds -1.5 to .float(-1.5).
    case integer(Int)
    case float(Double)
    case string(String)
}

// MARK: - Parsed Line

/// Represents a single BASIC line after parsing.
struct ParsedLine: Equatable {
    let number: Int
    let stmts: [Stmt]
}

// MARK: - Two-Character Name Canonicalization

/// BASIC V2 identifies a variable by its first two characters plus the
/// type suffix: SCORE and SCALE are both variable SC on hardware, and FN
/// names follow the same rule. The editor's analysis keeps full names (the
/// Variables panel exists to SHOW those collisions), but compiled code must
/// use hardware identity or programs written for the interpreter read and
/// write disjoint storage the machine would have shared. Applied to the
/// AST once, in the compile path only.
enum BasicNameCanonicalizer {

    static func canonicalName(_ name: String) -> String {
        var base = name
        var suffix = ""
        if base.hasSuffix("$") || base.hasSuffix("%") {
            suffix = String(base.removeLast())
        }
        return String(base.prefix(2)) + suffix
    }

    /// Only user FN calls carry a variable-rule name; built-in function
    /// names (PEEK, LEFT$, ...) pass through untouched.
    private static func canonicalFuncName(_ name: String) -> String {
        guard name.hasPrefix("FN"), name.count > 2 else { return name }
        return "FN" + canonicalName(String(name.dropFirst(2)))
    }

    static func rewrite(_ lines: [ParsedLine]) -> [ParsedLine] {
        lines.map { ParsedLine(number: $0.number, stmts: $0.stmts.map(rewrite)) }
    }

    private static func rewrite(_ t: VarTarget) -> VarTarget {
        switch t {
        case .scalar(let n):            return .scalar(canonicalName(n))
        case .element(let n, let subs): return .element(canonicalName(n), subs.map(rewrite))
        }
    }

    private static func rewrite(_ item: PrintItem) -> PrintItem {
        if case .expr(let e) = item { return .expr(rewrite(e)) }
        return item
    }

    private static func rewrite(_ s: Stmt) -> Stmt {
        switch s {
        case .letFloat(let n, let e): return .letFloat(canonicalName(n), rewrite(e))
        case .letStr(let n, let e):   return .letStr(canonicalName(n), rewrite(e))
        case .letInt(let n, let e):   return .letInt(canonicalName(n), rewrite(e))
        case .arrayWrite(let n, let idxs, let e):
            return .arrayWrite(canonicalName(n), idxs.map(rewrite), rewrite(e))
        case .forStmt(let n, let a, let b, let st):
            return .forStmt(canonicalName(n), rewrite(a), rewrite(b), st.map(rewrite))
        case .nextStmt(let n): return .nextStmt(n.map(canonicalName))
        case .printStmt(let items): return .printStmt(items.map(rewrite))
        case .printHashStmt(let e, let items):
            return .printHashStmt(rewrite(e), items.map(rewrite))
        case .inputStmt(let p, let t): return .inputStmt(p, rewrite(t))
        case .inputHashStmt(let e, let ts):
            return .inputHashStmt(rewrite(e), ts.map(rewrite))
        case .getStmt(let ts): return .getStmt(ts.map(rewrite))
        case .getHashStmt(let e, let ts):
            return .getHashStmt(rewrite(e), ts.map(rewrite))
        case .pokeStmt(let a, let v): return .pokeStmt(rewrite(a), rewrite(v))
        case .sysStmt(let e): return .sysStmt(rewrite(e))
        case .waitStmt(let a, let m, let x):
            return .waitStmt(rewrite(a), rewrite(m), x.map(rewrite))
        case .readStmt(let ts): return .readStmt(ts.map(rewrite))
        case .dimStmt(let entries):
            return .dimStmt(entries.map {
                DimEntry(name: canonicalName($0.name), dims: $0.dims.map(rewrite))
            })
        case .onGoto(let e, let t):  return .onGoto(rewrite(e), t)
        case .onGosub(let e, let t): return .onGosub(rewrite(e), t)
        case .ifGoto(let c, let t):  return .ifGoto(rewrite(c), t)
        case .ifThen(let c, let th, let el):
            return .ifThen(rewrite(c), th.map(rewrite), el.map { $0.map(rewrite) })
        case .defFn(let n, let p, let b):
            return .defFn(canonicalName(n), canonicalName(p), rewrite(b))
        case .openStmt(let l, let d, let sec, let n):
            return .openStmt(rewrite(l), rewrite(d), rewrite(sec), n.map(rewrite))
        case .closeStmt(let e): return .closeStmt(rewrite(e))
        case .cmdStmt(let e):   return .cmdStmt(rewrite(e))
        case .loadStmt(let n, let d, let f):
            return .loadStmt(rewrite(n), rewrite(d), f.map(rewrite))
        case .saveStmt(let n, let d): return .saveStmt(rewrite(n), rewrite(d))
        case .gotoStmt, .gosubStmt, .returnStmt, .endStmt, .stopStmt,
             .dataStmt, .restoreStmt, .clrStmt, .remStmt:
            return s
        }
    }

    private static func rewrite(_ e: Expr) -> Expr {
        switch e {
        case .floatVar(let n): return .floatVar(canonicalName(n))
        case .strVar(let n):   return .strVar(canonicalName(n))
        case .intVar(let n):   return .intVar(canonicalName(n))
        case .arrayRead(let n, let idxs):
            return .arrayRead(canonicalName(n), idxs.map(rewrite))
        case .binaryOp(let op, let l, let r):
            return .binaryOp(op, rewrite(l), rewrite(r))
        case .compareOp(let op, let l, let r):
            return .compareOp(op, rewrite(l), rewrite(r))
        case .unaryMinus(let inner): return .unaryMinus(rewrite(inner))
        case .notOp(let inner):      return .notOp(rewrite(inner))
        case .funcCall(let n, let args):
            return .funcCall(canonicalFuncName(n), args.map(rewrite))
        case .intLit, .floatLit, .strLit, .tiVar, .stVar:
            return e
        }
    }
}

