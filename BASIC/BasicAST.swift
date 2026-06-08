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
    case inputStmt(String?, String)                 // INPUT [prompt;] var
    case inputHashStmt(Expr, [String])              // INPUT# lognum, vars
    case getStmt(String)                            // GET var$
    case getHashStmt(Expr, String)                  // GET# lognum, var$
    
    // ── Memory ─────────────────────────────────────────────
    case pokeStmt(Expr, Expr)
    case sysStmt(Expr)
    case waitStmt(Expr, Expr, Expr?)
    
    // ── Data ───────────────────────────────────────────────
    case dataStmt([DataValue])
    case readStmt([String])                         // READ var [, var ...]
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
    case integer(Int)
    case float(Double)
    case string(String)
    /// `-N` (stored separately so the type analyzer sees the sign)
    case negative(Int)
}

// MARK: - Parsed Line

/// Represents a single BASIC line after parsing.
struct ParsedLine: Equatable {
    let number: Int
    let stmts: [Stmt]
}

