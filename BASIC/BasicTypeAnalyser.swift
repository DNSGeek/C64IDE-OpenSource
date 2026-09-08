import Foundation

// ═══════════════════════════════════════════════════════════
// MARK: - NumWidth  (the numeric width lattice)
// ═══════════════════════════════════════════════════════════
//
// Numeric types form a monotone lattice — they only widen, never shrink.
// Order:   byte  →  word  →  float
//
// "signed" is an orthogonal flag; a signed byte is still 1 byte of
// storage but arithmetic treats it as -128..127.

enum NumWidth: Int, Comparable {
    case byte  = 0   // 0..255      → .byte 0       (1 byte)
    case word  = 1   // 0..65535    → .word 0        (2 bytes, lo/hi)
    case float = 2   // any         → .res 5          (5 bytes, C64 ROM format)

    static func < (a: NumWidth, b: NumWidth) -> Bool { a.rawValue < b.rawValue }

    /// Returns the narrowest type that can safely hold both self and other.
    func widened(to other: NumWidth) -> NumWidth { max(self, other) }

    var description: String {
        switch self {
        case .byte:  "byte"
        case .word:  "word"
        case .float: "float"
        }
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - VarType
// ═══════════════════════════════════════════════════════════

enum VarType: Equatable {
    case numeric(width: NumWidth, signed: Bool)
    case string

    // ── Convenience constructors ───────────────────────────
    static let byte  = VarType.numeric(width: .byte,  signed: false)
    static let sbyte = VarType.numeric(width: .byte,  signed: true)
    static let word  = VarType.numeric(width: .word,  signed: false)
    static let sword = VarType.numeric(width: .word,  signed: true)
    static let float = VarType.numeric(width: .float, signed: true)

    // ── Monotone widening ──────────────────────────────────
    /// Combines two types into the narrowest supertype that preserves
    /// all possible values. Strings absorb numeric types, and signedness
    /// is preserved if either operand is signed.
    func widened(to other: VarType) -> VarType {
        switch (self, other) {
        case (.string, _), (_, .string):
            return .string
        case (.numeric(let wa, let sa), .numeric(let wb, let sb)):
            var width = wa.widened(to: wb)
            // An unsigned byte (0..255) and a signed byte (-128..127) have
            // no common 1-byte representation: joining them as "signed
            // byte" made X=200 read back as -56 and ended
            // FOR I=200 TO 0 STEP -1 after one iteration. Widen to a
            // signed word instead. (Words already accept the analogous
            // 16-bit wrap as a documented compromise.)
            if width == .byte && sa != sb { width = .word }
            return .numeric(width: width, signed: sa || sb)
        }
    }

    // ── Properties ────────────────────────────────────────
    var isString: Bool { if case .string = self { return true }; return false }
    var width: NumWidth? { if case .numeric(let w, _) = self { return w }; return nil }
    var isSigned: Bool { if case .numeric(_, let s) = self { return s }; return false }

    var description: String {
        switch self {
        case .string: return "string"
        case .numeric(let w, let s): return s ? "signed \(w.description)" : w.description
        }
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - SymbolTable
// ═══════════════════════════════════════════════════════════

/// Maps variable name → inferred VarType.
/// Names include suffix: "A$", "A%", "A" are separate entries.
struct SymbolTable {
    private(set) var types: [String: VarType] = [:]

    /// Look up a variable. Returns `.float` if unknown (safe fallback).
    subscript(_ name: String) -> VarType {
        types[name] ?? .float
    }

    /// Widen a variable's type. Returns true if type actually changed.
    @discardableResult
    mutating func widen(_ name: String, to newType: VarType) -> Bool {
        let current = types[name]
        let result  = current?.widened(to: newType) ?? newType
        if result == current { return false }
        types[name] = result
        return true
    }

    /// Force-set a type (for string variables whose type is known from syntax).
    mutating func set(_ name: String, _ type: VarType) {
        types[name] = type
    }

    /// Names seen in a read position, and names assigned from something
    /// whose type is only known after propagation. Neither is typed on
    /// the spot: seeding either as an unsigned byte BEFORE the real type
    /// arrived joined with e.g. sbyte into sword, pessimising every
    /// countdown loop whose variable was printed or copied. An absent
    /// entry is the lattice bottom during propagation.
    private(set) var referenced: Set<String> = []
    private(set) var declared: Set<String> = []

    mutating func reference(_ name: String) { referenced.insert(name) }
    mutating func declare(_ name: String)   { declared.insert(name) }

    /// Before propagation: a variable that is read but never assigned
    /// anywhere is always 0, so a byte is exact - and it must exist or
    /// emitStorage() never allocates it (`10 PRINT A` must assemble).
    mutating func materializeUnassignedReads() {
        for name in referenced where types[name] == nil && !declared.contains(name) {
            types[name] = .byte
        }
    }

    /// After propagation: anything still untyped could not be resolved
    /// (X=Y:Y=X with nothing else, or a chain longer than the iteration
    /// cap). Float is the only safe width for an unknown value.
    mutating func materializeRemaining() {
        for name in referenced.union(declared) where types[name] == nil {
            types[name] = .float
        }
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - BasicTypeAnalyser
// ═══════════════════════════════════════════════════════════
//
// Algorithm:
//   Phase 1 — Seed:      walk all statements, collect constraints
//                        from literal assignments and FOR bounds.
//   Phase 2 — Propagate: apply variable→variable constraints until
//                        no type changes (fixpoint, max 20 iterations).
//
// Types only ever widen, so termination is guaranteed. The iteration cap
// protects against pathological code while still covering all realistic
// C64 BASIC programs.

struct BasicTypeAnalyser {

    // ── Entry point ────────────────────────────────────────

    func analyse(_ lines: [ParsedLine]) -> SymbolTable {
        var table = SymbolTable()
        let dataHint = widestNumericDataType(lines)
        seedFromSyntax(lines, into: &table, dataHint: dataHint)
        table.materializeUnassignedReads()

        // Each pass can resolve at least one more link of an assignment
        // chain (A=B, B=C, ...); the cap only guards against pathological
        // input, and anything left unresolved falls back to float below.
        var iterations = 0
        var changed = true
        while changed && iterations < 100 {
            changed = propagate(lines, table: &table)
            iterations += 1
        }
        table.materializeRemaining()

        return table
    }

    // ═══════════════════════════════════════════════════════
    // MARK: - Phase 1: Seeding
    // ═══════════════════════════════════════════════════════

    private func seedFromSyntax(_ lines: [ParsedLine], into table: inout SymbolTable,
                                dataHint: VarType) {
        for line in lines {
            for stmt in line.stmts { seedStmt(stmt, into: &table, dataHint: dataHint) }
        }
    }

    /// Widest numeric type appearing in any DATA statement, classified
    /// exactly as the code generator classifies DATA items (0..255 byte,
    /// otherwise +/-32767 word, otherwise float; anything negative is
    /// signed). READ targets are seeded with this type because the
    /// DATA-to-READ mapping is a runtime property of the data pointer:
    /// statically, any numeric READ may receive the widest item in the
    /// pool. Programs whose numeric DATA all fits in a byte (the common
    /// sprite/charset case) fall back to .byte, preserving the fast
    /// indexed read path. DATA inside a THEN/ELSE clause counts, matching
    /// both real BASIC (the READ pointer scans program text) and the
    /// code generator's first-pass collection.
    private func widestNumericDataType(_ lines: [ParsedLine]) -> VarType {
        var hint = VarType.byte
        func scan(_ stmt: Stmt) {
            switch stmt {
            case .dataStmt(let vals):
                for v in vals {
                    switch v {
                    case .integer(let n):
                        if n >= 0 && n <= 255 {
                            // Fits the byte floor; nothing to widen.
                        } else if n >= -32768 && n <= 32767 {
                            hint = hint.widened(to: n < 0 ? .sword : .word)
                        } else {
                            hint = hint.widened(to: .float)
                        }
                    case .float:
                        hint = hint.widened(to: .float)
                    case .string:
                        break
                    }
                }
            case .ifThen(_, let then, let els):
                then.forEach(scan)
                els?.forEach(scan)
            default:
                break
            }
        }
        for line in lines { for stmt in line.stmts { scan(stmt) } }
        return hint
    }

    private func seedStmt(_ stmt: Stmt, into t: inout SymbolTable,
                          dataHint: VarType) {
        switch stmt {

        case .letStr(let name, let rhs):
            t.set(name, .string)
            seedExpr(rhs, into: &t)

        case .letInt(let name, let rhs):
            t.widen(name, to: .word)          // % vars are 16-bit in BASIC
            seedExpr(rhs, into: &t)

        case .letFloat(let name, let rhs):
            if let hint = literalTypeHint(rhs) { t.widen(name, to: hint) }
            else { t.declare(name) }
            seedExpr(rhs, into: &t)

        case .forStmt(let v, let from, let to, let step):
            // The STEP participates in the loop variable's type: a
            // fractional step (STEP 0.5) must force the whole loop to
            // float, or the step slot truncates it to 0 and the loop
            // never advances.
            if let fh = literalTypeHint(from), let th = literalTypeHint(to) {
                t.widen(v, to: loopVarType(from: from, to: to,
                                           bounds: fh.widened(to: th),
                                           stepType: step.flatMap(literalTypeHint)))
            } else {
                t.declare(v)
            }
            seedExpr(from, into: &t)
            seedExpr(to, into: &t)
            if let s = step { seedExpr(s, into: &t) }

        case .arrayWrite(let name, let idxs, let rhs):
            if name.hasSuffix("$") { t.set(name, .string) }
            else if name.hasSuffix("%") { t.widen(name, to: .word) }
            else if let hint = literalTypeHint(rhs) { t.widen(name, to: hint) }
            else { t.declare(name) }
            idxs.forEach { seedExpr($0, into: &t) }
            seedExpr(rhs, into: &t)

        case .getStmt(let targets):
            for target in targets { seedTarget(target, to: .byte, into: &t) }   // GETIN returns one byte

        case .getHashStmt(let logNum, let targets):
            seedExpr(logNum, into: &t)
            for target in targets { seedTarget(target, to: .byte, into: &t) }

        // INPUT accepts any number the interpreter does — a plain variable
        // must be able to hold 3.14. Seeding .word routed the read through
        // the integer input helper, silently dropping the fraction the
        // user typed.
        case .inputStmt(_, let target):
            seedTarget(target, to: .float, into: &t)

        case .inputHashStmt(let logNum, let targets):
            seedExpr(logNum, into: &t)
            for target in targets {
                seedTarget(target, to: .float, into: &t)
            }

        case .defFn(_, _, let body):
            seedExpr(body, into: &t)

        case .readStmt(let targets):
            // Numeric READ targets: the DATA-to-READ mapping is only known
            // at runtime, so seed with the widest numeric type present in
            // any DATA statement (see widestNumericDataType). All-byte
            // DATA — the common sprite/charset case — seeds .byte and
            // keeps the fast indexed read path; a program whose DATA
            // contains a word or float seeds wide enough that no READ can
            // truncate.
            targets.forEach { seedTarget($0, to: dataHint, into: &t) }

        case .dimStmt(let entries):
            for entry in entries {
                if entry.name.hasSuffix("$") { t.set(entry.name, .string) }
                else if entry.name.hasSuffix("%") { t.widen(entry.name, to: .word) }
                entry.dims.forEach { seedExpr($0, into: &t) }
            }

        case .ifGoto(let cond, _):
            seedExpr(cond, into: &t)

        case .ifThen(let cond, let then, let els):
            seedExpr(cond, into: &t)
            then.forEach { seedStmt($0, into: &t, dataHint: dataHint) }
            els?.forEach { seedStmt($0, into: &t, dataHint: dataHint) }

        case .printStmt(let items):
            items.forEach { if case .expr(let e) = $0 { seedExpr(e, into: &t) } }

        case .printHashStmt(let n, let items):
            seedExpr(n, into: &t)
            items.forEach { if case .expr(let e) = $0 { seedExpr(e, into: &t) } }

        case .pokeStmt(let addr, let val):
            seedExpr(addr, into: &t)
            seedExpr(val, into: &t)

        case .waitStmt(let addr, let mask, let xor):
            seedExpr(addr, into: &t)
            seedExpr(mask, into: &t)
            if let x = xor { seedExpr(x, into: &t) }

        case .sysStmt(let e):   seedExpr(e, into: &t)
        case .closeStmt(let e): seedExpr(e, into: &t)
        case .cmdStmt(let e):   seedExpr(e, into: &t)

        case .onGoto(let e, _), .onGosub(let e, _):
            seedExpr(e, into: &t)

        case .openStmt(let l, let d, let s, let n):
            [l, d, s].forEach { seedExpr($0, into: &t) }
            if let n = n { seedExpr(n, into: &t) }

        // LOAD/SAVE sub-expressions were never seeded, so a variable used
        // only there (LOAD "DATA",D) got no storage and the assembly
        // failed with an undefined var_ symbol.
        case .loadStmt(let n, let d, let f):
            seedExpr(n, into: &t)
            seedExpr(d, into: &t)
            if let f = f { seedExpr(f, into: &t) }
        case .saveStmt(let n, let d):
            seedExpr(n, into: &t)
            seedExpr(d, into: &t)

        default: break
        }
    }

    /// Seeds an input-style destination: strings are settled by the suffix,
    /// numerics widen to at least `numeric`, and any subscript expression is
    /// seeded as an ordinary read.
    private func seedTarget(_ target: VarTarget, to numeric: VarType,
                            into t: inout SymbolTable) {
        let name = target.name
        target.subscripts.forEach { seedExpr($0, into: &t) }
        if name.hasSuffix("$") { t.set(name, .string) }
        // % variables are 16-bit regardless of the statement's own hint;
        // a GET-only A% used to be seeded .byte against 2-byte semantics.
        else if name.hasSuffix("%") { t.widen(name, to: .word) }
        else { t.widen(name, to: numeric) }
    }

    private func seedExpr(_ expr: Expr, into t: inout SymbolTable) {
        switch expr {
        case .strVar(let name):   t.set(name, .string)
        case .intVar(let name):   t.widen(name, to: .word)
        case .floatVar(let name):
            // Every referenced variable must at least exist in the table,
            // or emitStorage() never allocates it and the assembly fails
            // with an undefined var_ symbol (e.g. `10 PRINT A` with A
            // never assigned). Recorded now, materialized after seeding
            // so a read can never pre-empt the assignment's own type.
            t.reference(name)
        case .binaryOp(_, let l, let r):
            seedExpr(l, into: &t); seedExpr(r, into: &t)
        case .compareOp(_, let l, let r):
            seedExpr(l, into: &t); seedExpr(r, into: &t)
        case .unaryMinus(let e):  seedExpr(e, into: &t)
        case .notOp(let e):       seedExpr(e, into: &t)
        case .funcCall(_, let args): args.forEach { seedExpr($0, into: &t) }
        case .arrayRead(_, let idxs): idxs.forEach { seedExpr($0, into: &t) }
        default: break
        }
    }

    // ═══════════════════════════════════════════════════════
    // MARK: - Phase 2: Propagation
    // ═══════════════════════════════════════════════════════

    private func propagate(_ lines: [ParsedLine], table t: inout SymbolTable) -> Bool {
        var changed = false
        for line in lines {
            for stmt in line.stmts {
                if propagateStmt(stmt, table: &t) { changed = true }
            }
        }
        return changed
    }

    private func propagateStmt(_ stmt: Stmt, table t: inout SymbolTable) -> Bool {
        var ch = false
        switch stmt {

        case .letFloat(let name, let rhs):
            if let typ = inferExpr(rhs, table: t), t.widen(name, to: typ) { ch = true }

        case .letInt(let name, let rhs):
            if let typ = inferExpr(rhs, table: t),
               t.widen(name, to: typ.widened(to: .word)) { ch = true }

        case .letStr(let name, _):
            if t.widen(name, to: .string) { ch = true }

        case .forStmt(let v, let from, let to, let step):
            // The step's inferred type must feed in here too: STEP S with
            // S=0.5 assigned elsewhere has no literal hint, and without
            // this the loop stayed byte, stored a step of 0, and never
            // terminated.
            if let ft = inferExpr(from, table: t), let tt = inferExpr(to, table: t) {
                let typ = loopVarType(from: from, to: to,
                                      bounds: ft.widened(to: tt),
                                      stepType: step.flatMap { inferExpr($0, table: t) })
                if t.widen(v, to: typ) { ch = true }
            }

        case .arrayWrite(let name, _, let rhs):
            if !name.hasSuffix("$") && !name.hasSuffix("%"),
               let typ = inferExpr(rhs, table: t),
               t.widen(name, to: typ) { ch = true }

        case .ifGoto(let cond, _):
            ch = propagateExpr(cond, table: &t)

        case .ifThen(let cond, let then, let els):
            ch = propagateExpr(cond, table: &t)
            then.forEach { if propagateStmt($0, table: &t) { ch = true } }
            els?.forEach { if propagateStmt($0, table: &t) { ch = true } }

        case .printStmt(let items):
            items.forEach { if case .expr(let e) = $0 { if propagateExpr(e, table: &t) { ch = true } } }

        case .pokeStmt(let addr, let val):
            // Address: widen to word (must be 16-bit addressable)
            if propagateExprWithHint(addr, hint: .word, table: &t) { ch = true }
            if propagateExpr(val, table: &t) { ch = true }

        case .waitStmt(let addr, let mask, let xor):
            if propagateExprWithHint(addr, hint: .word, table: &t) { ch = true }
            if propagateExpr(mask, table: &t) { ch = true }
            if let x = xor, propagateExpr(x, table: &t) { ch = true }

        default: break
        }
        return ch
    }

    private func propagateExpr(_ expr: Expr, table t: inout SymbolTable) -> Bool {
        var ch = false
        switch expr {
        case .binaryOp(_, let l, let r):
            ch = propagateExpr(l, table: &t); ch = propagateExpr(r, table: &t) || ch

        case .compareOp(_, let l, let r):
            // Comparison-driven widening: both operands must be representable
            // in the same width. E.g. "TT > DE" where DE=word → widen TT to word.
            ch = propagateExpr(l, table: &t); ch = propagateExpr(r, table: &t) || ch
            if let lt = inferExpr(l, table: t), let rt = inferExpr(r, table: t),
               !lt.isString, !rt.isString {
                let wider = lt.widened(to: rt)
                ch = widenVarsInExpr(l, to: wider, table: &t) || ch
                ch = widenVarsInExpr(r, to: wider, table: &t) || ch
            }

        case .unaryMinus(let e): ch = propagateExpr(e, table: &t)
        case .notOp(let e):      ch = propagateExpr(e, table: &t)
        case .funcCall(_, let args):
            args.forEach { if propagateExpr($0, table: &t) { ch = true } }
        default: break
        }
        return ch
    }

    /// Widen all variables directly referenced by `expr` to at least `minType`'s width.
    private func widenVarsInExpr(
        _ expr: Expr, to minType: VarType, table t: inout SymbolTable
    ) -> Bool {
        guard !minType.isString, let minWidth = minType.width else { return false }
        switch expr {
        case .floatVar(let name):
            // An untyped (bottom) variable takes the width unsigned; a
            // later assignment can still make it signed.
            let cur = t.types[name] ?? .byte
            let newType = cur.widened(to: VarType.numeric(width: minWidth, signed: cur.isSigned))
            return t.widen(name, to: newType)
        case .intVar(let name):
            return t.widen(name, to: minType.widened(to: .word))
        case .binaryOp(_, let l, let r):
            let lc = widenVarsInExpr(l, to: minType, table: &t)
            let rc = widenVarsInExpr(r, to: minType, table: &t)
            return lc || rc
        default:
            return false
        }
    }

    private func propagateExprWithHint(
        _ expr: Expr, hint: VarType, table t: inout SymbolTable
    ) -> Bool {
        switch expr {
        case .floatVar(let name):
            return t.widen(name, to: hint)
        case .intVar(let name):
            return t.widen(name, to: hint.widened(to: .word))
        case .binaryOp(_, let l, let r):
            let lc = propagateExprWithHint(l, hint: hint, table: &t)
            let rc = propagateExpr(r, table: &t)
            return lc || rc
        default:
            return propagateExpr(expr, table: &t)
        }
    }

    // ═══════════════════════════════════════════════════════
    // MARK: - Expression type inference (public for tests)
    // ═══════════════════════════════════════════════════════

    /// Type of an expression, or nil while it depends on a variable that
    /// has no type yet (the lattice bottom). Callers skip widening on nil
    /// and try again on the next propagation pass; that keeps the result
    /// independent of statement order (Y=X before X=ST must still make Y
    /// a signed byte, not "byte now, then sword").
    func inferExpr(_ expr: Expr, table: SymbolTable) -> VarType? {
        switch expr {

        // ── Literals ────────────────────────────────────────
        case .intLit(let n):  return typeOfInt(n)
        case .floatLit:       return .float
        case .strLit:         return .string

        // ── Variables ──────────────────────────────────────
        case .floatVar(let name): return table.types[name]
        case .strVar:             return .string
        case .intVar(let name):   return (table.types[name] ?? .word).widened(to: .word)
        case .tiVar:              return .word   // 24-bit jiffy counter, fits in word
        case .stVar:              return .sbyte  // ROM converts $90 as a signed byte: DEVICE NOT PRESENT reads -128

        // ── Array element ───────────────────────────────────
        case .arrayRead(let name, _):
            if name.hasSuffix("$") { return .string }
            if name.hasSuffix("%") { return (table.types[name] ?? .word).widened(to: .word) }
            // A float array that is only ever read holds zeros.
            return table.types[name] ?? .byte

        // ── Arithmetic ──────────────────────────────────────
        case .binaryOp(let op, let l, let r):
            // Literal-only subtrees fold to their exact value: 100+100 is
            // a byte, 256*256 is a float (the old rule called it a word
            // and the compiled program wrapped it to 0).
            if let v = foldConstant(expr) { return typeOfInt(v) }
            if op == "/" || op == "^" { return .float }
            guard let lt = inferExpr(l, table: table),
                  let rt = inferExpr(r, table: table) else { return nil }
            return arithmeticResultType(op, lt, rt)

        case .unaryMinus(let e):
            if let v = foldConstant(expr) { return typeOfInt(v) }
            return inferExpr(e, table: table).map(negatedType)

        case .notOp:
            return .sword   // NOT returns 0 or -1

        // ── Comparisons ─────────────────────────────────────
        case .compareOp:
            return .sword   // BASIC V2: 0 (false) or -1 (true)

        // ── Function return types ────────────────────────────
        case .funcCall(let name, _):
            return funcReturnType(name)
        }
    }

    private func funcReturnType(_ name: String) -> VarType {
        switch name {
        case "PEEK", "ASC":                         return .byte
        case "LEN", "POS", "FRE":                  return .word
        case "CHR$", "LEFT$", "RIGHT$", "MID$", "STR$": return .string
        case "TAB(", "SPC(":                        return .word
        case "ABS", "ATN", "COS", "EXP", "INT",
             "LOG", "RND", "SGN", "SIN", "SQR",
             "TAN", "USR", "VAL":                  return .float
        default:                                    return .float
        }
    }

    // ═══════════════════════════════════════════════════════
    // MARK: - Helpers
    // ═══════════════════════════════════════════════════════

    /// Narrowest type that can hold integer n.
    func typeOfInt(_ n: Int) -> VarType {
        if n < 0 {
            if n >= -128   { return .sbyte }
            if n >= -32768 { return .sword }
            return .float
        }
        if n <= 255  { return .byte }
        if n <= 65535 { return .word }
        return .float
    }

    /// Result type of an arithmetic operator on already-typed operands.
    /// Shared by inference and literal seeding so the two can never drift.
    private func arithmeticResultType(_ op: String, _ lt: VarType, _ rt: VarType) -> VarType {
        switch op {
        case "+":
            return lt.widened(to: rt).widened(to: .word)   // byte + byte can carry past 255
        case "-":
            // byte - byte spans -255..255, which a signed BYTE cannot hold:
            // typing it sbyte made A=10:B=200:C=A-B print 66 instead of
            // -190 and X=255:X=X-1 read back as -2. Signed word is the
            // narrowest storage that covers the range.
            return lt.widened(to: rt).widened(to: .sword)
        case "*":
            // If either operand is float, result is float (e.g. ZR*ZI in Mandelbrot).
            // Otherwise widen both — byte*byte can overflow to word.
            let wider = lt.widened(to: rt)
            if case .numeric(let w, _) = wider, w == .byte { return .word }
            return wider
        case "/":         return .float                 // BASIC V2 / is ALWAYS floating-point
        case "^":         return .float                 // power is always float
        case "AND", "OR": return lt.widened(to: rt)
        default:          return .float
        }
    }

    /// Type of -x for an operand of type t. Negating an unsigned byte
    /// spans -255..0, so it needs a signed word; wider operands keep their
    /// width and turn signed.
    private func negatedType(_ t: VarType) -> VarType {
        guard case .numeric(let w, _) = t else { return t }
        if w == .byte { return .sword }
        return .numeric(width: w, signed: true)
    }

    /// Exact integer value of a literal-only subtree (+, -, * and unary
    /// minus over integer literals), or nil when anything else appears or
    /// the arithmetic overflows Int.
    func foldConstant(_ expr: Expr) -> Int? {
        switch expr {
        case .intLit(let n): return n
        case .unaryMinus(let e):
            guard let v = foldConstant(e) else { return nil }
            return v == Int.min ? nil : -v
        case .binaryOp(let op, let l, let r):
            guard let a = foldConstant(l), let b = foldConstant(r) else { return nil }
            let (v, overflow): (Int, Bool)
            switch op {
            case "+": (v, overflow) = a.addingReportingOverflow(b)
            case "-": (v, overflow) = a.subtractingReportingOverflow(b)
            case "*": (v, overflow) = a.multipliedReportingOverflow(by: b)
            default:  return nil
            }
            return overflow ? nil : v
        default: return nil
        }
    }

    /// Type of a FOR loop variable from its bounds and step. A negative
    /// step makes the loop signed; when both bounds are literals that fit
    /// a signed byte, the loop can stay a signed byte instead of paying
    /// for the byte/sbyte join's widening to word — FOR I=10 TO 1 STEP -1
    /// is the canonical countdown and deserves the 8-bit NEXT. A step
    /// whose type is not known yet contributes nothing this pass.
    private func loopVarType(from: Expr, to: Expr,
                             bounds: VarType, stepType: VarType?) -> VarType {
        guard let stepType = stepType else { return bounds }
        if stepType == .sbyte, bounds == .byte,
           let f = foldConstant(from), let t = foldConstant(to),
           (0...127).contains(f), (0...127).contains(t) {
            return .sbyte
        }
        return bounds.widened(to: stepType)
    }

    /// Type of a literal-only expression, for seeding before propagation.
    /// Nil for anything involving a variable or function: those are left
    /// untyped (bottom) so propagation can assign the exact type instead
    /// of joining it with a guessed unsigned byte.
    private func literalTypeHint(_ expr: Expr) -> VarType? {
        if let v = foldConstant(expr) { return typeOfInt(v) }
        switch expr {
        case .intLit(let n):  return typeOfInt(n)
        case .floatLit:       return .float
        case .strLit:         return .string
        case .unaryMinus(let e):
            return literalTypeHint(e).map(negatedType)
        case .binaryOp(let op, let l, let r):
            // Mirror inferExpr so seeding catches float-producing ops.
            if op == "/" || op == "^" { return .float }
            guard let lt = literalTypeHint(l), let rt = literalTypeHint(r) else { return nil }
            return arithmeticResultType(op, lt, rt)
        default:
            return nil
        }
    }
}

