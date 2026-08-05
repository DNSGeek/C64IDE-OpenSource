//  BasicVariableScanner.swift
//  C64 IDE
//
//  Walks a parsed BASIC program and collects per-variable metadata for the
//  Variables reference tab: kind, inferred type, first line seen, all lines
//  referenced, read/write counts, initial value (when the first write is a
//  literal), array dimensions, and two-character name collisions.
//
//  Runs on the output of BasicParser + BasicTypeAnalyser. Pure value types,
//  safe to run on a background queue.

import Foundation

// MARK: - BasicVariableInfo

struct BasicVariableInfo: Equatable {
    enum Kind: String {
        case scalar   = "var"
        case array    = "array"
        case function = "FN"
    }

    let name: String            // As written, including $/% suffix (e.g. "SC%", "A$")
    let kind: Kind
    let type: VarType           // From BasicTypeAnalyser (byte/word/float/signed/string)
    let firstLine: Int          // BASIC line number of first appearance
    let lines: [Int]            // Sorted, unique BASIC line numbers referencing it
    let readCount: Int
    let writeCount: Int
    let initialValue: String?   // Display string when first write RHS is a literal
    let dims: String?           // "10,5" for DIM A(10,5); "10 (implicit)" if never DIMed
    let collidesWith: [String]  // Other names sharing the 2-char identity (BASIC V2)

    var typeDescription: String { type.description }
}

// MARK: - BasicVariableScanner

struct BasicVariableScanner {

    /// When true (interpreted BASIC V2 semantics), only the first two
    /// characters of a name are significant and collisions are reported.
    /// Pass false for dialects like Vision BASIC that honor longer names.
    var honorsTwoCharNames: Bool = true

    // MARK: Accumulator

    private struct Acc {
        var kind: BasicVariableInfo.Kind
        var firstLine: Int
        var lines: Set<Int> = []
        var reads = 0
        var writes = 0
        var initialValue: String? = nil
        var sawFirstWrite = false
        var dims: String? = nil
    }

    // Keyed by kind + name so scalar A and array A() stay separate,
    // matching BASIC V2 (they are distinct entities on hardware).
    private struct Key: Hashable {
        let kind: BasicVariableInfo.Kind
        let name: String
    }

    // MARK: - Entry point

    func scan(_ lines: [ParsedLine], types: SymbolTable) -> [BasicVariableInfo] {
        var acc: [Key: Acc] = [:]

        for line in lines {
            for stmt in line.stmts {
                scanStmt(stmt, line: line.number, into: &acc)
            }
        }

        // Two-character collision map (per suffix kind, scalars and arrays
        // grouped separately since they don't collide with each other).
        var collisions: [Key: [String]] = [:]
        if honorsTwoCharNames {
            var groups: [String: [Key]] = [:]
            for key in acc.keys where key.kind != .function {
                groups[twoCharIdentity(of: key), default: []].append(key)
            }
            for (_, members) in groups where members.count > 1 {
                for key in members {
                    collisions[key] = members
                        .filter { $0 != key }
                        .map { $0.name }
                        .sorted()
                }
            }
        }

        return acc.map { key, a in
            BasicVariableInfo(
                name: key.name,
                kind: key.kind,
                type: types[key.name],
                firstLine: a.firstLine,
                lines: a.lines.sorted(),
                readCount: a.reads,
                writeCount: a.writes,
                initialValue: a.initialValue,
                dims: key.kind == .array ? (a.dims ?? "10 (implicit)") : nil,
                collidesWith: collisions[key] ?? []
            )
        }
        .sorted { $0.name < $1.name }
    }

    /// The identity BASIC V2 actually uses: first two characters + suffix.
    /// "SCORE" and "SCALE" are both "SC"; "SCORE$" is "SC$" and distinct.
    private func twoCharIdentity(of key: Key) -> String {
        var base = key.name
        var suffix = ""
        if base.hasSuffix("$") || base.hasSuffix("%") {
            suffix = String(base.removeLast())
        }
        let prefix = String(base.prefix(2))
        return "\(key.kind.rawValue)|\(prefix)\(suffix)"
    }

    // MARK: - Statement walk

    private func scanStmt(_ stmt: Stmt, line: Int, into acc: inout [Key: Acc]) {
        switch stmt {

        // Assignment: target is a write, RHS is reads.
        case .letFloat(let name, let rhs),
             .letStr(let name, let rhs),
             .letInt(let name, let rhs):
            recordWrite(.scalar, name, line, rhs: rhs, into: &acc)
            scanExpr(rhs, line: line, into: &acc)

        case .arrayWrite(let name, let subs, let rhs):
            recordWrite(.array, name, line, rhs: rhs, into: &acc)
            subs.forEach { scanExpr($0, line: line, into: &acc) }
            scanExpr(rhs, line: line, into: &acc)

        // FOR writes the loop var; bounds are reads.
        case .forStmt(let name, let from, let to, let step):
            recordWrite(.scalar, name, line, rhs: from, into: &acc)
            scanExpr(from, line: line, into: &acc)
            scanExpr(to, line: line, into: &acc)
            if let step { scanExpr(step, line: line, into: &acc) }

        case .nextStmt(let name):
            if let name { recordRead(.scalar, name, line, into: &acc) }

        // I/O writes.
        case .inputStmt(_, let name):
            recordWrite(.scalar, name, line, rhs: nil, into: &acc)
        case .inputHashStmt(let lognum, let names):
            scanExpr(lognum, line: line, into: &acc)
            names.forEach { recordWrite(.scalar, $0, line, rhs: nil, into: &acc) }
        case .getStmt(let name):
            recordWrite(.scalar, name, line, rhs: nil, into: &acc)
        case .getHashStmt(let lognum, let name):
            scanExpr(lognum, line: line, into: &acc)
            recordWrite(.scalar, name, line, rhs: nil, into: &acc)
        case .readStmt(let names):
            names.forEach { recordWrite(.scalar, $0, line, rhs: nil, into: &acc) }

        // Pure expression consumers.
        case .printStmt(let items):
            scanPrintItems(items, line: line, into: &acc)
        case .printHashStmt(let lognum, let items):
            scanExpr(lognum, line: line, into: &acc)
            scanPrintItems(items, line: line, into: &acc)
        case .pokeStmt(let a, let v):
            scanExpr(a, line: line, into: &acc)
            scanExpr(v, line: line, into: &acc)
        case .sysStmt(let e), .closeStmt(let e), .cmdStmt(let e):
            scanExpr(e, line: line, into: &acc)
        case .waitStmt(let a, let m, let x):
            scanExpr(a, line: line, into: &acc)
            scanExpr(m, line: line, into: &acc)
            if let x { scanExpr(x, line: line, into: &acc) }
        case .openStmt(let log, let dev, let sec, let name):
            [log, dev, sec].forEach { scanExpr($0, line: line, into: &acc) }
            if let name { scanExpr(name, line: line, into: &acc) }
        case .loadStmt(let name, let dev, let flag):
            scanExpr(name, line: line, into: &acc)
            scanExpr(dev, line: line, into: &acc)
            if let flag { scanExpr(flag, line: line, into: &acc) }
        case .saveStmt(let name, let dev):
            scanExpr(name, line: line, into: &acc)
            scanExpr(dev, line: line, into: &acc)
        case .onGoto(let e, _), .onGosub(let e, _):
            scanExpr(e, line: line, into: &acc)

        // DIM declares arrays; treated as the array's defining write.
        case .dimStmt(let entries):
            for entry in entries {
                recordWrite(.array, entry.name, line, rhs: nil, into: &acc)
                let key = Key(kind: .array, name: entry.name)
                if acc[key]?.dims == nil {
                    acc[key]?.dims = entry.dims
                        .map { literalDisplay($0) ?? "?" }
                        .joined(separator: ",")
                }
                entry.dims.forEach { scanExpr($0, line: line, into: &acc) }
            }

        // Conditionals recurse.
        case .ifGoto(let cond, _):
            scanExpr(cond, line: line, into: &acc)
        case .ifThen(let cond, let thenStmts, let elseStmts):
            scanExpr(cond, line: line, into: &acc)
            thenStmts.forEach { scanStmt($0, line: line, into: &acc) }
            elseStmts?.forEach { scanStmt($0, line: line, into: &acc) }

        // DEF FN: the function itself, plus its body. The dummy param is a
        // real BASIC V2 variable (shares global storage), so record it too.
        case .defFn(let fnName, let param, let body):
            recordWrite(.function, "FN" + fnName, line, rhs: body, into: &acc)
            recordWrite(.scalar, param, line, rhs: nil, into: &acc)
            scanExpr(body, line: line, into: &acc)

        // No variable traffic.
        case .gotoStmt, .gosubStmt, .returnStmt, .endStmt, .stopStmt,
             .dataStmt, .restoreStmt, .clrStmt, .remStmt:
            break
        }
    }

    private func scanPrintItems(_ items: [PrintItem], line: Int,
                                into acc: inout [Key: Acc]) {
        for item in items {
            if case .expr(let e) = item {
                scanExpr(e, line: line, into: &acc)
            }
        }
    }

    // MARK: - Expression walk (reads)

    private func scanExpr(_ expr: Expr, line: Int, into acc: inout [Key: Acc]) {
        switch expr {
        case .floatVar(let n), .strVar(let n), .intVar(let n):
            recordRead(.scalar, n, line, into: &acc)
        case .arrayRead(let n, let subs):
            recordRead(.array, n, line, into: &acc)
            subs.forEach { scanExpr($0, line: line, into: &acc) }
        case .binaryOp(_, let l, let r), .compareOp(_, let l, let r):
            scanExpr(l, line: line, into: &acc)
            scanExpr(r, line: line, into: &acc)
        case .unaryMinus(let e), .notOp(let e):
            scanExpr(e, line: line, into: &acc)
        case .funcCall(let name, let args):
            // FNA(x) call sites arrive as funcCall("FNA", args).
            if name.hasPrefix("FN") && name.count > 2 {
                recordRead(.function, name, line, into: &acc)
            }
            args.forEach { scanExpr($0, line: line, into: &acc) }
        case .intLit, .floatLit, .strLit, .tiVar, .stVar:
            break
        }
    }

    // MARK: - Recording

    private func recordRead(_ kind: BasicVariableInfo.Kind, _ name: String,
                            _ line: Int, into acc: inout [Key: Acc]) {
        touch(kind, name, line, into: &acc)
        acc[Key(kind: kind, name: name)]?.reads += 1
    }

    private func recordWrite(_ kind: BasicVariableInfo.Kind, _ name: String,
                             _ line: Int, rhs: Expr?,
                             into acc: inout [Key: Acc]) {
        touch(kind, name, line, into: &acc)
        let key = Key(kind: kind, name: name)
        acc[key]?.writes += 1
        if acc[key]?.sawFirstWrite == false {
            acc[key]?.sawFirstWrite = true
            // Only claim an initial value when it's a plain literal.
            // Everything is 0 / "" before first assignment anyway; showing
            // a folded arbitrary expression here would be a lie half the time.
            if let rhs { acc[key]?.initialValue = literalDisplay(rhs) }
        }
    }

    private func touch(_ kind: BasicVariableInfo.Kind, _ name: String,
                       _ line: Int, into acc: inout [Key: Acc]) {
        let key = Key(kind: kind, name: name)
        if acc[key] == nil {
            acc[key] = Acc(kind: kind, firstLine: line)
        }
        acc[key]?.lines.insert(line)
    }

    /// Renders literal-only expressions for the "Init" column. Returns nil
    /// for anything with a variable or function in it.
    private func literalDisplay(_ expr: Expr) -> String? {
        switch expr {
        case .intLit(let n):
            return String(n)
        case .floatLit(let f):
            return f == f.rounded() && abs(f) < 1e15
                ? String(Int(f)) : String(f)
        case .strLit(let s):
            return "\"\(s)\""
        case .unaryMinus(let inner):
            guard let s = literalDisplay(inner) else { return nil }
            return "-" + s
        default:
            return nil
        }
    }
}
