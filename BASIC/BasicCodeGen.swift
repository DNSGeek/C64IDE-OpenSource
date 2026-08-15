// MARK: - BasicCodeGen.swift
//
// Compiled under: Swift 5.9+ | ca65 assembler
// Architecture:   Commodore 64 (6502/6510)
// Purpose:        Generates ca65 assembly from a typed, parsed BASIC V2 AST.
//                 Driven entirely by SymbolTable type information to minimize
//                 runtime overhead and avoid unnecessary FAC/ROM float calls.
//
// Open Source License: [Insert License Here]
// Author: [Your Name/Handle]
// Repository: [Insert URL]

import Foundation

// MARK: - ROM & KERNAL Address Constants
/// Official C64 ROM/KERNAL entry points used by this compiler.
/// Verified against C64 ROM Map and KERNAL documentation.
private enum ROM {
    // Floating-point routines
    static let MOVFM   = "$BBA2"   // Load FAC from 5-byte float at (A/Y)
    static let MOVMF   = "$BBD4"   // Store FAC to 5-byte float at (X/Y)
    static let FADD    = "$B867"   // FAC = FAC + MEM(A/Y)
    static let FSUB    = "$B850"   // FAC = FAC - MEM(A/Y)
    static let FMUL    = "$BA28"   // FAC = FAC * MEM(A/Y)
    static let FDIV    = "$BB0F"   // FAC = FAC / MEM(A/Y)
    static let FPOW    = "$BF7B"   // FAC = ARG ^ FAC
    static let MOVAF   = "$BC0C"   // ARG = FAC
    static let CONUPK  = "$BA8C"   // Unpack 5-byte float at (A/Y) into ARG,
                                   // sets the FAC/ARG sign-compare byte.
                                   // Same routine FADD/FMUL call first.
    static let NEGFAC  = "$BFB4"   // FAC = -FAC
    static let INT     = "$BCCC"   // FAC = INT(FAC)
    static let ABS     = "$BC58"   // FAC = ABS(FAC)
    static let SGN     = "$BC39"   // FAC = SGN(FAC)
    static let SQR     = "$BF71"   // FAC = SQR(FAC)
    static let SIN     = "$E26B"   // FAC = SIN(FAC)
    static let COS     = "$E264"   // FAC = COS(FAC)
    static let TAN     = "$E2B4"   // FAC = TAN(FAC)
    static let ATN     = "$E30E"   // FAC = ATN(FAC)
    static let EXP     = "$BFED"   // FAC = EXP(FAC)
    static let LOG     = "$B9EA"   // FAC = LOG(FAC)
    static let RND     = "$E097"   // FAC = RND(FAC)
    static let FCOMP   = "$BC5B"   // Compare FAC with MEM(A/Y)
    static let FACINT  = "$B7F7"   // FAC → 16-bit int: A=$64(hi), Y=$65(lo)
    static let AYINT   = "$B1BF"   // FAC -> SIGNED 16-bit at $64(hi)/$65(lo),
                                   // range-checked -32768..32767. Use this
                                   // instead of FACINT/GETADR when the value
                                   // may be negative (GETADR throws ILLEGAL
                                   // QUANTITY on any negative FAC).
    static let INTFAC  = "$B391"   // 16-bit int A=hi/Y=lo → FAC (GIVAYF)
    static let FOUT    = "$BDDD"   // FAC -> null-terminated ASCII at $0100
                                   // (LDY #$01 entry; sign char lands at
                                   // $0100, digits follow, 0-terminated).
                                   // Do NOT enter at $BDE3: that is the
                                   // middle of the routine and Y would be
                                   // whatever the caller left in it.
    static let VAL     = "$B7B5"   // Parse string at $22/$23/$24 → FAC
}

private enum KERNAL {
    static let CHROUT = "$FFD2"
    static let GETIN  = "$FFE4"
    static let SETLFS = "$FFBA"
    static let SETNAM = "$FFBD"
    static let KOPEN  = "$FFC0"
    static let KCLOSE = "$FFC3"
    static let CHKOUT = "$FFC9"
    static let CHKIN  = "$FFC6"
    static let CLRCHN = "$FFCC"
    static let KLOAD  = "$FFD5"   // A=0 load/1 verify, X/Y = addr (SA=0 only)
    static let KSAVE  = "$FFD8"   // A = ZP offset of start ptr, X/Y = end+1
}

// MARK: - BasicCodeGen
/// Converts a typed, parsed BASIC V2 program into ca65 assembly.
///
/// Key difference from legacy compilers: every code-gen decision is driven by
/// the `SymbolTable` produced by `BasicTypeAnalyser`. Variables typed as `.byte`
/// get 1-byte storage and simple LDA/STA arithmetic. Variables typed as `.word`
/// get 2-byte (lo/hi) storage and 16-bit add/subtract. Only variables typed
/// `.float` use the ROM floating-point routines.
struct BasicCodeGen {

    // MARK: - State
    private var output: [String] = []
    private var labelCounter = 0
    private var lineLabels: [Int: String] = [:]
    private var table: SymbolTable = SymbolTable()
    /// Non-fatal diagnostics collected during code generation (unimplemented
    /// features, silently-degraded constructs). Surfaced via CompileResultV2
    /// so the IDE can show them instead of shipping quietly broken PRGs.
    private(set) var warnings: [String] = []
    /// True while generating a PRINT# item list; numbers get a trailing
    /// space ($20) on files but a cursor-right ($1D) on screen, exactly as
    /// the ROM does at $AB3B.
    /// FOR variables whose limit/step could not be resolved to constants
    /// in at least one loop, and therefore still need runtime storage.
    private var forLimitNeeded: Set<String> = []
    private var forStepNeeded: Set<String> = []
    /// Runtime routines emitted only when some expression needs them.
    private var needsMul16 = false
    private var needsDiv16 = false
    /// Set when a byte-table READ needs full 16-bit data-pointer
    /// addressing (table longer than 256 bytes); gates emission of
    /// _rt_data_get_byte.
    private var needsWideByteData = false

    // First-pass collection:
    private var dataBytes: [UInt8] = []
    private var dataFloats: [Double] = []
    private var dataIsAllByte: Bool = true
    private var arrayDims: [(name: String, dims: [Int])] = []
    private var dataHasString: Bool = false
    private var dataItems: [DataItem] = []
    private var userFunctions: [String: (param: String, body: Expr)] = [:]

    private enum DataItem {
        case byte(UInt8)
        case word(Int)
        case float(Double)
        case string(String)
    }

    // MARK: - Entry Point
    /// Compiles a list of parsed BASIC lines into ca65 assembly.
    mutating func compile(_ lines: [ParsedLine], symbolTable: SymbolTable) -> String {
        output = []
        labelCounter = 0
        lineLabels = [:]
        table = symbolTable
        dataBytes = []
        dataFloats = []
        dataIsAllByte = true
        dataHasString = false
        dataItems = []
        arrayDims = []
        userFunctions = [:]
        warnings = []
        forLimitNeeded = []
        forStepNeeded = []
        needsMul16 = false
        needsDiv16 = false
        needsWideByteData = false

        // Build line → label map
        for line in lines {
            lineLabels[line.number] = "line_\(line.number)"
        }

        firstPass(lines)
        emitHeader()

        for line in lines {
            emit("")
            emit("; ── Line \(line.number) ──")
            emit("\(lineLabels[line.number]!):")
            for stmt in line.stmts { genStmt(stmt) }
        }

        // Fall-through to BASIC warm start
        emit("")
        emit("_program_end:")
        emit("    lda #$37")
        emit("    sta $01")
        emit("    jmp $A474        ; BASIC warm start — READY.")

        emitRuntime()
        emitStorage(lines)

        return output.joined(separator: "\n")
    }

    // MARK: - First Pass
    private mutating func firstPass(_ lines: [ParsedLine]) {
        for line in lines {
            for stmt in line.stmts { collectStmt(stmt) }
        }
        // Second walk: register arrays used without DIM (BASIC auto-DIMs
        // them to subscripts 0-10). Must run AFTER the walk above so an
        // explicit DIM anywhere in the program wins over the default size;
        // otherwise `10 A(3)=5 : 20 DIM A(100)` would allocate 11 elements
        // and emit a duplicate arr_ label.
        for line in lines {
            for stmt in line.stmts { collectArrayRefs(stmt) }
        }
    }

    private mutating func collectStmt(_ stmt: Stmt) {
        switch stmt {
        case .dataStmt(let vals):
            for v in vals {
                switch v {
                case .integer(let n):
                    if n >= 0 && n <= 255 { dataItems.append(.byte(UInt8(n))) }
                    else if n >= -32768 && n <= 32767 { dataItems.append(.word(n)) }
                    else { dataItems.append(.float(Double(n))) }
                    appendNumericData(Double(n), fitsByte: n >= 0 && n <= 255)
                case .float(let f):
                    dataItems.append(.float(f))
                    appendNumericData(f, fitsByte: false)
                case .string(let s):
                    dataItems.append(.string(s))
                    dataHasString = true
                }
            }
        case .dimStmt(let entries):
            for entry in entries {
                let sizes = entry.dims.map { e -> Int in
                    if case .intLit(let n) = e { return n + 1 }
                    warn("DIM \(entry.name): non-constant dimension, allocating 11 elements")
                    return 11
                }
                arrayDims.append((name: entry.name, dims: sizes))
            }
        case .defFn(let name, let param, let body):
            // Register during the first pass so FNA(x) works even when the
            // DEF FN line comes later in the program (the common layout:
            // definitions at the bottom). Previously registration happened
            // in genStmt, so forward references silently emitted
            // "; unimplemented function".
            userFunctions[name] = (param: param, body: body)
        case .ifThen(_, let t, let e):
            t.forEach { collectStmt($0) }
            e?.forEach { collectStmt($0) }
        default: break
        }
    }

    /// Numeric DATA lands in one of two parallel tables: the fast all-byte
    /// table, or - once any value needs more than a byte - the float
    /// table. The demotion copies the bytes collected so far across
    /// exactly once (this block used to be pasted per DataValue arm).
    private mutating func appendNumericData(_ d: Double, fitsByte: Bool) {
        if fitsByte && dataIsAllByte {
            dataBytes.append(UInt8(d))
        } else {
            if dataIsAllByte {
                dataFloats = dataBytes.map { Double($0) }
                dataBytes = []
                dataIsAllByte = false
            }
            dataFloats.append(d)
        }
    }

    // MARK: - Implicit Arrays (second first-pass walk)

    /// Registers an array referenced without a DIM. Real BASIC auto-DIMs
    /// to 11 elements per dimension (subscripts 0-10); without this, any
    /// implicit array produced an undefined arr_ symbol at assemble time.
    private mutating func registerImplicitArray(_ name: String, dimCount: Int) {
        guard !arrayDims.contains(where: { $0.name == name }) else { return }
        arrayDims.append((name: name, dims: Array(repeating: 11, count: max(1, dimCount))))
    }

    private mutating func collectArrayRefs(_ stmt: Stmt) {
        switch stmt {
        case .letFloat(_, let e), .letStr(_, let e), .letInt(_, let e):
            collectArrayRefsExpr(e)
        case .arrayWrite(let name, let idxs, let rhs):
            registerImplicitArray(name, dimCount: idxs.count)
            idxs.forEach { collectArrayRefsExpr($0) }
            collectArrayRefsExpr(rhs)
        case .ifGoto(let c, _):
            collectArrayRefsExpr(c)
        case .ifThen(let c, let t, let e):
            collectArrayRefsExpr(c)
            t.forEach { collectArrayRefs($0) }
            e?.forEach { collectArrayRefs($0) }
        case .forStmt(_, let from, let to, let step):
            collectArrayRefsExpr(from)
            collectArrayRefsExpr(to)
            if let s = step { collectArrayRefsExpr(s) }
        case .printStmt(let items):
            items.forEach { if case .expr(let e) = $0 { collectArrayRefsExpr(e) } }
        case .printHashStmt(let n, let items):
            collectArrayRefsExpr(n)
            items.forEach { if case .expr(let e) = $0 { collectArrayRefsExpr(e) } }
        case .pokeStmt(let a, let v):
            collectArrayRefsExpr(a); collectArrayRefsExpr(v)
        case .sysStmt(let e), .closeStmt(let e), .cmdStmt(let e):
            collectArrayRefsExpr(e)
        case .waitStmt(let a, let m, let x):
            collectArrayRefsExpr(a); collectArrayRefsExpr(m)
            if let x = x { collectArrayRefsExpr(x) }
        case .onGoto(let e, _), .onGosub(let e, _):
            collectArrayRefsExpr(e)
        case .openStmt(let l, let d, let s, let n):
            collectArrayRefsExpr(l); collectArrayRefsExpr(d); collectArrayRefsExpr(s)
            if let n = n { collectArrayRefsExpr(n) }
        case .loadStmt(let n, let d, let f):
            collectArrayRefsExpr(n); collectArrayRefsExpr(d)
            if let f = f { collectArrayRefsExpr(f) }
        case .saveStmt(let n, let d):
            collectArrayRefsExpr(n); collectArrayRefsExpr(d)
        case .inputHashStmt(let n, let targets):
            collectArrayRefsExpr(n)
            targets.forEach { collectArrayRefsTarget($0) }
        case .getHashStmt(let n, let targets):
            collectArrayRefsExpr(n)
            targets.forEach { collectArrayRefsTarget($0) }
        case .getStmt(let targets):
            targets.forEach { collectArrayRefsTarget($0) }
        case .inputStmt(_, let target):
            collectArrayRefsTarget(target)
        case .readStmt(let targets):
            targets.forEach { collectArrayRefsTarget($0) }
        case .dimStmt(let entries):
            entries.forEach { $0.dims.forEach { collectArrayRefsExpr($0) } }
        case .defFn(_, _, let body):
            collectArrayRefsExpr(body)
        default:
            break
        }
    }

    /// An array element used as a READ/INPUT# target is a reference like any
    /// other: without this, `READ A(I)` on an un-DIMed array left arr_A
    /// undefined at assemble time.
    private mutating func collectArrayRefsTarget(_ target: VarTarget) {
        guard case .element(let name, let indices) = target else { return }
        registerImplicitArray(name, dimCount: indices.count)
        indices.forEach { collectArrayRefsExpr($0) }
    }

    private mutating func collectArrayRefsExpr(_ expr: Expr) {
        switch expr {
        case .arrayRead(let name, let idxs):
            registerImplicitArray(name, dimCount: idxs.count)
            idxs.forEach { collectArrayRefsExpr($0) }
        case .binaryOp(_, let l, let r), .compareOp(_, let l, let r):
            collectArrayRefsExpr(l); collectArrayRefsExpr(r)
        case .unaryMinus(let e), .notOp(let e):
            collectArrayRefsExpr(e)
        case .funcCall(_, let args):
            args.forEach { collectArrayRefsExpr($0) }
        default:
            break
        }
    }

    // MARK: - Header
    private mutating func emitHeader() {
        emit("; ════════════════════════════════════════")
        emit("; Compiled BASIC V2 — generated by C64 IDE")
        emit("; Type-aware: byte/word/float per variable")
        emit("; ════════════════════════════════════════")
        emit("")
        emit(".export __LOADADDR__: absolute = 1")
        emit("")
        emit(".segment \"LOADADDR\"")
        emit("    .word $0801")
        emit("")
        emit(".segment \"STARTUP\"")
        emit("    ; BASIC stub: 10 SYS 2061")
        emit("    .word @end")
        emit("    .word 10")
        emit("    .byte $9E")
        emit("    .byte \"2061\",0")
        emit("@end:")
        emit("    .word 0")
        emit("")
        emit(".segment \"CODE\"")
        emit("")
        emit("_start:")
    }

    // MARK: - Statement Generation
    private mutating func genStmt(_ stmt: Stmt) {
        switch stmt {
        case .gotoStmt(let n):
            emit("    jmp \(lineLabel(n))")
        case .gosubStmt(let n):
            emit("    jsr \(lineLabel(n))")
        case .returnStmt:
            emit("    rts")
        case .endStmt, .stopStmt:
            emit("    jmp _program_end")
        case .clrStmt:
            emit("    ; CLR (no-op in compiled code)")
        case .remStmt:
            break
        case .letFloat(let name, let rhs):
            genAssign(name: name, rhs: rhs)
        case .letStr(let name, let rhs):
            genStrAssign(name: name, rhs: rhs)
        case .letInt(let name, let rhs):
            // % variables hold -32768..32767; the interpreter raises
            // ILLEGAL QUANTITY beyond that, we silently wrap - at least
            // diagnose the constant case.
            if let v = constIntValue(rhs), !(-32768...32767).contains(v) {
                warn("\(name) = \(v): value outside the integer range -32768..32767 wraps on hardware")
            }
            genExprToWord(rhs)
            emit("    sta var_\(asm(name))")
            emit("    stx var_\(asm(name))+1")
        case .arrayWrite(let name, let idxs, let rhs):
            genArrayWrite(name: name, indices: idxs, rhs: rhs)
        case .pokeStmt(let addr, let val):
            genPoke(addr: addr, val: val)
        case .sysStmt(let addrExpr):
            genExprToWord(addrExpr)
            emit("    sta _sys_lo")
            emit("    stx _sys_hi")
            emit("    jsr _rt_sys")
        case .getStmt(let targets):
            // One keypress per target: GET A$,B$ consumes two.
            for target in targets { genGetTarget(target) }
        case .waitStmt(let addr, let mask, let xor):
            let lp = newLabel("wait")
            genExprToWord(addr)
            emit("    sta _peek_lo")
            emit("    stx _peek_hi")
            genExprToByte(mask)
            emit("    sta _and_tmp")
            if let xv = xor {
                genExprToByte(xv)
                emit("    sta _xor_tmp")
            } else {
                emit("    lda #0")
                emit("    sta _xor_tmp")
            }
            emit("\(lp):")
            emit("    jsr _rt_peek_byte")
            // Hardware WAIT is (PEEK EOR xor) AND mask — EOR first. The
            // old AND-first order made any xor bit outside the mask
            // permanently nonzero, so the wait returned immediately.
            emit("    eor _xor_tmp")
            emit("    and _and_tmp")
            emit("    beq \(lp)")
        case .printStmt(let items):
            genPrint(items)
        case .printHashStmt(let logNum, let items):
            genExprToByte(logNum)
            emit("    tax")
            emit("    jsr \(KERNAL.CHKOUT)")
            genPrint(items)
            emit("    jsr \(KERNAL.CLRCHN)")
        case .inputStmt(let prompt, let target):
            genInput(prompt: prompt, target: target)
        case .inputHashStmt(let logNum, let targets):
            genExprToByte(logNum)
            emit("    tax")
            emit("    jsr \(KERNAL.CHKIN)")
            for target in targets { genInputTarget(target) }
            emit("    jsr \(KERNAL.CLRCHN)")
        case .forStmt(let v, let from, let to, let step):
            genFor(varName: v, from: from, to: to, step: step)
        case .nextStmt(let v):
            genNext(varName: v)
        case .ifGoto(let cond, let target):
            genIfGoto(cond: cond, target: target)
        case .ifThen(let cond, let thenStmts, let elseStmts):
            genIfThen(cond: cond, then: thenStmts, else_: elseStmts)
        case .dataStmt:
            emit("    ; DATA (values in _data_table)")
        case .readStmt(let names):
            genRead(names)
        case .restoreStmt:
            emit("    lda #0")
            emit("    sta _data_ptr")
            emit("    sta _data_ptr+1")
        case .dimStmt:
            emit("    ; DIM (storage allocated at link time)")
        case .onGoto(let expr, let targets):
            genOnGotoGosub(expr: expr, targets: targets, isGosub: false)
        case .onGosub(let expr, let targets):
            genOnGotoGosub(expr: expr, targets: targets, isGosub: true)
        case .openStmt(let l, let d, let s, let n):
            genOpen(logNum: l, device: d, secondary: s, filename: n)
        case .closeStmt(let n):
            genExprToByte(n)
            emit("    jsr \(KERNAL.KCLOSE)")
        case .cmdStmt(let n):
            genExprToByte(n)
            emit("    tax")
            emit("    jsr \(KERNAL.CHKOUT)")
        case .loadStmt(let name, let dev, let flag):
            // Real KERNAL LOAD. The old code set up SETNAM with scrambled
            // registers (SETNAM wants A=length, X=ptr lo, Y=ptr hi) and
            // then only OPENed logical file 1 - nothing was ever loaded.
            emitSetNam(name)
            // Secondary address from the third LOAD parameter. Default is
            // 1 (load at the file's own address), NOT BASIC's 0: SA=0
            // relocates the file to $0801, which is where the running
            // compiled program lives. LOAD-chaining cannot work here;
            // LOAD"DATA",8,1 for sprite/char data is the supported use.
            if let f = flag { genExprToByte(f) } else { emit("    lda #1") }
            emit("    sta _open_sec")
            genExprToByte(dev)
            emit("    tax")                 // X = device
            emit("    lda #1")              // A = logical file number
            emit("    ldy _open_sec")       // Y = secondary address
            emit("    jsr \(KERNAL.SETLFS)")
            emit("    lda #0")              // 0 = LOAD (1 = VERIFY)
            emit("    ldx #$01")            // fallback address $0801,
            emit("    ldy #$08")            // used by KERNAL only if SA=0
            emit("    jsr \(KERNAL.KLOAD)")
            let loadOk = newLabel("ldok")
            emit("    bcc \(loadOk)")       // carry set = KERNAL error
            emit("    jmp _program_end")
            emit("\(loadOk):")
        case .getHashStmt(let logNum, let targets):
            genExprToByte(logNum)
            emit("    tax")
            emit("    jsr \(KERNAL.CHKIN)")
            // Channel stays open across every target — one byte each — and
            // CLRCHN comes after the last store, so nothing needs saving
            // around it (the stores are pure memory/FAC work).
            for target in targets { genGetTarget(target) }
            emit("    jsr \(KERNAL.CLRCHN)")
        case .saveStmt(let name, let dev):
            // Real KERNAL SAVE. BASIC's SAVE writes the program; the
            // compiled equivalent is the whole image from $0801 through
            // _image_end (code, runtime, data, and current variable
            // state), which re-loads as a runnable PRG.
            emitSetNam(name)
            genExprToByte(dev)
            emit("    tax")
            emit("    lda #1")
            emit("    ldy #1")
            emit("    jsr \(KERNAL.SETLFS)")
            // SETNAM stored the name POINTER into $BB/$BC, so $FB/$FC are
            // free to reuse as the KERNAL SAVE start-address pointer.
            emit("    lda #$01")
            emit("    sta $FB")
            emit("    lda #$08")
            emit("    sta $FC")
            emit("    lda #$FB")            // A = ZP offset of start ptr
            emit("    ldx #<_image_end")    // X/Y = end address + 1
            emit("    ldy #>_image_end")
            emit("    jsr \(KERNAL.KSAVE)")
            let saveOk = newLabel("svok")
            emit("    bcc \(saveOk)")       // carry set = KERNAL error
            emit("    jmp _program_end")
            emit("\(saveOk):")
        case .defFn(let name, let param, _):
            // Registered in firstPass (collectStmt); nothing to execute here.
            emit("    ; DEF FN \(name)(\(param))")
        }
    }

    // MARK: - POKE
    private mutating func genPoke(addr: Expr, val: Expr) {
        genExprToByte(val)
        emit("    sta _poke_val")

        // No banking needed anywhere: 6510 writes always go through to RAM
        // regardless of $01, and the I/O block at $D000 is visible under
        // the default $37 configuration. The old $35 bank-switch for
        // addresses >= $A000 was pure overhead, silently reverted POKE 1,x
        // by restoring #$37 afterwards, and opened an NMI-with-KERNAL-
        // banked-out crash window (RESTORE key at the wrong microsecond).
        if let constAddr = constWordValue(addr) {
            emit("    lda _poke_val")
            emit("    sta \(hex(constAddr))")
            return
        }

        genExprToWord(addr)
        emit("    sta _poke_lo")
        emit("    stx _poke_hi")
        emit("    jsr _rt_poke")
    }

    // MARK: - Assignment
    private mutating func genAssign(name: String, rhs: Expr) {
        let varType = table[name]
        switch varType.width {
        case .byte:
            genExprToByte(rhs)
            emit("    sta var_\(asm(name))")
        case .word:
            genExprToWord(rhs)
            emit("    sta var_\(asm(name))")
            emit("    stx var_\(asm(name))+1")
        case .float, .none:
            genExprToFloat(rhs)
            genStoreFloat(name)
        }
    }

    private mutating func genStrAssign(name: String, rhs: Expr) {
        genStrPtr(rhs)
        let lbl = newLabel("scp")
        emit("    ldy #0")
        emit("\(lbl):")
        emit("    lda ($FB),y")
        emit("    sta var_\(asm(name)),y")
        emit("    beq \(lbl)_done")
        emit("    iny")
        emit("    bne \(lbl)")
        emit("\(lbl)_done:")
    }

    // MARK: - FOR / NEXT
    /// One active FOR loop during code generation. constStep/constLimit
    /// are set when the values are compile-time constants usable by the
    /// specialized NEXT paths; when constStep is nil the loop entry stores
    /// both values and NEXT takes the generic runtime path.
    private struct ForEntry {
        let name: String
        let bodyLabel: String
        let doneLabel: String
        let constStep: Int?
        let constLimit: Int?
    }
    private var forStack: [ForEntry] = []

    private mutating func genFor(varName: String, from: Expr, to: Expr, step: Expr?) {
        let varType = table[varName]
        let bodyLabel = "for_\(asm(varName))_\(labelCounter)"
        let doneLabel = "fordn_\(asm(varName))_\(labelCounter)"
        labelCounter += 1

        let stepExpr = step ?? .intLit(1)
        // Compile-time step/limit unlock the specialized NEXT paths and
        // let the loop entry skip storing them (literals have no side
        // effects, so skipping their evaluation is safe).
        var cStep = constIntValue(stepExpr)
        var cLimit = constIntValue(to)
        switch varType.width {
        case .byte:
            // Unsigned byte loops only: the analyser types any loop with
            // a negative step as signed, so a byte-width unsigned loop
            // always counts up. Signed byte loops keep the generic path.
            if varType.isSigned { cStep = nil }
            if let k = cStep, !(1...255).contains(k) { cStep = nil }
            if let l = cLimit, !(0...255).contains(l) { cLimit = nil }
        case .word:
            // The specialized word path compares unsigned; signed word
            // loops (e.g. FOR I=-300 TO 300) take the generic path, which
            // biases the limit compare.
            if varType.isSigned { cStep = nil }
            if let k = cStep, k == 0 || k < -32768 || k > 65535 { cStep = nil }
            if let l = cLimit, !(0...65535).contains(l) { cLimit = nil }
        default:
            cStep = nil
            cLimit = nil
        }
        // The specialized NEXT paths key on constStep; a const limit with
        // a runtime step would leave the generic path reading a
        // _for_limit that was never stored.
        if cStep == nil { cLimit = nil }

        forStack.append(ForEntry(name: varName, bodyLabel: bodyLabel,
                                 doneLabel: doneLabel,
                                 constStep: cStep, constLimit: cLimit))

        switch varType.width {
        case .byte:
            genExprToByte(from)
            emit("    sta var_\(asm(varName))")
            if cLimit == nil {
                genExprToByte(to)
                // Signed loops store the limit sign-biased so NEXT's
                // unsigned carry tree computes the signed ordering.
                if varType.isSigned { emit("    eor #$80") }
                emit("    sta _for_limit_\(asm(varName))")
                forLimitNeeded.insert(varName)
            }
            if cStep == nil {
                genExprToByte(stepExpr)
                emit("    sta _for_step_\(asm(varName))")
                forStepNeeded.insert(varName)
            }
        case .word:
            genExprToWord(from)
            emit("    sta var_\(asm(varName))")
            emit("    stx var_\(asm(varName))+1")
            if cLimit == nil {
                genExprToWord(to)
                emit("    sta _for_limit_\(asm(varName))")
                if varType.isSigned {
                    // Bias the high byte only; see the byte case above.
                    emit("    txa")
                    emit("    eor #$80")
                    emit("    sta _for_limit_\(asm(varName))+1")
                } else {
                    emit("    stx _for_limit_\(asm(varName))+1")
                }
                forLimitNeeded.insert(varName)
            }
            if cStep == nil {
                genExprToWord(stepExpr)
                emit("    sta _for_step_\(asm(varName))")
                emit("    stx _for_step_\(asm(varName))+1")
                forStepNeeded.insert(varName)
            }
        default:
            genExprToFloat(from); genStoreFloatNamed("_for_start_\(asm(varName))")
            genExprToFloat(to);   genStoreFloatNamed("_for_limit_\(asm(varName))")
            genExprToFloat(stepExpr); genStoreFloatNamed("_for_step_\(asm(varName))")
            genLoadFloatNamed("_for_start_\(asm(varName))")
            genStoreFloat(varName)
        }
        emit("\(bodyLabel):")
    }

    private mutating func genNext(varName: String?) {
        let entry: ForEntry
        if let name = varName,
           let idx = forStack.lastIndex(where: { $0.name == name }) {
            entry = forStack.remove(at: idx)
        } else if let last = forStack.popLast() {
            entry = last
        } else {
            warn("NEXT without a matching FOR (ignored)")
            return
        }

        let varType = table[entry.name]
        switch varType.width {
        case .byte: genNextByte(entry)
        case .word: genNextWord(entry)
        default:    genNextFloat(entry)
        }
        emit("\(entry.doneLabel):")
    }

    private mutating func genNextByte(_ e: ForEntry) {
        let n = asm(e.name)
        let signed = table[e.name].isSigned

        // -- Specialized path: unsigned byte loop, compile-time constant
        //    positive step. NOT an exact-hit equality test: FOR I=5 TO 3
        //    legally runs its body once and overshoots past limit+step,
        //    so the compare must be a magnitude test. --
        if !signed, let k = e.constStep {
            if k == 1 {
                emit("    inc var_\(n)")
                // Counting up, var can only become 0 by wrapping 255 -> 0,
                // and inc sets Z.
                emit("    beq \(e.doneLabel)")
                if e.constLimit == 255 {
                    emit("    jmp \(e.bodyLabel)")  // only the wrap ends it
                    return
                }
                emit("    lda var_\(n)")
            } else {
                emit("    lda var_\(n)")
                emit("    clc")
                emit("    adc #\(k)")
                emit("    sta var_\(n)")
                emit("    bcs \(e.doneLabel)")      // wrapped past 255
                if e.constLimit == 255 {
                    emit("    jmp \(e.bodyLabel)")
                    return
                }
            }
            if let lim = e.constLimit {
                // Continue while var <= lim, i.e. var < lim+1.
                emit("    cmp #\(lim + 1)")
                emit("    bcs \(e.doneLabel)")
                emit("    jmp \(e.bodyLabel)")
            } else {
                let go = newLabel("nbg")
                emit("    cmp _for_limit_\(n)")
                emit("    beq \(go)")               // == limit: continue
                emit("    bcs \(e.doneLabel)")      // >  limit: done
                emit("\(go):")
                emit("    jmp \(e.bodyLabel)")
            }
            return
        }

        if !signed {
            emit("    lda var_\(n)")
            emit("    clc")
            emit("    adc _for_step_\(n)")
            emit("    sta var_\(n)")
            // Carry set = the add wrapped past 255, i.e. we passed the top
            // of the unsigned range. Without this, FOR I=0 TO 255 loops
            // forever (255+1 wraps to 0, which is < 255). sta preserves C.
            emit("    bcs \(e.doneLabel)")
            emit("    cmp _for_limit_\(n)")
            let bSkip = newLabel("nbs")
            emit("    beq \(bSkip)")
            emit("    bcs \(e.doneLabel)")
            emit("\(bSkip):")
            emit("    jmp \(e.bodyLabel)")
        } else {
            // Signed loop: the limit was stored sign-biased at FOR time,
            // so biasing the counter before each cmp gives the signed
            // ordering with the same carry tree. bvs catches the counter
            // wrapping past +127/-128, which the carry can't see in
            // two's complement.
            emit("    lda _for_step_\(n)")
            emit("    bmi \(e.bodyLabel)_neg")
            emit("    lda var_\(n)")
            emit("    clc")
            emit("    adc _for_step_\(n)")
            emit("    sta var_\(n)")
            emit("    bvs \(e.doneLabel)")
            emit("    eor #$80")
            emit("    cmp _for_limit_\(n)")
            let posSkip = newLabel("nbps")
            emit("    beq \(posSkip)")
            emit("    bcs \(e.doneLabel)")
            emit("\(posSkip):")
            emit("    jmp \(e.bodyLabel)")
            emit("\(e.bodyLabel)_neg:")
            emit("    lda var_\(n)")
            emit("    clc")
            emit("    adc _for_step_\(n)")
            emit("    sta var_\(n)")
            emit("    bvs \(e.doneLabel)")
            emit("    eor #$80")
            emit("    cmp _for_limit_\(n)")
            let negSkip = newLabel("nbns")
            emit("    bcc \(negSkip)")
            emit("    jmp \(e.bodyLabel)")
            emit("\(negSkip):")
        }
    }

    private mutating func genNextWord(_ e: ForEntry) {
        let n = asm(e.name)

        // -- Specialized path: compile-time constant step. The sign test
        //    disappears (sign is known), the add uses immediates or a
        //    16-bit inc, and a constant limit compares against immediates.
        //    Magnitude compares throughout: exact-hit equality breaks on
        //    degenerate loops like FOR I=5 TO 3 (body runs once,
        //    overshoot skips the equality). --
        if let k = e.constStep {
            if k == 1 {
                let c = newLabel("nwi")
                emit("    inc var_\(n)")
                emit("    bne \(c)")
                emit("    inc var_\(n)+1")
                emit("    beq \(e.doneLabel)")      // wrapped past $FFFF
                emit("\(c):")
            } else {
                let kk = k & 0xFFFF
                emit("    lda var_\(n)")
                emit("    clc")
                emit("    adc #<\(kk)")
                emit("    sta var_\(n)")
                emit("    lda var_\(n)+1")
                emit("    adc #>\(kk)")
                emit("    sta var_\(n)+1")
                if k > 0 {
                    emit("    bcs \(e.doneLabel)")  // wrapped past $FFFF
                } else {
                    emit("    bcc \(e.doneLabel)")  // borrowed below 0
                }
            }
            let limLo: String
            let limHi: String
            if let lim = e.constLimit {
                if k > 0 && lim == 65535 || k < 0 && lim == 0 {
                    // Only the wrap/borrow check above can end this loop.
                    emit("    jmp \(e.bodyLabel)")
                    return
                }
                limLo = "#<\(lim)"
                limHi = "#>\(lim)"
            } else {
                limLo = "_for_limit_\(n)"
                limHi = "_for_limit_\(n)+1"
            }
            let go = newLabel("nwg")
            if k > 0 {
                // Continue while var <= limit.
                emit("    lda var_\(n)+1")
                emit("    cmp \(limHi)")
                emit("    bcc \(go)")               // hi <  : continue
                emit("    bne \(e.doneLabel)")      // hi >  : done
                emit("    lda var_\(n)")
                emit("    cmp \(limLo)")
                emit("    beq \(go)")               // ==    : continue
                emit("    bcs \(e.doneLabel)")      // lo >  : done
            } else {
                // Continue while var >= limit.
                emit("    lda var_\(n)+1")
                emit("    cmp \(limHi)")
                emit("    bcc \(e.doneLabel)")      // hi <  : done
                emit("    bne \(go)")               // hi >  : continue
                emit("    lda var_\(n)")
                emit("    cmp \(limLo)")
                emit("    bcc \(e.doneLabel)")      // lo <  : done
            }
            emit("\(go):")
            emit("    jmp \(e.bodyLabel)")
            return
        }

        let negPath = newLabel("nwneg")
        let signed = table[e.name].isSigned

        // Runtime sign test on the step's high byte: STEP can be any
        // expression, so the direction isn't knowable at compile time.
        emit("    lda _for_step_\(n)+1")
        emit("    bmi \(negPath)")

        // -- Positive step: 16-bit add, exit on wrap, continue while
        //    var <= limit. Unsigned wrap is the carry past $FFFF; signed
        //    wrap is overflow past +32767 (V flag), and the carry from
        //    e.g. -1 -> 0 is normal. Signed compares run with both high
        //    bytes sign-biased (limit stored biased at FOR time). --
        emit("    lda var_\(n)")
        emit("    clc")
        emit("    adc _for_step_\(n)")
        emit("    sta var_\(n)")
        emit("    lda var_\(n)+1")
        emit("    adc _for_step_\(n)+1")
        emit("    sta var_\(n)+1")
        if signed {
            emit("    bvs \(e.doneLabel)")  // wrapped past +32767: done
            emit("    eor #$80")
        } else {
            emit("    bcs \(e.doneLabel)")  // wrapped past 65535: done
        }
        emit("    cmp _for_limit_\(n)+1")   // A still holds var hi
        let hiLess = newLabel("nwhl")
        emit("    bcc \(hiLess)")           // var hi < limit hi: continue
        emit("    bne \(e.doneLabel)")      // var hi > limit hi: done
        emit("    lda var_\(n)")
        emit("    cmp _for_limit_\(n)")
        emit("    beq \(hiLess)")           // var == limit: continue
        emit("    bcs \(e.doneLabel)")      // var lo > limit lo: done
        emit("\(hiLess):")
        emit("    jmp \(e.bodyLabel)")

        // -- Negative step (two's complement add): unsigned loops end on
        //    the borrow below 0 (carry clear); signed loops end on
        //    overflow past -32768 (V flag) since e.g. 0 -> -1 clears the
        //    carry on a perfectly legal iteration. Otherwise continue
        //    while var >= limit. --
        emit("\(negPath):")
        emit("    lda var_\(n)")
        emit("    clc")
        emit("    adc _for_step_\(n)")
        emit("    sta var_\(n)")
        emit("    lda var_\(n)+1")
        emit("    adc _for_step_\(n)+1")
        emit("    sta var_\(n)+1")
        if signed {
            emit("    bvs \(e.doneLabel)")  // wrapped past -32768: done
            emit("    eor #$80")
        } else {
            emit("    bcc \(e.doneLabel)")  // underflowed below 0: done
        }
        emit("    cmp _for_limit_\(n)+1")   // A still holds var hi
        let negLoop = newLabel("nwnl")
        emit("    bcc \(e.doneLabel)")      // var hi < limit hi: done
        emit("    bne \(negLoop)")          // var hi > limit hi: continue
        emit("    lda var_\(n)")
        emit("    cmp _for_limit_\(n)")
        emit("    bcc \(e.doneLabel)")      // var < limit: done
        emit("\(negLoop):")
        emit("    jmp \(e.bodyLabel)")
    }

    private mutating func genNextFloat(_ e: ForEntry) {
        let n = asm(e.name)
        genLoadFloat(e.name)
        emit("    lda #<_for_step_\(n)")
        emit("    ldy #>_for_step_\(n)")
        emit("    jsr \(ROM.FADD)")
        genStoreFloat(e.name)
        emit("    lda #<_for_step_\(n)")
        emit("    ldy #>_for_step_\(n)")
        emit("    jsr \(ROM.MOVFM)")
        emit("    lda $66")
        emit("    bmi \(e.bodyLabel)_neg")
        genLoadFloat(e.name)
        emit("    lda #<_for_limit_\(n)")
        emit("    ldy #>_for_limit_\(n)")
        emit("    jsr \(ROM.FCOMP)")
        let posSkip = newLabel("fnfps")
        emit("    bpl \(posSkip)")
        emit("    jmp \(e.bodyLabel)")
        emit("\(posSkip):")
        let posSkip2 = newLabel("fnfps2")
        emit("    bne \(posSkip2)")
        emit("    jmp \(e.bodyLabel)")
        emit("\(posSkip2):")
        emit("    jmp \(e.doneLabel)")
        emit("\(e.bodyLabel)_neg:")
        genLoadFloat(e.name)
        emit("    lda #<_for_limit_\(n)")
        emit("    ldy #>_for_limit_\(n)")
        emit("    jsr \(ROM.FCOMP)")
        let negSkip = newLabel("fnfns")
        emit("    bne \(negSkip)")
        emit("    jmp \(e.bodyLabel)")       // var == limit: continue
        emit("\(negSkip):")
        let negSkip2 = newLabel("fnfns2")
        // FCOMP: A=$FF when FAC(var) < mem(limit). Counting down, that is
        // the loop-exit condition; var > limit (A=1) continues.
        emit("    bmi \(negSkip2)")
        emit("    jmp \(e.bodyLabel)")       // var > limit: continue
        emit("\(negSkip2):")
    }

    // MARK: - IF / THEN
    private mutating func genIfGoto(cond: Expr, target: Int) {
        let skip = newLabel("ifsk")
        genConditionBranch(cond, branchIfFalse: skip)
        emit("    jmp \(lineLabel(target))")
        emit("\(skip):")
    }

    private mutating func genIfThen(cond: Expr, then: [Stmt], else_: [Stmt]?) {
        let skip = newLabel("ifsk")
        let end  = else_ != nil ? newLabel("ifend") : skip
        genConditionBranch(cond, branchIfFalse: skip)
        then.forEach { genStmt($0) }
        if else_ != nil { emit("    jmp \(end)") }
        emit("\(skip):")
        else_?.forEach { genStmt($0) }
        if else_ != nil { emit("\(end):") }
    }

    private mutating func genConditionBranch(_ cond: Expr, branchIfFalse label: String) {
        switch cond {
        case .floatVar(let name) where table[name].width == .byte:
            emit("    lda var_\(asm(name))")
            emit("    beq \(label)")
        case .floatVar(let name) where table[name].width == .word:
            emit("    lda var_\(asm(name))")
            emit("    ora var_\(asm(name))+1")
            emit("    beq \(label)")
        case .binaryOp("AND", let left, let right) where isBooleanExpr(left) && isBooleanExpr(right):
            genConditionBranch(left, branchIfFalse: label)
            genConditionBranch(right, branchIfFalse: label)
        case .binaryOp("OR", let left, let right) where isBooleanExpr(left) && isBooleanExpr(right):
            let orTrue = newLabel("ort")
            genConditionTrueBranch(left, branchIfTrue: orTrue)
            genConditionBranch(right, branchIfFalse: label)
            emit("\(orTrue):")
        case .binaryOp("AND", _, _), .binaryOp("OR", _, _):
            // BASIC AND/OR are BITWISE on 16-bit ints, not logical. When
            // either operand isn't a comparison (e.g. the ubiquitous
            // IF PEEK(56320) AND 16 joystick test), short-circuiting gives
            // the wrong answer: PEEK=2 AND 16 is 0 (false), but "both
            // nonzero" would say true. Evaluate the value, test nonzero.
            genWordTest(cond, branchIfFalse: label)
        case .notOp(let inner) where isBooleanExpr(inner):
            // NOT of a truth value: branch to the false label when the
            // inner condition is TRUE.
            genConditionTrueBranch(inner, branchIfTrue: label)
        case .notOp:
            // NOT of arbitrary bits: NOT x = -x-1, which is zero only for
            // x = -1. Must be computed bitwise, then tested.
            genWordTest(cond, branchIfFalse: label)
        case .compareOp(let op, let l, let r) where exprWidth(l) == .byte && exprWidth(r) == .byte:
            genByteComparison(op: op, left: l, right: r, falseLabel: label)
        case .compareOp(let op, let l, let r) where exprWidth(l) == .word || exprWidth(r) == .word:
            genWordComparison(op: op, left: l, right: r, falseLabel: label)
        case .compareOp(let op, let l, let r) where exprIsString(l) || exprIsString(r):
            genStringComparison(op: op, left: l, right: r, falseLabel: label)
        default:
            genExprToFloat(cond)
            emit("    lda $61")
            emit("    beq \(label)")
        }
    }

    private mutating func genConditionTrueBranch(_ cond: Expr, branchIfTrue label: String) {
        let tmp = newLabel("nott")
        genConditionBranch(cond, branchIfFalse: tmp)
        emit("    jmp \(label)")
        emit("\(tmp):")
    }

    /// True when the expression is guaranteed to produce a BASIC truth
    /// value (0 or -1) rather than arbitrary bits: comparisons, NOT of a
    /// truth value, and AND/OR of truth values. Only these may be compiled
    /// with short-circuit logic in conditions; anything else must go the
    /// bitwise route because AND/OR/NOT in BASIC V2 are 16-bit bitwise ops.
    private func isBooleanExpr(_ e: Expr) -> Bool {
        switch e {
        case .compareOp:
            return true
        case .notOp(let inner):
            return isBooleanExpr(inner)
        case .binaryOp("AND", let l, let r), .binaryOp("OR", let l, let r):
            return isBooleanExpr(l) && isBooleanExpr(r)
        default:
            return false
        }
    }

    /// Evaluates `e` as a 16-bit value and branches to `label` if it is zero.
    private mutating func genWordTest(_ e: Expr, branchIfFalse label: String) {
        genExprToWord(e)
        emit("    sta _cmp_tmp")
        emit("    txa")
        emit("    ora _cmp_tmp")
        emit("    beq \(label)")
    }

    /// True when the analysed types allow the expression to hold a negative
    /// value (two's complement in storage). Comparisons must then use
    /// sign-biased sequences: with both operands EOR #$80 (high byte only
    /// for words), the ordinary unsigned carry tree computes the signed
    /// ordering. Mirrors the analyser's canBeNegative rule so the compare
    /// interpretation matches how the value was stored.
    private func exprIsSigned(_ expr: Expr) -> Bool {
        switch expr {
        case .intLit(let n):       return n < 0
        case .floatLit(let f):     return f < 0
        case .floatVar(let name), .intVar(let name):
            return table[name].isSigned
        case .arrayRead(let name, _):
            return table[name].isSigned
        case .unaryMinus:          return true
        case .binaryOp("-", _, _): return true
        case .binaryOp(_, let l, let r):
            return exprIsSigned(l) || exprIsSigned(r)
        case .funcCall(let name, _):
            return name.hasPrefix("FN")   // user function bodies are opaque here
        default:
            return false
        }
    }

    private mutating func genByteComparison(op: String, left: Expr, right: Expr, falseLabel: String) {
        let signed = exprIsSigned(left) || exprIsSigned(right)
        genExprToByte(left)
        if let k = constByteValue(right), !signed {
            emit("    cmp #\(k)")
            switch op {
            case "=":  emit("    bne \(falseLabel)")
            case "<>": emit("    beq \(falseLabel)")
            case "<":  emit("    bcs \(falseLabel)")
            case ">=": emit("    bcc \(falseLabel)")
            case ">":
                let ok = newLabel("cgt")
                emit("    beq \(falseLabel)")
                emit("    bcs \(ok)")
                emit("    jmp \(falseLabel)")
                emit("\(ok):")
            case "<=":
                let notOk = newLabel("nle")
                emit("    beq \(notOk)")
                emit("    bcs \(falseLabel)")
                emit("\(notOk):")
            default: break
            }
        } else {
            // Sign-biasing both operands turns the unsigned carry tree
            // below into a signed compare; equality is unaffected.
            if signed { emit("    eor #$80") }
            emit("    sta _cmp_tmp")
            genExprToByte(right)
            if signed { emit("    eor #$80") }
            emit("    cmp _cmp_tmp")
            switch op {
            case "=":  emit("    bne \(falseLabel)")
            case "<>": emit("    beq \(falseLabel)")
            case "<":  emit("    bcc \(falseLabel)"); emit("    beq \(falseLabel)")
            case ">=":
                let ok = newLabel("cge")
                emit("    beq \(ok)")
                emit("    bcs \(falseLabel)")
                emit("\(ok):")
            case ">":  emit("    bcs \(falseLabel)")
            case "<=": emit("    bcc \(falseLabel)")
            default: break
            }
        }
    }

    private mutating func genWordComparison(op: String, left: Expr, right: Expr, falseLabel: String) {
        let signed = exprIsSigned(left) || exprIsSigned(right)
        genExprToWord(right)
        emit("    sta _cmp_lo")
        if signed {
            // Bias the high bytes only: the low-byte compare of a biased
            // word compare stays raw.
            emit("    txa")
            emit("    eor #$80")
            emit("    sta _cmp_hi")
        } else {
            emit("    stx _cmp_hi")
        }
        genExprToWord(left)
        if signed {
            emit("    pha")
            emit("    txa")
            emit("    eor #$80")
            emit("    tax")
            emit("    pla")
        }
        emit("    cpx _cmp_hi")
        switch op {
        case "=":
            emit("    bne \(falseLabel)")
            emit("    cmp _cmp_lo")
            emit("    bne \(falseLabel)")
        case "<>":
            let neOk = newLabel("wne")
            emit("    bne \(neOk)")
            emit("    cmp _cmp_lo")
            emit("    beq \(falseLabel)")
            emit("\(neOk):")
        case "<":
            let ltOk = newLabel("wlt")
            emit("    bcc \(ltOk)")
            emit("    bne \(falseLabel)")
            emit("    cmp _cmp_lo")
            emit("    bcc \(ltOk)")
            emit("    jmp \(falseLabel)")
            emit("\(ltOk):")
        case ">":
            let gtOk = newLabel("wgt")
            let gtEqHi = newLabel("wgeh")
            emit("    bcc \(falseLabel)")
            emit("    beq \(gtEqHi)")
            emit("    jmp \(gtOk)")
            emit("\(gtEqHi):")
            emit("    cmp _cmp_lo")
            emit("    beq \(falseLabel)")
            emit("    bcs \(gtOk)")
            emit("    jmp \(falseLabel)")
            emit("\(gtOk):")
        case "<=":
            let leOk = newLabel("wle")
            emit("    bcc \(leOk)")
            emit("    bne \(falseLabel)")
            emit("    cmp _cmp_lo")
            emit("    beq \(leOk)")
            emit("    bcc \(leOk)")
            emit("    jmp \(falseLabel)")
            emit("\(leOk):")
        case ">=":
            let geOk = newLabel("wge")
            emit("    bcc \(falseLabel)")
            emit("    bne \(geOk)")
            emit("    cmp _cmp_lo")
            emit("    bcc \(falseLabel)")
            emit("\(geOk):")
        default:
            genExprToFloat(left)
            let tmp = newLabel("wcmp")
            emitFloatConst(tmp, 0)
            genStoreFloatNamed(tmp)
            genExprToFloat(right)
            emit("    lda #<\(tmp)")
            emit("    ldy #>\(tmp)")
            emit("    jsr \(ROM.FCOMP)")
            emitFloatBranchForOp(op, falseLabel: falseLabel)
        }
    }

    private mutating func emitFloatBranchForOp(_ op: String, falseLabel: String) {
        switch op {
        case "=":    emit("    bne \(falseLabel)")
        case "<>":   emit("    beq \(falseLabel)")
        case "<":
            emit("    beq \(falseLabel)")
            emit("    cmp #1")
            emit("    beq \(falseLabel)")
        case ">=":   emit("    bmi \(falseLabel)")
        case ">":
            emit("    beq \(falseLabel)")
            emit("    bmi \(falseLabel)")
        case "<=":
            emit("    cmp #1")
            emit("    beq \(falseLabel)")
        default: break
        }
    }

    private mutating func genStringComparison(op: String, left: Expr, right: Expr, falseLabel: String) {
        // The left side may live in a shared buffer (_chr_buf,
        // _str_slice_buf, _str_cat_buf) that evaluating the right side
        // overwrites - and genStrSlice rewrites _str_src itself. Copy the
        // left string into the compare-private buffer before touching the
        // right side; the helper leaves _str_src pointing at the copy.
        genStrPtr(left)
        emit("    jsr _rt_strcmp_lhs")
        genStrPtr(right)
        emit("    jsr _rt_strcmp")
        switch op {
        case "=":  emit("    bne \(falseLabel)")
        case "<>": emit("    beq \(falseLabel)")
        case "<":  emit("    bpl \(falseLabel)"); emit("    beq \(falseLabel)")
        case ">":  emit("    bmi \(falseLabel)"); emit("    beq \(falseLabel)")
        case "<=":
            // Equal strings return 0, which is "plus" — a bare bpl
            // treated A$<=A$ as false.
            let ok = newLabel("sle")
            emit("    beq \(ok)")
            emit("    bpl \(falseLabel)")
            emit("\(ok):")
        case ">=": emit("    bmi \(falseLabel)")
        default: break
        }
    }

    // MARK: - PRINT
    private mutating func genPrint(_ items: [PrintItem]) {
        var i = 0
        while i < items.count {
            switch items[i] {
            case .noNewline: i += 1; continue
            case .tab:       emit("    jsr _rt_tab_to_next_col")
            case .expr(let e): genPrintExpr(e)
            }
            i += 1
        }
        let suppressNewline = items.last == .noNewline || items.last == .tab
        if !suppressNewline {
            emit("    lda #$0D")
            emit("    jsr \(KERNAL.CHROUT)")
        }
    }

    private mutating func genPrintExpr(_ expr: Expr) {
        switch expr {
        case .strLit(let s):
            let lbl = newLabel("pstr")
            emit("    lda #<\(lbl)")
            emit("    ldy #>\(lbl)")
            emit("    jsr _print_str")
            emitStringData(lbl, s)
        case .strVar(let name):
            emit("    lda #<var_\(asm(name))")
            emit("    ldy #>var_\(asm(name))")
            emit("    jsr _print_str")
        case .arrayRead(let name, _) where name.hasSuffix("$"):
            genStrPtr(expr)
            emit("    lda $FB")
            emit("    ldy $FC")
            emit("    jsr _print_str")
        case .binaryOp("+", let l, let r) where exprIsString(l) || exprIsString(r):
            genStrPtr(expr)
            emit("    lda $FB")
            emit("    ldy $FC")
            emit("    jsr _print_str")
        case .funcCall("CHR$", let args) where !args.isEmpty:
            genExprToByte(args[0])
            emit("    jsr \(KERNAL.CHROUT)")
        case .funcCall("TAB(", let args) where !args.isEmpty:
            genExprToByte(args[0])
            emit("    jsr _rt_tab")
        case .funcCall("SPC(", let args) where !args.isEmpty:
            genExprToByte(args[0])
            emit("    jsr _rt_spc")
        case .funcCall(let fn, let args) where ["LEFT$","RIGHT$","MID$"].contains(fn) && !args.isEmpty:
            genStrSlice(fn, args: args)
            // _rt_str_slice returns A=0/Y=count, not the buffer address.
            emit("    lda #<_str_slice_buf")
            emit("    ldy #>_str_slice_buf")
            emit("    jsr _print_str")
        case .funcCall("STR$", let args) where !args.isEmpty:
            genExprToFloat(args[0])
            emit("    jsr _rt_str_from_fac")
            emit("    jsr _print_str")
        default:
            genExprToFloat(expr)
            emit("    jsr \(ROM.FOUT)")
            emit("    lda #<$0100")
            emit("    ldy #>$0100")
            emit("    jsr _print_str")
            // The interpreter appends a character after every number
            // (ROM $AB3B): cursor-right ($1D) on the screen, space ($20)
            // when output is redirected. The choice must be made at RUN
            // time from the active output device — CMD redirects plain
            // PRINT without any compile-time marker.
            emit("    jsr _rt_num_sep")
        }
    }

    // MARK: - INPUT
    private mutating func genInput(prompt: String?, target: VarTarget) {
        if let p = prompt {
            let lbl = newLabel("ipr")
            emit("    lda #<\(lbl)")
            emit("    ldy #>\(lbl)")
            emit("    jsr _print_str")
            emitStringData(lbl, p)
        }
        // The interpreter always prints "? " for INPUT, prompt or not.
        emit("    lda #$3F")
        emit("    jsr \(KERNAL.CHROUT)")
        emit("    lda #$20")
        emit("    jsr \(KERNAL.CHROUT)")
        genInputTarget(target)
    }

    /// GET / GET# into one target: one character from GETIN, with the
    /// channel (for GET#) already selected by the caller.
    private mutating func genGetTarget(_ target: VarTarget) {
        if case .element(let name, let indices) = target {
            genGetElement(name: name, indices: indices)
            return
        }
        let name = target.name
        emit("    jsr \(KERNAL.GETIN)")
        if name.hasSuffix("$") {
            emit("    sta var_\(asm(name))")
            emit("    lda #0")
            emit("    sta var_\(asm(name))+1")
        } else {
            // Numeric GET: the interpreter converts a digit key to its
            // value (GET A with "5" gives 5), gives 0 with no key
            // pending, and stops with ?SYNTAX ERROR on any other
            // character. The old code stored the raw PETSCII code.
            emit("    jsr _rt_char_to_digit")
            let varType = table[name]
            switch varType.width {
            case .byte:
                emit("    sta var_\(asm(name))")
            case .word:
                // The digit is 0-9; zero-extend into the 2-byte slot.
                // Falling into the float branch here MOVMF'd 5 bytes over
                // 2-byte storage, corrupting the neighbors.
                emit("    sta var_\(asm(name))")
                emit("    lda #0")
                emit("    sta var_\(asm(name))+1")
            default:
                emit("    tay")
                emit("    lda #0")
                emit("    jsr \(ROM.INTFAC)")
                genStoreFloat(name)
            }
        }
    }

    /// GET into an array element. The character arrives in A, which cannot
    /// survive pulling the element pointer back, so it parks in _arith_tmp.
    private mutating func genGetElement(name: String, indices: [Expr]) {
        let dest = genPushElementPtr(name: name, indices: indices)

        emit("    jsr \(KERNAL.GETIN)")
        if name.hasSuffix("$") {
            // A one-character string: the character then a NUL, exactly
            // what the scalar path writes into var_X / var_X+1.
            genElementStoreByteInA(dest: dest)
            return
        }

        emit("    jsr _rt_char_to_digit")
        if name.hasSuffix("%") {
            genElementStoreByteInA(dest: dest)
        } else {
            emit("    tay")                 // Y = lo
            emit("    lda #0")              // A = hi
            emit("    jsr \(ROM.INTFAC)")   // GIVAYF: A/Y -> FAC1
            if dest == nil { genPopElementPtr() }
            genElementStoreFloat(dest: dest)
        }
    }

    /// INPUT# into one target. Array elements take the same address-on-the-
    /// stack route as READ; see `genPushElementPtr`.
    private mutating func genInputTarget(_ target: VarTarget) {
        guard case .element(let name, let indices) = target else {
            genInputOneVar(target.name)
            return
        }

        if name.hasSuffix("$") {
            // _rt_input_str writes through the pointer it is given.
            genElementDestToAY(name: name, indices: indices)
            emit("    jsr _rt_input_str")
            return
        }

        let dest = genPushElementPtr(name: name, indices: indices)
        if name.hasSuffix("%") {
            emit("    jsr _rt_input_num_int")
            if dest == nil { genPopElementPtr() }
            genElementStoreInt(dest: dest, lo: "_input_lo", hi: "_input_hi")
        } else {
            emit("    jsr _rt_input_num")
            if dest == nil { genPopElementPtr() }
            genElementStoreFloat(dest: dest)
        }
    }

    private mutating func genInputOneVar(_ varName: String) {
        if varName.hasSuffix("$") {
            emit("    lda #<var_\(asm(varName))")
            emit("    ldy #>var_\(asm(varName))")
            emit("    jsr _rt_input_str")
        } else {
            let varType = table[varName]
            switch varType.width {
            case .byte:
                emit("    jsr _rt_input_num_int")
                emit("    lda _input_lo")
                emit("    sta var_\(asm(varName))")
            case .word:
                emit("    jsr _rt_input_num_int")
                emit("    lda _input_lo")
                emit("    sta var_\(asm(varName))")
                emit("    lda _input_hi")
                emit("    sta var_\(asm(varName))+1")
            default:
                emit("    jsr _rt_input_num")
                genStoreFloat(varName)
            }
        }
    }

    // MARK: - READ / DATA

    private mutating func genRead(_ targets: [VarTarget]) {
        for target in targets {
            if case .element(let name, let indices) = target {
                genReadElement(name: name, indices: indices)
            } else {
                genReadScalar(target.name)
            }
        }
    }

    /// Fetches the next DATA byte into A, advancing _data_ptr. Tables up to
    /// 256 bytes keep the fast Y-indexed path (indices 0..255 all reachable;
    /// the low-byte-only inc can't wrap mid-table). Larger tables go through
    /// _rt_data_get_byte, which does full 16-bit indexing and carry —
    /// ldy/inc only ever saw the low byte and wrapped silently after 256.
    private mutating func genDataFetchByte() {
        if dataBytes.count > 256 {
            needsWideByteData = true
            emit("    jsr _rt_data_get_byte")
        } else {
            emit("    ldy _data_ptr")
            emit("    lda _data_table,y")
            emit("    inc _data_ptr")
        }
    }

    /// Loads the DATA item at _data_ptr into FAC1 (5-byte MFLPT table).
    /// Does NOT advance the pointer — call `genDataAdvanceFloat` after the
    /// value has been stored.
    private mutating func genDataFetchFloat() {
        let lbl = newLabel("rd")
        emit("    lda _data_ptr+1")
        emit("    clc")
        emit("    adc #>_data_table")
        emit("    tay")
        emit("    lda _data_ptr")
        emit("    clc")
        emit("    adc #<_data_table")
        emit("    bcc @\(lbl)")
        emit("    iny")
        emit("@\(lbl):")
        emit("    jsr \(ROM.MOVFM)")
    }

    private mutating func genDataAdvanceFloat() {
        emit("    lda _data_ptr")
        emit("    clc")
        emit("    adc #5")
        emit("    sta _data_ptr")
        emit("    lda _data_ptr+1")
        emit("    adc #0")
        emit("    sta _data_ptr+1")
    }

    /// Stores FAC1 into a scalar by its analysed width. AYINT is signed and
    /// range-checked; the old FACINT path threw ILLEGAL QUANTITY on
    /// negative DATA values.
    private mutating func genStoreFAC1ByWidth(_ name: String) {
        switch table[name].width {
        case .byte:
            emit("    jsr \(ROM.AYINT)")
            emit("    lda $65")
            emit("    sta var_\(asm(name))")
        case .word:
            emit("    jsr \(ROM.AYINT)")
            emit("    lda $65")
            emit("    sta var_\(asm(name))")
            emit("    lda $64")
            emit("    sta var_\(asm(name))+1")
        default:
            genStoreFloat(name)
        }
    }

    /// Fetches the next numeric DATA item and leaves its FOUT text in
    /// _str_slice_buf: the READ-string-target-with-numeric-DATA path. The
    /// stream pointer advances exactly as a numeric READ would, keeping
    /// later READs in sync (skipping the item desynchronized every READ
    /// after it). The interpreter reads the item's original source text,
    /// which the compiled table no longer has; FOUT's rendering differs
    /// only in the leading space/minus column.
    private mutating func genFetchNumericDataTextToSliceBuf(context: String) {
        warn("\(context): string target with numeric-only DATA; the compiled program reads the value's printed text (leading space differs from the interpreter)")
        if dataIsAllByte {
            genDataFetchByte()
            emit("    tay")                 // Y = lo
            emit("    lda #0")              // A = hi
            emit("    jsr \(ROM.INTFAC)")   // GIVAYF: A/Y -> FAC1
        } else {
            genDataFetchFloat()
            genDataAdvanceFloat()
        }
        emit("    jsr _rt_str_from_fac")
    }

    private mutating func genReadScalar(_ name: String) {
        if name.hasSuffix("$") {
            if dataHasString {
                emit("    lda #<var_\(asm(name))")
                emit("    ldy #>var_\(asm(name))")
                emit("    jsr _rt_data_read_str")
            } else {
                // Previously this fell into the numeric path and MOVMF'd a
                // float image into the string variable.
                genFetchNumericDataTextToSliceBuf(context: "READ \(name)")
                let lbl = newLabel("rds")
                emit("    ldy #0")
                emit("\(lbl):")
                emit("    lda _str_slice_buf,y")
                emit("    sta var_\(asm(name)),y")
                emit("    beq \(lbl)_done")
                emit("    iny")
                emit("    bne \(lbl)")
                emit("\(lbl)_done:")
            }
            return
        }

        if dataHasString {
            // Mixed string/numeric DATA: the tagged-stream reader
            // dispatches on the item tag, converts byte/word/float items
            // into FAC1, and advances _data_ptr by the item's encoded size
            // (a string item under a numeric READ is a type mismatch and
            // stops the program, mirroring what _rt_data_read_str does in
            // the opposite direction).
            emit("    jsr _rt_data_read_num")
            genStoreFAC1ByWidth(name)
            return
        }

        let varType = table[name]
        if dataIsAllByte {
            genDataFetchByte()
            switch varType.width {
            case .byte:
                emit("    sta var_\(asm(name))")
            case .word:
                emit("    sta var_\(asm(name))")
                emit("    lda #0")
                emit("    sta var_\(asm(name))+1")
            default:
                // Float-typed target reading from a byte table
                // (propagation widened the variable, e.g. READ X
                // followed by X=X+0.5). Previously this fell into
                // the float-table branch below, which misread raw
                // bytes as 5-byte MFLPT floats and advanced by 5.
                // Convert the fetched byte via GIVAYF instead.
                emit("    tay")                 // Y = lo
                emit("    lda #0")              // A = hi
                emit("    jsr \(ROM.INTFAC)")   // GIVAYF: A/Y -> FAC1
                genStoreFloat(name)
            }
        } else {
            genDataFetchFloat()
            genStoreFAC1ByWidth(name)
            genDataAdvanceFloat()
        }
    }

    /// READ into one array element. The element address has to survive the
    /// fetch, so it goes on the stack exactly as `genArrayWrite` does around
    /// RHS evaluation. Element width comes from the array's suffix — 2 bytes
    /// for `%`, 5 for float — NOT from the analysed scalar width, which
    /// describes a different piece of storage entirely.
    private mutating func genReadElement(name: String, indices: [Expr]) {
        // Strings: _rt_data_read_str writes through a destination pointer,
        // so the address is handed straight over and nothing needs saving.
        if name.hasSuffix("$") {
            if dataHasString {
                genElementDestToAY(name: name, indices: indices)
                emit("    jsr _rt_data_read_str")
            } else {
                // Previously this skipped WITHOUT consuming a DATA item,
                // desynchronizing every READ after it.
                genFetchNumericDataTextToSliceBuf(context: "READ \(name)()")
                genElementDestToAY(name: name, indices: indices)
                emit("    sta $FD")
                emit("    sty $FE")
                let lbl = newLabel("rde")
                emit("    ldy #0")
                emit("\(lbl):")
                emit("    lda _str_slice_buf,y")
                emit("    sta ($FD),y")
                emit("    beq \(lbl)_done")
                emit("    iny")
                emit("    bne \(lbl)")
                emit("\(lbl)_done:")
            }
            return
        }

        let isInt = name.hasSuffix("%")
        let dest  = genPushElementPtr(name: name, indices: indices)

        if dataHasString {
            emit("    jsr _rt_data_read_num")       // -> FAC1
            if isInt { emit("    jsr \(ROM.AYINT)") }
        } else if dataIsAllByte {
            genDataFetchByte()                      // -> A
            emit("    sta _arith_tmp")              // A cannot survive the pull
            if !isInt {
                emit("    ldy _arith_tmp")          // Y = lo
                emit("    lda #0")                  // A = hi
                emit("    jsr \(ROM.INTFAC)")       // GIVAYF: A/Y -> FAC1
            }
        } else {
            genDataFetchFloat()                     // -> FAC1
            if isInt { emit("    jsr \(ROM.AYINT)") }
        }

        if dest == nil { genPopElementPtr() }

        if isInt {
            // AYINT leaves the integer in $64 (hi) / $65 (lo); the byte
            // table needs no conversion and zero-extends. The condition
            // must mirror the fetch dispatch above exactly: with string
            // DATA present the fetch went through _rt_data_read_num even
            // when every numeric item fits a byte, so _arith_tmp is stale.
            if !dataHasString && dataIsAllByte {
                genElementStoreInt(dest: dest, lo: "_arith_tmp", hi: nil)
            } else {
                genElementStoreInt(dest: dest, lo: "$65", hi: "$64")
            }
        } else {
            genElementStoreFloat(dest: dest)
        }

        if !dataHasString && !dataIsAllByte { genDataAdvanceFloat() }
    }

    // MARK: - Array Element Targets (READ / INPUT#)

    /// Prepares an array element as a store destination. Constant subscripts
    /// resolve to an absolute label and nothing is emitted; otherwise the
    /// runtime element pointer is computed and PUSHED, and the caller must
    /// call `genPopElementPtr()` once the value has been fetched. The stack
    /// round-trip is what makes the fetch free to clobber _arr_ptr.
    private mutating func genPushElementPtr(name: String, indices: [Expr]) -> String? {
        if let off = constArrayByteOffset(name: name, indices: indices) {
            return "arr_\(asm(name))+\(off)"
        }
        genArrayElementPtr(name: name, indices: indices)
        emit("    lda _arr_ptr_lo")
        emit("    pha")
        emit("    lda _arr_ptr_hi")
        emit("    pha")
        return nil
    }

    /// Restores the pushed element pointer into _arr_ptr and $FD/$FE.
    /// Only pla/sta, so FAC1 is left alone.
    private mutating func genPopElementPtr() {
        emit("    pla")
        emit("    sta _arr_ptr_hi")
        emit("    sta $FE")
        emit("    pla")
        emit("    sta _arr_ptr_lo")
        emit("    sta $FD")
    }

    /// Loads an element's address into A/Y for the runtime string routines.
    private mutating func genElementDestToAY(name: String, indices: [Expr]) {
        if let off = constArrayByteOffset(name: name, indices: indices) {
            emit("    lda #<(arr_\(asm(name))+\(off))")
            emit("    ldy #>(arr_\(asm(name))+\(off))")
        } else {
            genArrayElementPtr(name: name, indices: indices)
            emit("    lda _arr_ptr_lo")
            emit("    ldy _arr_ptr_hi")
        }
    }

    /// Stores a 16-bit value held in memory into a 2-byte array element.
    /// `hi` nil zero-extends.
    private mutating func genElementStoreInt(dest: String?, lo: String, hi: String?) {
        if let dest {
            emit("    lda \(lo)")
            emit("    sta \(dest)")
            if let hi { emit("    lda \(hi)") } else { emit("    lda #0") }
            emit("    sta \(dest)+1")
        } else {
            emit("    ldy #0")
            emit("    lda \(lo)")
            emit("    sta ($FD),y")
            emit("    iny")
            if let hi { emit("    lda \(hi)") } else { emit("    lda #0") }
            emit("    sta ($FD),y")
        }
    }

    /// Stores the byte in A into a 2-byte array element, zero-extended.
    /// A constant destination is written straight from A; a runtime one has
    /// to park the value first, since pulling the pointer clobbers A.
    private mutating func genElementStoreByteInA(dest: String?) {
        if let dest {
            emit("    sta \(dest)")
            emit("    lda #0")
            emit("    sta \(dest)+1")
        } else {
            emit("    sta _arith_tmp")
            genPopElementPtr()
            genElementStoreInt(dest: nil, lo: "_arith_tmp", hi: nil)
        }
    }

    /// Stores FAC1 into a 5-byte float array element.
    private mutating func genElementStoreFloat(dest: String?) {
        if let dest {
            emit("    ldx #<(\(dest))")
            emit("    ldy #>(\(dest))")
        } else {
            emit("    ldx _arr_ptr_lo")
            emit("    ldy _arr_ptr_hi")
        }
        emit("    jsr \(ROM.MOVMF)")
    }

    // MARK: - ON GOTO / GOSUB
    private mutating func genOnGotoGosub(expr: Expr, targets: [Int], isGosub: Bool) {
        guard !targets.isEmpty else { return }
        let done = newLabel("on_done")
        let op   = isGosub ? "jsr" : "jmp"
        genExprToByte(expr)
        // Re-derive Z from A: genExprToByte sequences ending in ldx leave
        // the flags describing the wrong register.
        emit("    cmp #0")
        emit("    beq \(done)")
        emit("    cmp #\(targets.count + 1)")
        emit("    bcs \(done)")
        for (i, target) in targets.enumerated() {
            let skip = newLabel("on_c")
            emit("    cmp #\(i + 1)")
            emit("    bne \(skip)")
            emit("    \(op) \(lineLabel(target))")
            if isGosub { emit("    jmp \(done)") }
            emit("\(skip):")
        }
        emit("\(done):")
    }

    // MARK: - OPEN / CLOSE
    /// KERNAL SETNAM from a string expression. Register protocol:
    /// A=length, X=ptr lo, Y=ptr hi - once hand-copied in three places,
    /// and once scrambled in one of them (nothing ever loaded).
    private mutating func emitSetNam(_ name: Expr) {
        genStrPtr(name)
        emit("    jsr _rt_strlen")      // A = length
        emit("    ldx $FB")             // X = name ptr lo
        emit("    ldy $FC")             // Y = name ptr hi
        emit("    jsr \(KERNAL.SETNAM)")
    }

    private mutating func genOpen(logNum: Expr, device: Expr, secondary: Expr, filename: Expr?) {
        genExprToByte(logNum);    emit("    sta _open_log")
        genExprToByte(device);   emit("    sta _open_dev")
        genExprToByte(secondary);emit("    sta _open_sec")
        emit("    lda _open_log")
        emit("    ldx _open_dev")
        emit("    ldy _open_sec")
        emit("    jsr \(KERNAL.SETLFS)")
        if let fn = filename {
            emitSetNam(fn)
        } else {
            emit("    lda #0")
            emit("    jsr \(KERNAL.SETNAM)")
        }
        emit("    jsr \(KERNAL.KOPEN)")
    }

    // MARK: - Array Write
    private mutating func genArrayWrite(name: String, indices: [Expr], rhs: Expr) {
        if let off = constArrayByteOffset(name: name, indices: indices) {
            // Constant subscripts: direct absolute stores. No element
            // pointer exists, so nothing needs saving around the RHS.
            let addr = "arr_\(asm(name))+\(off)"
            if name.hasSuffix("$") {
                genStrPtr(rhs)
                emit("    lda #<(\(addr))")
                emit("    sta $FD")
                emit("    lda #>(\(addr))")
                emit("    sta $FE")
                let lbl = newLabel("awc")
                emit("    ldy #0")
                emit("\(lbl):")
                emit("    lda ($FB),y")
                emit("    sta ($FD),y")
                emit("    beq \(lbl)_done")
                emit("    iny")
                emit("    bne \(lbl)")
                emit("\(lbl)_done:")
            } else if name.hasSuffix("%") {
                genExprToWord(rhs)
                emit("    sta \(addr)")
                emit("    stx \(addr)+1")
            } else {
                genExprToFloat(rhs)
                emit("    ldx #<(\(addr))")
                emit("    ldy #>(\(addr))")
                emit("    jsr \(ROM.MOVMF)")
            }
            return
        }

        genArrayElementPtr(name: name, indices: indices)
        if name.hasSuffix("$") {
            // The destination pointer must survive the RHS: genStrPtr for a
            // string-array element (A$(I)=B$(J), or any concat containing
            // one) recomputes _arr_ptr, which used to leave source and
            // destination both pointing at the RHS element.
            emit("    lda _arr_ptr_lo")
            emit("    pha")
            emit("    lda _arr_ptr_hi")
            emit("    pha")
            genStrPtr(rhs)
            emit("    pla")
            emit("    sta $FE")
            emit("    pla")
            emit("    sta $FD")
            let lbl = newLabel("aws")
            emit("    ldy #0")
            emit("\(lbl):")
            emit("    lda ($FB),y")
            emit("    sta ($FD),y")
            emit("    beq \(lbl)_done")
            emit("    iny")
            emit("    bne \(lbl)")
            emit("\(lbl)_done:")
        } else if name.hasSuffix("%") {
            // Integer arrays store 2-byte little-endian values matching the
            // 2-bytes-per-element stride in genArrayElementPtr/emitStorage.
            // (Previously this fell into the float branch and wrote 5 bytes
            // into 2-byte slots, corrupting the neighbors.)
            // Save the element pointer: evaluating the RHS can recompute
            // _arr_ptr for a nested array read (A%(I) = A%(J) + 1).
            emit("    lda _arr_ptr_lo")
            emit("    pha")
            emit("    lda _arr_ptr_hi")
            emit("    pha")
            genExprToWord(rhs)              // A = lo, X = hi
            emit("    sta _arith_tmp")      // safe: RHS eval is complete
            emit("    pla")
            emit("    sta $FE")
            emit("    pla")
            emit("    sta $FD")
            emit("    ldy #0")
            emit("    lda _arith_tmp")
            emit("    sta ($FD),y")
            emit("    iny")
            emit("    txa")
            emit("    sta ($FD),y")
        } else {
            // Save the element pointer for the same nested-read reason.
            emit("    lda _arr_ptr_lo")
            emit("    pha")
            emit("    lda _arr_ptr_hi")
            emit("    pha")
            genExprToFloat(rhs)
            emit("    pla")                 // FAC untouched by pla/sta
            emit("    sta _arr_ptr_hi")
            emit("    pla")
            emit("    sta _arr_ptr_lo")
            emit("    ldx _arr_ptr_lo")
            emit("    ldy _arr_ptr_hi")
            emit("    jsr \(ROM.MOVMF)")
        }
    }

    /// Multiplies the 16-bit _arr_idx accumulator in place by a
    /// compile-time constant using inline shift-add. Replaces the old
    /// _rt_mul8 calls, which were both slow (~170 cycles vs ~10-30 here)
    /// and WRONG for arrays larger than 255 elements: they fed only the
    /// LOW byte of the accumulated index into an 8-bit multiply, so
    /// A(260) indexed off 260 mod 256.
    private mutating func emitIdxMulConst(_ k: Int) {
        if k == 1 { return }
        if k == 0 {
            emit("    lda #0")
            emit("    sta _arr_idx_lo")
            emit("    sta _arr_idx_hi")
            return
        }
        // Multi-bit constants need the original value saved for the adds.
        if k.nonzeroBitCount > 1 {
            emit("    lda _arr_idx_lo")
            emit("    sta _arr_mul_lo")
            emit("    lda _arr_idx_hi")
            emit("    sta _arr_mul_hi")
        }
        // MSB-first: accumulator already holds x (the top set bit), then
        // for each lower bit: double, and add the saved original if set.
        var bit = 1
        while bit << 1 <= k { bit <<= 1 }
        bit >>= 1
        while bit >= 1 {
            emit("    asl _arr_idx_lo")
            emit("    rol _arr_idx_hi")
            if k & bit != 0 {
                emit("    lda _arr_idx_lo")
                emit("    clc")
                emit("    adc _arr_mul_lo")
                emit("    sta _arr_idx_lo")
                emit("    lda _arr_idx_hi")
                emit("    adc _arr_mul_hi")
                emit("    sta _arr_idx_hi")
            }
            bit >>= 1
        }
    }

    /// Bytes per array element by name suffix: $=256 (fixed string slot),
    /// %=2, float=5. The single source of truth - element address math
    /// (runtime and constant-folded) and storage allocation must agree
    /// byte-for-byte or same-array accesses silently address different
    /// memory.
    static func bytesPerElement(for name: String) -> Int {
        if name.hasSuffix("$") { return 256 }
        if name.hasSuffix("%") { return 2 }
        return 5
    }

    /// True when evaluating the expression can re-enter genArrayElementPtr
    /// (an array read anywhere in the tree, or a user FN whose inlined body
    /// might contain one) and therefore clobber the shared _arr_idx.
    private func exprReadsArray(_ e: Expr) -> Bool {
        switch e {
        case .arrayRead: return true
        case .binaryOp(_, let l, let r), .compareOp(_, let l, let r):
            return exprReadsArray(l) || exprReadsArray(r)
        case .unaryMinus(let inner), .notOp(let inner):
            return exprReadsArray(inner)
        case .funcCall(let name, let args):
            return name.hasPrefix("FN") || args.contains { exprReadsArray($0) }
        default: return false
        }
    }

    private mutating func genArrayElementPtr(name: String, indices: [Expr]) {
        let dims = arrayDims.first(where: { $0.name == name })?.dims ?? [11]
        let bytesPerElem = Self.bytesPerElement(for: name)

        if indices.count != dims.count {
            // BAD SUBSCRIPT on real hardware; clamping (extra subscripts
            // scale by the default dimension) keeps the compiler alive
            // instead of trapping on dims[i].
            warn("\(name): \(indices.count) subscript(s) for a \(dims.count)-dimensional array")
        }

        for (i, idx) in indices.enumerated() {
            if i == 0 {
                // Store, not zero-init-and-add: a nested array read inside
                // the subscript (A(B(J))) re-enters this function and
                // rewrites _arr_idx before the value comes back.
                // Full 16-bit subscript: the old genExprToByte call
                // truncated subscripts over 255, so A(300) indexed elem 44.
                genExprToWord(idx)
                emit("    sta _arr_idx_lo")
                emit("    stx _arr_idx_hi")
                continue
            }
            emitIdxMulConst(i < dims.count ? dims[i] : 11)
            if exprReadsArray(idx) {
                // The subscript's evaluation clobbers _arr_idx; keep the
                // accumulated index on the stack across it. _arr_mul is
                // free here - emitIdxMulConst is already done.
                emit("    lda _arr_idx_lo")
                emit("    pha")
                emit("    lda _arr_idx_hi")
                emit("    pha")
                genExprToWord(idx)
                emit("    sta _arr_mul_lo")
                emit("    stx _arr_mul_hi")
                emit("    pla")
                emit("    sta _arr_idx_hi")
                emit("    pla")
                emit("    sta _arr_idx_lo")
                emit("    lda _arr_mul_lo")
                emit("    clc")
                emit("    adc _arr_idx_lo")
                emit("    sta _arr_idx_lo")
                emit("    lda _arr_mul_hi")
                emit("    adc _arr_idx_hi")
                emit("    sta _arr_idx_hi")
            } else {
                genExprToWord(idx)
                emit("    clc")
                emit("    adc _arr_idx_lo")
                emit("    sta _arr_idx_lo")
                emit("    txa")
                emit("    adc _arr_idx_hi")
                emit("    sta _arr_idx_hi")
            }
        }

        if bytesPerElem == 256 {
            emit("    lda _arr_idx_lo")
            emit("    sta _arr_idx_hi")
            emit("    lda #0")
            emit("    sta _arr_idx_lo")
        } else if bytesPerElem > 1 {
            emitIdxMulConst(bytesPerElem)
        }

        emit("    lda #<arr_\(asm(name))")
        emit("    clc")
        emit("    adc _arr_idx_lo")
        emit("    sta _arr_ptr_lo")
        emit("    lda #>arr_\(asm(name))")
        emit("    adc _arr_idx_hi")
        emit("    sta _arr_ptr_hi")
    }

    // MARK: - Expression Evaluation
    /// True when the tree contains an operation whose exact result can be
    /// fractional: '/', '^', or a float-producing function. BASIC does all
    /// arithmetic in floats and rounds ONCE at the final conversion, so an
    /// integer-math tree that floors such an intermediate diverges from the
    /// interpreter (A%=7/2*2 gave 6, not 7). AND/OR and comparisons stop
    /// the walk: hardware converts their operands to ints individually.
    private func exprHasFractionalOp(_ e: Expr) -> Bool {
        switch e {
        case .binaryOp("AND", _, _), .binaryOp("OR", _, _):
            return false
        case .binaryOp(let op, let l, let r):
            return op == "/" || op == "^"
                || exprHasFractionalOp(l) || exprHasFractionalOp(r)
        case .unaryMinus(let inner):
            return exprHasFractionalOp(inner)
        case .funcCall(let name, _):
            return !["PEEK", "ASC", "LEN", "INT"].contains(name)
        default:
            return false
        }
    }

    /// Integer contexts bail to float evaluation when an operand subtree
    /// can be fractional - see exprHasFractionalOp. The operator's own
    /// result converting at the statement boundary is the correct single
    /// rounding, so only operand subtrees force the bail-out.
    private func intPathWouldFloorIntermediates(_ expr: Expr) -> Bool {
        if case .binaryOp(let op, let l, let r) = expr, op != "AND", op != "OR" {
            return exprHasFractionalOp(l) || exprHasFractionalOp(r)
        }
        return false
    }

    mutating func genExprToByte(_ expr: Expr) {
        if intPathWouldFloorIntermediates(expr) {
            genExprToFloat(expr)
            emit("    jsr _rt_fac_to_byte")
            return
        }
        switch expr {
        case .intLit(let n):
            emit("    lda #\(n & 0xFF)")
        case .floatLit(let f):
            genExprToFloat(.floatLit(f))
            emit("    jsr _rt_fac_to_byte")
        case .floatVar(let name):
            if name == "TI" { genExprToFloat(.tiVar); break }
            if name == "ST" { genExprToFloat(.stVar); break }
            let w = table[name].width
            if w == .byte || w == .word {
                emit("    lda var_\(asm(name))")
            } else {
                emit("    lda #<var_\(asm(name))")
                emit("    ldy #>var_\(asm(name))")
                emit("    jsr \(ROM.MOVFM)")
                emit("    jsr _rt_fac_to_byte")
            }
        case .intVar(let name):
            emit("    lda var_\(asm(name))")
        case .funcCall("PEEK", let args) where !args.isEmpty:
            genExprToWord(args[0])
            emit("    sta _peek_lo")
            emit("    stx _peek_hi")
            emit("    jsr _rt_peek_byte")
        case .funcCall("ASC", let args) where !args.isEmpty:
            genStrPtr(args[0])
            emit("    ldy #0")
            emit("    lda ($FB),y")
        case .funcCall("LEN", let args) where !args.isEmpty:
            genStrPtr(args[0])
            emit("    jsr _rt_strlen")
        case .binaryOp("AND", let l, let r):
            let s = newLabel("bas"); emitByteScratch(s)
            genExprToByte(l); emit("    sta \(s)"); genExprToByte(r); emit("    and \(s)")
        case .binaryOp("OR", let l, let r):
            let s = newLabel("bos"); emitByteScratch(s)
            genExprToByte(l); emit("    sta \(s)"); genExprToByte(r); emit("    ora \(s)")
        case .binaryOp("+", let l, let r):
            genExprToByte(l)
            if let k = constByteValue(r) { emit("    clc"); emit("    adc #\(k)") }
            else {
                // Per-node scratch: a shared temp here breaks right-nested
                // expressions like A-(B-C), whose inner node reuses it.
                let s = newLabel("bps"); emitByteScratch(s)
                emit("    sta \(s)"); genExprToByte(r); emit("    clc"); emit("    adc \(s)")
            }
        case .binaryOp("-", let l, let r):
            genExprToByte(l)
            if let k = constByteValue(r) { emit("    sec"); emit("    sbc #\(k)") }
            else {
                let s = newLabel("bss"); emitByteScratch(s)
                emit("    sta \(s)"); genExprToByte(r); emit("    sta _arith_tmp")
                emit("    lda \(s)"); emit("    sec"); emit("    sbc _arith_tmp")
            }
        case .binaryOp("*", _, _), .binaryOp("/", _, _):
            // Word math; the result's low byte is already in A. Keeps
            // byte-context products and quotients out of the float path.
            // (A possibly-signed divide still falls to float inside
            // genExprToWord, which is exactly what we want.)
            genExprToWord(expr)
        case .unaryMinus(let e):
            genExprToByte(e); emit("    eor #$FF"); emit("    clc"); emit("    adc #1")
        case .funcCall("CHR$", _):
            if case .funcCall(_, let args) = expr, let a = args.first { genExprToByte(a) }
        default:
            genExprToFloat(expr); emit("    jsr _rt_fac_to_byte")
        }
    }

    mutating func genExprToWord(_ expr: Expr) {
        if intPathWouldFloorIntermediates(expr) {
            genExprToFloat(expr)
            emit("    jsr \(ROM.AYINT)")
            emit("    lda $65"); emit("    ldx $64")
            return
        }
        switch expr {
        case .intLit(let n):
            emit("    lda #<\(n)"); emit("    ldx #>\(n)")
        case .floatLit(let f):
            // Int(f) traps on infinite/out-of-range doubles (1E999 lexes
            // as an infinite floatLit); diagnose instead of crashing.
            guard f.isFinite, f >= -32768, f <= 65535 else {
                warn("float literal \(f) does not fit a 16-bit value; using 0")
                emit("    lda #0"); emit("    ldx #0")
                break
            }
            let i = Int(f)
            emit("    lda #<\(i)"); emit("    ldx #>\(i)")
        case .floatVar(let name):
            if name == "TI" { genExprToFloat(.tiVar); break }
            if name == "ST" { genExprToFloat(.stVar); break }
            let w = table[name].width
            if w == .byte {
                emit("    lda var_\(asm(name))"); emit("    ldx #0")
            } else if w == .word {
                emit("    lda var_\(asm(name))"); emit("    ldx var_\(asm(name))+1")
            } else {
                genExprToFloat(expr)
                // AYINT, not FACINT/GETADR: the value may be negative.
                emit("    jsr \(ROM.AYINT)")
                emit("    lda $65"); emit("    ldx $64")
            }
        case .intVar(let name):
            emit("    lda var_\(asm(name))"); emit("    ldx var_\(asm(name))+1")
        case .binaryOp("+", let l, let r):
            // Constant on either side stays register-only.
            if let k = constWordValue(r) ?? constWordValue(l) {
                genExprToWord(constWordValue(r) != nil ? l : r)
                emit("    clc")
                emit("    adc #<\(k)")
                emit("    tay")
                emit("    txa")
                emit("    adc #>\(k)")
                emit("    tax")
                emit("    tya")
            } else {
                // Per-node scratch: the old shared _word_lo/_word_hi save
                // slot broke right-nested expressions (A + B*C evaluates
                // B*C while A sits in the slot the inner node reuses).
                let s = newLabel("was"); emitWordScratch(s)
                genExprToWord(l)
                emit("    sta \(s)")
                emit("    stx \(s)+1")
                genExprToWord(r)
                emit("    clc")
                emit("    adc \(s)")
                emit("    tay")
                emit("    txa")
                emit("    adc \(s)+1")
                emit("    tax")
                emit("    tya")
            }
        case .binaryOp("-", let l, let r):
            if let k = constWordValue(r) {
                genExprToWord(l)
                emit("    sec")
                emit("    sbc #<\(k)")
                emit("    tay")
                emit("    txa")
                emit("    sbc #>\(k)")
                emit("    tax")
                emit("    tya")
            } else {
                let s = newLabel("wss"); emitWordScratch(s)
                genExprToWord(l)
                emit("    sta \(s)")
                emit("    stx \(s)+1")
                genExprToWord(r)
                // r's evaluation is complete here, so these shared temps
                // are safe: nothing evaluates between the store and use.
                emit("    sta _arith_tmp")
                emit("    stx _word_hi_tmp")
                emit("    lda \(s)")
                emit("    sec")
                emit("    sbc _arith_tmp")
                emit("    tay")
                emit("    lda \(s)+1")
                emit("    sbc _word_hi_tmp")
                emit("    tax")
                emit("    tya")
            }
        case .binaryOp("*", let l, let r):
            // Word multiply is mod 65536; two's complement makes the low
            // 16 bits correct for signed operands too. Float contexts are
            // untouched (products above 65535 still compute exactly
            // there). Note the old behavior for a word-context product
            // over 65535 was a GETADR ILLEGAL QUANTITY stop; wrapping is
            // both faster and more useful for address math.
            if let k = constWordValue(r) ?? constWordValue(l) {
                let varSide = constWordValue(r) != nil ? l : r
                genExprToWord(varSide)
                if k == 0 {
                    emit("    lda #0")
                    emit("    tax")
                } else if k > 1 {
                    // Inline shift-add, MSB-first over the bits of k.
                    let s = newLabel("wms"); emitWordScratch(s)
                    let s2 = newLabel("wmo")
                    let multiBit = k.nonzeroBitCount > 1
                    if multiBit { emitWordScratch(s2) }
                    emit("    sta \(s)")
                    emit("    stx \(s)+1")
                    if multiBit {
                        emit("    sta \(s2)")
                        emit("    stx \(s2)+1")
                    }
                    var bit = 1
                    while bit << 1 <= k { bit <<= 1 }
                    bit >>= 1
                    while bit >= 1 {
                        emit("    asl \(s)")
                        emit("    rol \(s)+1")
                        if k & bit != 0 {
                            emit("    lda \(s)")
                            emit("    clc")
                            emit("    adc \(s2)")
                            emit("    sta \(s)")
                            emit("    lda \(s)+1")
                            emit("    adc \(s2)+1")
                            emit("    sta \(s)+1")
                        }
                        bit >>= 1
                    }
                    emit("    lda \(s)")
                    emit("    ldx \(s)+1")
                }
                // k == 1: value already in A/X.
            } else {
                needsMul16 = true
                let s = newLabel("wml"); emitWordScratch(s)
                genExprToWord(l)
                emit("    sta \(s)")
                emit("    stx \(s)+1")
                genExprToWord(r)
                emit("    sta _mul_b")
                emit("    stx _mul_b+1")
                emit("    lda \(s)")
                emit("    sta _mul_a")
                emit("    lda \(s)+1")
                emit("    sta _mul_a+1")
                emit("    jsr _rt_mul16")
            }
        case .binaryOp("/", let l, let r) where !exprMaybeSigned(l) && !exprMaybeSigned(r):
            // Unsigned integer division floors exactly like BASIC does in
            // an integer context, so results match the old float path for
            // non-negative operands. Possibly-signed operands fall through
            // to the float default (floor(-7/2) is -4; truncation says -3).
            if let k = constWordValue(r) {
                if k == 0 {
                    warn("division by constant zero; program will stop here")
                    genExprToWord(l)
                    emit("    jmp _program_end")
                } else if k == 1 {
                    genExprToWord(l)
                } else if k.nonzeroBitCount == 1 {
                    let s = newLabel("wds"); emitWordScratch(s)
                    genExprToWord(l)
                    emit("    sta \(s)")
                    emit("    stx \(s)+1")
                    var q = k
                    while q > 1 {
                        emit("    lsr \(s)+1")
                        emit("    ror \(s)")
                        q >>= 1
                    }
                    emit("    lda \(s)")
                    emit("    ldx \(s)+1")
                } else {
                    needsDiv16 = true
                    genExprToWord(l)
                    emit("    sta _div_n")
                    emit("    stx _div_n+1")
                    emit("    lda #<\(k)")
                    emit("    sta _div_d")
                    emit("    lda #>\(k)")
                    emit("    sta _div_d+1")
                    emit("    jsr _rt_div16")
                }
            } else {
                needsDiv16 = true
                let s = newLabel("wdl"); emitWordScratch(s)
                genExprToWord(l)
                emit("    sta \(s)")
                emit("    stx \(s)+1")
                genExprToWord(r)
                emit("    sta _div_d")
                emit("    stx _div_d+1")
                emit("    lda \(s)")
                emit("    sta _div_n")
                emit("    lda \(s)+1")
                emit("    sta _div_n+1")
                emit("    jsr _rt_div16")
            }
        case .arrayRead(let name, let idxs) where name.hasSuffix("%"):
            if let off = constArrayByteOffset(name: name, indices: idxs) {
                emit("    lda arr_\(asm(name))+\(off)")
                emit("    ldx arr_\(asm(name))+\(off)+1")
                break
            }
            // Direct 2-byte load. Going through the float path would send
            // negative elements into GETADR's ILLEGAL QUANTITY check.
            genArrayElementPtr(name: name, indices: idxs)
            emit("    lda _arr_ptr_lo")
            emit("    sta $FD")
            emit("    lda _arr_ptr_hi")
            emit("    sta $FE")
            emit("    ldy #1")
            emit("    lda ($FD),y")
            emit("    tax")                 // hi
            emit("    dey")
            emit("    lda ($FD),y")         // lo
        case .binaryOp("AND", let l, let r):
            genBitwiseWord(mnemonic: "and", l, r)
        case .binaryOp("OR", let l, let r):
            genBitwiseWord(mnemonic: "ora", l, r)
        case .notOp(let e):
            // BASIC NOT is 16-bit one's complement: NOT x = -x-1.
            genExprToWord(e)
            emit("    eor #$FF")
            emit("    pha")
            emit("    txa")
            emit("    eor #$FF")
            emit("    tax")
            emit("    pla")
        case .compareOp:
            // Produce 0 / $FFFF directly. Routing this through the float
            // path would call GETADR on -1 for a true result, which throws
            // ILLEGAL QUANTITY into the ROM error handler.
            let falseL = newLabel("wcf")
            let endL   = newLabel("wce")
            genConditionBranch(expr, branchIfFalse: falseL)
            emit("    lda #$FF")
            emit("    tax")
            emit("    jmp \(endL)")
            emit("\(falseL):")
            emit("    lda #0")
            emit("    tax")
            emit("\(endL):")
        case .funcCall("PEEK", let args) where !args.isEmpty:
            genExprToWord(args[0])
            emit("    sta _peek_lo"); emit("    stx _peek_hi")
            emit("    jsr _rt_peek_byte"); emit("    ldx #0")
        default:
            genExprToFloat(expr)
            // AYINT, not FACINT/GETADR: GETADR throws ILLEGAL QUANTITY on
            // any negative FAC, and word context routinely sees negatives
            // (A% = -5, signed subexpressions).
            emit("    jsr \(ROM.AYINT)")
            emit("    lda $65"); emit("    ldx $64")
        }
    }

    /// 16-bit bitwise AND/OR. Result in A (lo) / X (hi), matching the
    /// genExprToWord convention. Each node gets its own 2-byte scratch so
    /// nested bitwise expressions can't clobber each other's saved operand.
    private mutating func genBitwiseWord(mnemonic: String, _ l: Expr, _ r: Expr) {
        let tmp = newLabel("bw")
        emitWordScratch(tmp)
        genExprToWord(l)
        emit("    sta \(tmp)")
        emit("    stx \(tmp)+1")
        genExprToWord(r)
        emit("    \(mnemonic) \(tmp)")
        emit("    sta \(tmp)")
        emit("    txa")
        emit("    \(mnemonic) \(tmp)+1")
        emit("    tax")
        emit("    lda \(tmp)")
    }

    mutating func genExprToFloat(_ expr: Expr) {
        switch expr {
        case .intLit(let n) where n >= 0 && n <= 255:
            emit("    lda #0"); emit("    ldy #\(n)"); emit("    jsr \(ROM.INTFAC)")
        case .intLit(let n):
            let lbl = emitFloatConstValue(Double(n))
            emit("    lda #<\(lbl)"); emit("    ldy #>\(lbl)"); emit("    jsr \(ROM.MOVFM)")
        case .floatLit(let f):
            let lbl = emitFloatConstValue(f)
            emit("    lda #<\(lbl)"); emit("    ldy #>\(lbl)"); emit("    jsr \(ROM.MOVFM)")
        case .strLit, .strVar:
            warn("string used in numeric context; FAC left unchanged")
        case .floatVar(let name):
            let w = table[name].width
            if name == "TI" { genExprToFloat(.tiVar); break }
            if name == "ST" { genExprToFloat(.stVar); break }
            if w == .byte {
                if table[name].isSigned {
                    let sextLabel = newLabel("sext")
                    emit("    ldy var_\(asm(name))"); emit("    lda #0")
                    emit("    cpy #$80"); emit("    bcc \(sextLabel)")
                    emit("    lda #$FF"); emit("\(sextLabel):")
                    emit("    jsr \(ROM.INTFAC)")
                } else {
                    emit("    lda #0"); emit("    ldy var_\(asm(name))"); emit("    jsr \(ROM.INTFAC)")
                }
            } else if w == .word {
                if table[name].isSigned {
                    // Signed word (e.g. produced by word subtraction):
                    // GIVAYF's signed interpretation is exactly right.
                    emit("    lda var_\(asm(name))+1"); emit("    ldy var_\(asm(name))"); emit("    jsr \(ROM.INTFAC)")
                } else {
                    // Unsigned word: GIVAYF is SIGNED 16-bit, so values
                    // above 32767 would come out negative (X=50000 would
                    // print -15536). The helper adds 65536 back when the
                    // high bit was set.
                    emit("    lda var_\(asm(name))+1"); emit("    ldy var_\(asm(name))"); emit("    jsr _rt_uword_to_fac")
                }
            } else {
                emit("    lda #<var_\(asm(name))"); emit("    ldy #>var_\(asm(name))"); emit("    jsr \(ROM.MOVFM)")
            }
        case .intVar(let name):
            emit("    lda var_\(asm(name))+1"); emit("    ldy var_\(asm(name))"); emit("    jsr \(ROM.INTFAC)")
        case .tiVar:
            let lbl256 = emitFloatConstValue(256.0)
            let tmp = newLabel("titmp")
            emitFloatScratch(tmp)
            // Snapshot the 3-byte jiffy clock atomically FIRST. The float
            // calls below take hundreds of cycles each; an IRQ tick between
            // the byte reads produces a torn value around rollovers (e.g.
            // $00FFFF -> $010000 read as $01FFFF: off by 65280 jiffies).
            emit("    sei")
            emit("    lda $A0"); emit("    sta _ti_buf+2")   // hi
            emit("    lda $A1"); emit("    sta _ti_buf+1")   // mid
            emit("    lda $A2"); emit("    sta _ti_buf")     // lo
            emit("    cli")
            emit("    lda #0"); emit("    ldy _ti_buf+2"); emit("    jsr \(ROM.INTFAC)")
            emit("    lda #<\(lbl256)"); emit("    ldy #>\(lbl256)"); emit("    jsr \(ROM.FMUL)")
            emit("    ldx #<\(tmp)"); emit("    ldy #>\(tmp)"); emit("    jsr \(ROM.MOVMF)")
            emit("    lda #0"); emit("    ldy _ti_buf+1"); emit("    jsr \(ROM.INTFAC)")
            emit("    lda #<\(tmp)"); emit("    ldy #>\(tmp)"); emit("    jsr \(ROM.FADD)")
            emit("    lda #<\(lbl256)"); emit("    ldy #>\(lbl256)"); emit("    jsr \(ROM.FMUL)")
            emit("    ldx #<\(tmp)"); emit("    ldy #>\(tmp)"); emit("    jsr \(ROM.MOVMF)")
            emit("    lda #0"); emit("    ldy _ti_buf"); emit("    jsr \(ROM.INTFAC)")
            emit("    lda #<\(tmp)"); emit("    ldy #>\(tmp)"); emit("    jsr \(ROM.FADD)")
        case .stVar:
            emit("    lda #0"); emit("    ldy $90"); emit("    jsr \(ROM.INTFAC)")
        case .unaryMinus(let e):
            genExprToFloat(e); emit("    jsr \(ROM.NEGFAC)")
        case .notOp:
            // BASIC NOT is bitwise one's complement on a 16-bit signed int
            // (NOT x = -x-1), not logical negation. NOT 0 = -1, NOT 1 = -2.
            genExprToWord(expr)
            emit("    tay")             // lo → Y
            emit("    txa")             // hi → A
            emit("    jsr \(ROM.INTFAC)")
        case .binaryOp(let op, let l, let r):
            if op == "AND" || op == "OR" {
                // 16-bit bitwise, then signed word → FAC. GIVAYF being
                // signed is CORRECT here: BASIC AND/OR operate on 16-bit
                // signed ints and the result can legitimately be negative
                // (e.g. -1 AND X = X, NOT 0 = -1).
                genExprToWord(expr)
                emit("    tay")             // lo → Y
                emit("    txa")             // hi → A
                emit("    jsr \(ROM.INTFAC)")
                break
            }
            let tmp = newLabel("ftmp")
            emitFloatConst(tmp, 0.0)
            if op == "^" {
                // $BF7B entry requirements (see the ROM's own SQR at $BF71,
                // which falls into it): ARG = base, FAC = exponent, and
                // A = FAC exponent byte so the entry BEQ can test for a
                // zero exponent. The old sequence copied the base to ARG
                // FIRST and then evaluated the exponent, which clobbers
                // ARG the moment the exponent involves any FADD/FMUL.
                genExprToFloat(l)                                   // base -> FAC
                emit("    ldx #<\(tmp)"); emit("    ldy #>\(tmp)"); emit("    jsr \(ROM.MOVMF)")   // base -> tmp
                genExprToFloat(r)                                   // exponent -> FAC
                emit("    lda #<\(tmp)"); emit("    ldy #>\(tmp)"); emit("    jsr \(ROM.CONUPK)")  // base -> ARG
                emit("    lda $61")                                 // A/Z = FAC exponent
                emit("    jsr \(ROM.FPOW)")
            } else {
                genExprToFloat(l)
                emit("    ldx #<\(tmp)"); emit("    ldy #>\(tmp)"); emit("    jsr \(ROM.MOVMF)")
                genExprToFloat(r)
                emit("    lda #<\(tmp)"); emit("    ldy #>\(tmp)")
                switch op {
                case "+": emit("    jsr $B867")
                case "-": emit("    jsr $B850")
                case "*": emit("    jsr \(ROM.FMUL)")
                case "/": emit("    jsr \(ROM.FDIV)")
                default: break
                }
            }
        case .compareOp(let op, let l, let r):
            let tmp = newLabel("fcmp")
            emitFloatConst(tmp, 0.0)
            genExprToFloat(r); emit("    ldx #<\(tmp)"); emit("    ldy #>\(tmp)"); emit("    jsr \(ROM.MOVMF)")
            genExprToFloat(l); emit("    lda #<\(tmp)"); emit("    ldy #>\(tmp)"); emit("    jsr \(ROM.FCOMP)")
            let trueL = newLabel("ct")
            let endL  = newLabel("ce")
            switch op {
            case "=":  emit("    beq \(trueL)")
            case "<>": emit("    bne \(trueL)")
            case "<":  emit("    bmi \(trueL)")
            case ">":  emit("    cmp #1"); emit("    beq \(trueL)")
            case "<=": emit("    beq \(trueL)"); emit("    bmi \(trueL)")
            case ">=": emit("    beq \(trueL)"); emit("    cmp #1"); emit("    beq \(trueL)")
            default: break
            }
            emit("    lda #0"); emit("    tay"); emit("    jsr \(ROM.INTFAC)")
            emit("    jmp \(endL)")
            emit("\(trueL):")
            // BASIC truth value is -1, not +1: GIVAYF(A=$FF, Y=$FF) = -1.
            emit("    lda #$FF"); emit("    tay"); emit("    jsr \(ROM.INTFAC)")
            emit("\(endL):")
        case .funcCall(let fn, let args):
            genFuncCallToFloat(fn: fn, args: args)
        case .arrayRead(let name, let idxs):
            if let off = constArrayByteOffset(name: name, indices: idxs) {
                // All subscripts constant: the element address is a ca65
                // expression, no runtime pointer math at all.
                if name.hasSuffix("%") {
                    emit("    lda arr_\(asm(name))+\(off)+1")   // hi
                    emit("    ldy arr_\(asm(name))+\(off)")     // lo
                    emit("    jsr \(ROM.INTFAC)")
                } else {
                    emit("    lda #<(arr_\(asm(name))+\(off))")
                    emit("    ldy #>(arr_\(asm(name))+\(off))")
                    emit("    jsr \(ROM.MOVFM)")
                }
                break
            }
            genArrayElementPtr(name: name, indices: idxs)
            if name.hasSuffix("%") {
                // 2-byte signed element (little-endian). GIVAYF's signed
                // interpretation is correct: % values are signed in BASIC.
                emit("    lda _arr_ptr_lo"); emit("    sta $FD")
                emit("    lda _arr_ptr_hi"); emit("    sta $FE")
                emit("    ldy #1")
                emit("    lda ($FD),y")     // hi
                emit("    pha")
                emit("    dey")
                emit("    lda ($FD),y")     // lo
                emit("    tay")
                emit("    pla")             // A = hi, Y = lo
                emit("    jsr \(ROM.INTFAC)")
            } else {
                emit("    lda _arr_ptr_lo"); emit("    ldy _arr_ptr_hi"); emit("    jsr \(ROM.MOVFM)")
            }
        }
    }

    private mutating func genFuncCallToFloat(fn: String, args: [Expr]) {
        switch fn {
        case "PEEK":
            if !args.isEmpty {
                genExprToWord(args[0]); emit("    sta _peek_lo"); emit("    stx _peek_hi")
                emit("    jsr _rt_peek_byte"); emit("    tay"); emit("    lda #0"); emit("    jsr \(ROM.INTFAC)")
            }
        case "ABS":    if !args.isEmpty { genExprToFloat(args[0]); emit("    jsr \(ROM.ABS)") }
        case "INT":    if !args.isEmpty { genExprToFloat(args[0]); emit("    jsr \(ROM.INT)") }
        case "SGN":    if !args.isEmpty { genExprToFloat(args[0]); emit("    jsr \(ROM.SGN)") }
        case "SQR":    if !args.isEmpty { genExprToFloat(args[0]); emit("    jsr \(ROM.SQR)") }
        case "SIN":    if !args.isEmpty { genExprToFloat(args[0]); emit("    jsr \(ROM.SIN)") }
        case "COS":    if !args.isEmpty { genExprToFloat(args[0]); emit("    jsr \(ROM.COS)") }
        case "TAN":    if !args.isEmpty { genExprToFloat(args[0]); emit("    jsr \(ROM.TAN)") }
        case "ATN":    if !args.isEmpty { genExprToFloat(args[0]); emit("    jsr \(ROM.ATN)") }
        case "EXP":    if !args.isEmpty { genExprToFloat(args[0]); emit("    jsr \(ROM.EXP)") }
        case "LOG":    if !args.isEmpty { genExprToFloat(args[0]); emit("    jsr \(ROM.LOG)") }
        case "RND":    if !args.isEmpty { genExprToFloat(args[0]); emit("    jsr \(ROM.RND)") }
        case "VAL":
            if !args.isEmpty {
                genStrPtr(args[0]); emit("    lda $FB"); emit("    sta $22")
                emit("    lda $FC"); emit("    sta $23"); emit("    jsr _rt_strlen"); emit("    sta $24")
                emit("    jsr \(ROM.VAL)")
            }
        case "FRE":
            // ROM FRE ($B37D) garbage-collects using BASIC's string
            // pointers ($31-$34), which are stale leftovers in a compiled
            // program - calling it could scan arbitrary memory. Report the
            // real free space instead: the gap between the end of the
            // compiled image and the BASIC ROM at $A000, computed by ca65.
            if !args.isEmpty { genExprToFloat(args[0]) }   // arg may have side effects (e.g. FRE(RND(1)))
            emit("    lda #>($A000 - _image_end)")
            emit("    ldy #<($A000 - _image_end)")
            emit("    jsr _rt_uword_to_fac")
        case "POS":    emit("    lda $D3"); emit("    tay"); emit("    lda #0"); emit("    jsr \(ROM.INTFAC)")
        case "LEN":
            if !args.isEmpty { genStrPtr(args[0]); emit("    jsr _rt_strlen"); emit("    tay"); emit("    lda #0"); emit("    jsr \(ROM.INTFAC)") }
        case "ASC":
            if !args.isEmpty { genStrPtr(args[0]); emit("    ldy #0"); emit("    lda ($FB),y"); emit("    tay"); emit("    lda #0"); emit("    jsr \(ROM.INTFAC)") }
        case "STR$", "CHR$", "LEFT$", "RIGHT$", "MID$":
            break
        case "TI":     genExprToFloat(.tiVar)
        case "ST":     genExprToFloat(.stVar)
        default:
            if fn.hasPrefix("FN"), let def = userFunctions[String(fn.dropFirst(2))] {
                genUserFn(def: def, arg: args.first ?? .intLit(0))
            } else {
                warn("unimplemented function: \(fn)")
            }
        }
    }

    private mutating func genUserFn(def: (param: String, body: Expr), arg: Expr) {
        let tmp = "fn_arg_\(labelCounter)"
        labelCounter += 1
        genExprToFloat(arg)
        emit("    ldx #<var_\(tmp)"); emit("    ldy #>var_\(tmp)")
        emit("    jsr \(ROM.MOVMF)")
        let substituted = substituteVar(def.param, with: tmp, in: def.body)
        genExprToFloat(substituted)
        emitFloatConst("var_\(tmp)", 0.0)
    }

    private func substituteVar(_ from: String, with to: String, in expr: Expr) -> Expr {
        switch expr {
        case .floatVar(let n) where n == from: return .floatVar(to)
        case .binaryOp(let op, let l, let r): return .binaryOp(op, substituteVar(from, with: to, in: l), substituteVar(from, with: to, in: r))
        case .compareOp(let op, let l, let r): return .compareOp(op, substituteVar(from, with: to, in: l), substituteVar(from, with: to, in: r))
        case .unaryMinus(let e): return .unaryMinus(substituteVar(from, with: to, in: e))
        case .notOp(let e): return .notOp(substituteVar(from, with: to, in: e))
        case .funcCall(let fn, let args): return .funcCall(fn, args.map { substituteVar(from, with: to, in: $0) })
        default: return expr
        }
    }

    // MARK: - String Pointer Helper
    private mutating func genStrPtr(_ expr: Expr) {
        switch expr {
        case .strLit(let s):
            let lbl = newLabel("slit")
            emitStringData(lbl, s)
            emit("    lda #<\(lbl)"); emit("    sta $FB")
            emit("    lda #>\(lbl)"); emit("    sta $FC")
        case .strVar(let name):
            emit("    lda #<var_\(asm(name))"); emit("    sta $FB")
            emit("    lda #>var_\(asm(name))"); emit("    sta $FC")
        case .arrayRead(let name, let idxs) where name.hasSuffix("$"):
            // String array element: the element pointer IS the string
            // pointer (256-byte null-terminated slots). Previously
            // unhandled, so PRINT A$(I) fell into the float path and
            // printed a 5-byte reinterpretation of the text. Modern art,
            // but not what anyone asked for.
            if let off = constArrayByteOffset(name: name, indices: idxs) {
                emit("    lda #<(arr_\(asm(name))+\(off))"); emit("    sta $FB")
                emit("    lda #>(arr_\(asm(name))+\(off))"); emit("    sta $FC")
                break
            }
            genArrayElementPtr(name: name, indices: idxs)
            emit("    lda _arr_ptr_lo"); emit("    sta $FB")
            emit("    lda _arr_ptr_hi"); emit("    sta $FC")
        case .binaryOp("+", _, _):
            // String concatenation: flatten the left-leaning + chain the
            // parser builds and append each part into _str_cat_buf. Each
            // part is evaluated and appended immediately, so parts may use
            // the slice/STR$ scratch buffers freely. Result capped at 255
            // characters (BASIC's own string limit).
            var parts: [Expr] = []
            var node = expr
            while case .binaryOp("+", let l, let r) = node {
                parts.insert(r, at: 0)
                node = l
            }
            parts.insert(node, at: 0)
            emit("    lda #0")
            emit("    sta _cat_len")
            for part in parts {
                if containsStringConcat(part) {
                    // A part whose own subtree concatenates (e.g.
                    // LEFT$(A$+B$,3) as an operand) would reset the cat
                    // buffer mid-build. Diagnose instead of corrupting.
                    warn("nested string concatenation inside a function argument is not supported; skipped")
                    continue
                }
                genStrPtr(part)
                emit("    jsr _rt_cat_append")
            }
            emit("    lda #<_str_cat_buf"); emit("    sta $FB")
            emit("    lda #>_str_cat_buf"); emit("    sta $FC")
        case .funcCall("CHR$", let args) where !args.isEmpty:
            genExprToByte(args[0]); emit("    sta _chr_buf")
            emit("    lda #0"); emit("    sta _chr_buf+1")
            emit("    lda #<_chr_buf"); emit("    sta $FB")
            emit("    lda #>_chr_buf"); emit("    sta $FC")
        case .funcCall(let fn, let args) where ["LEFT$","RIGHT$","MID$"].contains(fn):
            genStrSlice(fn, args: args)
            emit("    lda #<_str_slice_buf"); emit("    sta $FB")
            emit("    lda #>_str_slice_buf"); emit("    sta $FC")
        case .funcCall("STR$", let args) where !args.isEmpty:
            genExprToFloat(args[0]); emit("    jsr _rt_str_from_fac")
            emit("    sta $FB"); emit("    sty $FC")
        default:
            warn("cannot take a string pointer of this expression; result undefined")
        }
    }

    /// Does any subtree perform string concatenation? Used to reject the
    /// one shape the single-buffer concat scheme cannot handle.
    private func containsStringConcat(_ e: Expr) -> Bool {
        switch e {
        case .binaryOp("+", let l, let r):
            if exprIsString(l) || exprIsString(r) { return true }
            return containsStringConcat(l) || containsStringConcat(r)
        case .binaryOp(_, let l, let r), .compareOp(_, let l, let r):
            return containsStringConcat(l) || containsStringConcat(r)
        case .unaryMinus(let inner), .notOp(let inner):
            return containsStringConcat(inner)
        case .funcCall(_, let args):
            return args.contains { containsStringConcat($0) }
        case .arrayRead(_, let idxs):
            return idxs.contains { containsStringConcat($0) }
        default:
            return false
        }
    }

    private mutating func genStrSlice(_ fn: String, args: [Expr]) {
        guard !args.isEmpty else { return }
        genStrPtr(args[0])
        emit("    lda $FB"); emit("    sta _str_src_lo")
        emit("    lda $FC"); emit("    sta _str_src_hi")
        switch fn {
        case "LEFT$":
            emit("    lda #0"); emit("    sta _str_slice_start")
            if args.count > 1 { genExprToByte(args[1]) } else { emit("    lda #255") }
            emit("    sta _str_slice_len")
        case "RIGHT$":
            emit("    jsr _rt_strlen")
            if args.count > 1 {
                emit("    sta _str_tmp"); genExprToByte(args[1]); emit("    sta _arith_tmp")
                emit("    lda _str_tmp"); emit("    sec"); emit("    sbc _arith_tmp")
                // Count > length borrows and wrapped the start to ~253,
                // reading garbage; BASIC returns the whole string.
                let ok = newLabel("rgc")
                emit("    bcs \(ok)")
                emit("    lda #0")
                emit("\(ok):")
                emit("    sta _str_slice_start")
                emit("    lda _arith_tmp"); emit("    sta _str_slice_len")
            } else {
                emit("    lda #0"); emit("    sta _str_slice_start")
                emit("    lda #255"); emit("    sta _str_slice_len")
            }
        case "MID$":
            if args.count > 1 {
                genExprToByte(args[1])
                // MID$ position is 1-based; 0 underflowed to offset 255.
                // The interpreter errors — clamping to 1 is the closest
                // non-aborting behavior.
                let ok = newLabel("mps")
                emit("    cmp #1")
                emit("    bcs \(ok)")
                emit("    lda #1")
                emit("\(ok):")
                emit("    sec"); emit("    sbc #1"); emit("    sta _str_slice_start")
            }
            if args.count > 2 { genExprToByte(args[2]); emit("    sta _str_slice_len") }
            else { emit("    lda #255"); emit("    sta _str_slice_len") }
        default: break
        }
        emit("    jsr _rt_str_slice")
    }

    // MARK: - Float Load/Store Helpers
    private mutating func genLoadFloat(_ name: String) {
        emit("    lda #<var_\(asm(name))"); emit("    ldy #>var_\(asm(name))"); emit("    jsr \(ROM.MOVFM)")
    }
    private mutating func genStoreFloat(_ name: String) {
        emit("    ldx #<var_\(asm(name))"); emit("    ldy #>var_\(asm(name))"); emit("    jsr \(ROM.MOVMF)")
    }
    private mutating func genStoreFloatNamed(_ label: String) {
        emit("    ldx #<\(label)"); emit("    ldy #>\(label)"); emit("    jsr \(ROM.MOVMF)")
    }
    private mutating func genLoadFloatNamed(_ label: String) {
        emit("    lda #<\(label)"); emit("    ldy #>\(label)"); emit("    jsr \(ROM.MOVFM)")
    }

    // MARK: - Helpers
    private mutating func emit(_ line: String) { output.append(line) }
    /// Records a diagnostic AND leaves a breadcrumb in the assembly output.
    private mutating func warn(_ message: String) {
        warnings.append(message)
        emit("    ; WARNING: \(message)")
    }
    private mutating func newLabel(_ prefix: String = "L") -> String {
        labelCounter += 1
        return "\(prefix)_\(labelCounter)"
    }
    private func lineLabel(_ n: Int) -> String { lineLabels[n] ?? "line_\(n)" }
    private func asm(_ name: String) -> String {
        name.replacingOccurrences(of: "$", with: "_str")
            .replacingOccurrences(of: "%", with: "_int")
            .map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" }
            .map(String.init).joined()
    }
    private func hex(_ n: Int) -> String { String(format: "$%04X", n) }

    private func constByteValue(_ expr: Expr) -> Int? {
        if case .intLit(let n) = expr, n >= 0, n <= 255 { return n }
        return nil
    }
    /// Compile-time integer value of an expression, negatives included
    /// (STEP -1 parses as unaryMinus(intLit(1))). Float literals qualify
    /// when integral.
    private func constIntValue(_ e: Expr) -> Int? {
        switch e {
        case .intLit(let n): return n
        case .floatLit(let f):
            guard f == f.rounded(.towardZero), abs(f) <= 65536 else { return nil }
            return Int(f)
        case .unaryMinus(let inner):
            guard let v = constIntValue(inner) else { return nil }
            return -v
        default: return nil
        }
    }

    private func constWordValue(_ expr: Expr) -> Int? {
        guard let v = constIntValue(expr), v >= 0, v <= 65535 else { return nil }
        return v
    }

    /// Conservatively: could this word-context expression hold a negative
    /// value? Gates the fast unsigned divide: for non-negative operands,
    /// unsigned integer division and BASIC's floor agree exactly; for
    /// negative ones they differ (-7/2 floors to -4, truncates to -3), so
    /// possibly-signed operands keep the float path.
    private func exprMaybeSigned(_ e: Expr) -> Bool {
        switch e {
        case .intLit(let n): return n < 0
        case .floatLit(let f): return f < 0
        case .strLit, .strVar: return false
        case .intVar: return true                       // % vars are signed
        case .tiVar, .stVar: return false
        case .floatVar(let name):
            if name == "TI" || name == "ST" { return false }
            return table[name].width == .float || table[name].isSigned
        case .unaryMinus, .notOp, .compareOp: return true
        case .binaryOp("-", _, _): return true          // may underflow
        case .binaryOp("+", let l, let r),
             .binaryOp("*", let l, let r),
             .binaryOp("/", let l, let r),
             .binaryOp("AND", let l, let r),
             .binaryOp("OR", let l, let r):
            return exprMaybeSigned(l) || exprMaybeSigned(r)
        case .binaryOp: return true
        case .arrayRead: return true                    // element sign unknown
        case .funcCall(let fn, _):
            return !["PEEK", "LEN", "ASC", "POS", "FRE", "RND", "ABS", "SQR"].contains(fn)
        }
    }

    /// Byte offset into an array's storage for an access whose subscripts
    /// are all compile-time constants, or nil to use runtime indexing.
    /// Mirrors genArrayElementPtr's row-major math exactly.
    private mutating func constArrayByteOffset(name: String, indices: [Expr]) -> Int? {
        guard let dims = arrayDims.first(where: { $0.name == name })?.dims,
              indices.count == dims.count else { return nil }
        let bpe = Self.bytesPerElement(for: name)
        var total = 0
        for (i, idx) in indices.enumerated() {
            guard let v = constIntValue(idx), v >= 0 else { return nil }
            guard v < dims[i] else {
                warn("\(name): constant subscript \(v) out of range (max \(dims[i] - 1)); using runtime indexing")
                return nil
            }
            if i > 0 { total *= dims[i] }
            total += v
        }
        return total * bpe
    }
    private func exprWidth(_ expr: Expr) -> NumWidth? {
        switch expr {
        case .intLit(let n):
            if n >= 0 && n <= 255 { return .byte }
            if n <= 65535 { return .word }
            return .float
        case .floatLit: return .float
        case .floatVar(let name): return table[name].width
        case .intVar(let name): return table[name].width
        case .funcCall("PEEK", _): return .byte
        case .funcCall("ASC", _):  return .byte
        case .funcCall("LEN", _):  return .word
        default: return nil
        }
    }
    private func exprIsString(_ expr: Expr) -> Bool {
        switch expr {
        case .strLit, .strVar: return true
        case .arrayRead(let name, _): return name.hasSuffix("$")
        case .binaryOp("+", let l, let r): return exprIsString(l) || exprIsString(r)
        case .funcCall(let fn, _): return ["CHR$","LEFT$","RIGHT$","MID$","STR$"].contains(fn)
        default: return false
        }
    }

    // MARK: - Runtime Library
    private mutating func emitRuntime() {
        emit("")
        emit("; ════════════════════════════════════════")
        emit("; Runtime support routines")
        emit("; ════════════════════════════════════════")
        emit("")

        emit("_print_str:")
        emit("    sta $FB"); emit("    sty $FC"); emit("    ldy #0")
        emit("_ps_loop:")
        emit("    lda ($FB),y"); emit("    beq _ps_done")
        emit("    jsr \(KERNAL.CHROUT)"); emit("    iny"); emit("    bne _ps_loop")
        emit("_ps_done:"); emit("    rts")
        emit("")

        emit("_rt_peek_byte:")
        // Reads through the normal $37 memory view, exactly like the
        // interpreter's PEEK: ROM at $A000-$BFFF/$E000-$FFFF, I/O at
        // $D000. (The old version banked to $35 and read RAM under the
        // ROMs, a silent deviation, and its SEI window left NMI fetching
        // its vector from banked-out memory.)
        emit("    lda _peek_lo"); emit("    sta @pk+1")
        emit("    lda _peek_hi"); emit("    sta @pk+2")
        emit("@pk:"); emit("    lda $0000")
        emit("    rts")
        emit("")

        emit("_rt_poke:")
        // Writes always reach RAM regardless of $01; I/O at $D000 is
        // visible under $37. No banking required.
        emit("    lda _poke_lo"); emit("    sta @pk+1")
        emit("    lda _poke_hi"); emit("    sta @pk+2")
        emit("    lda _poke_val")
        emit("@pk:"); emit("    sta $0000")
        emit("    rts")
        emit("")

        emit("_rt_sys:")
        emit("    lda _sys_lo"); emit("    sta @sj+1")
        emit("    lda _sys_hi"); emit("    sta @sj+2")
        emit("@sj:"); emit("    jsr $0000"); emit("    rts")
        emit("")

        emit("_rt_fac_to_byte:")
        emit("    lda $61"); emit("    beq @zero")
        emit("    lda $66"); emit("    bmi @neg")
        emit("    jsr \(ROM.FACINT)"); emit("    tya"); emit("    rts")
        emit("@neg:")
        emit("    jsr \(ROM.NEGFAC)"); emit("    jsr \(ROM.FACINT)")
        emit("    tya"); emit("    eor #$FF"); emit("    clc"); emit("    adc #1"); emit("    rts")
        emit("@zero:"); emit("    lda #0"); emit("    rts")
        emit("")

        // Unsigned 16-bit (A=hi, Y=lo) -> FAC. GIVAYF interprets its input
        // as SIGNED, so values with bit 15 set come back 65536 too low;
        // add the correction constant when that happens.
        emitFloatConst("_flt_65536", 65536.0)
        emit("_rt_uword_to_fac:")
        emit("    sta _word_tmp")
        emit("    jsr \(ROM.INTFAC)")
        emit("    lda _word_tmp")
        emit("    bpl @uw_done")
        emit("    lda #<_flt_65536")
        emit("    ldy #>_flt_65536")
        emit("    jsr \(ROM.FADD)")
        emit("@uw_done:")
        emit("    rts")
        emit("")

        emit("_rt_strlen:")
        emit("    ldy #0"); emit("@sl:")
        emit("    lda ($FB),y"); emit("    beq @sl_done"); emit("    iny"); emit("    bne @sl")
        emit("@sl_done:"); emit("    tya"); emit("    rts")
        emit("")

        emit("_rt_strcmp:")
        emit("    lda _str_src_lo"); emit("    sta $FD")
        emit("    lda _str_src_hi"); emit("    sta $FE")
        emit("    ldy #0"); emit("@sc:")
        emit("    lda ($FD),y"); emit("    sta _str_tmp")
        emit("    lda ($FB),y"); emit("    cmp _str_tmp"); emit("    bne @sc_ne")
        emit("    lda _str_tmp"); emit("    beq @sc_eq")
        emit("    iny"); emit("    bne @sc")
        emit("@sc_eq:"); emit("    lda #0"); emit("    rts")
        emit("@sc_ne:")
        // Return an explicit $FF / $01 order flag. The old 8-bit char
        // difference flipped sign when the differing PETSCII codes were
        // more than 127 apart (e.g. shifted/graphics chars vs letters).
        emit("    lda _str_tmp")
        emit("    cmp ($FB),y")
        emit("    bcs @sc_gt")
        emit("    lda #$FF"); emit("    rts")
        emit("@sc_gt:")
        emit("    lda #1"); emit("    rts")
        emit("")

        emit("_rt_strcmp_lhs:")
        // Copies the string at ($FB) into the compare-private LHS buffer
        // and points _str_src at the copy, so evaluating the comparison's
        // right side can freely reuse _chr_buf/_str_slice_buf/_str_cat_buf.
        emit("    ldy #0"); emit("@scl:")
        emit("    lda ($FB),y"); emit("    sta _strcmp_lhs_buf,y")
        emit("    beq @scl_done")
        emit("    iny"); emit("    bne @scl")
        emit("@scl_done:")
        emit("    lda #<_strcmp_lhs_buf"); emit("    sta _str_src_lo")
        emit("    lda #>_strcmp_lhs_buf"); emit("    sta _str_src_hi")
        emit("    rts")
        emit("")

        emit("_rt_cat_append:")
        // Appends the null-terminated string at ($FB) to _str_cat_buf at
        // offset _cat_len, capping the total at 255 characters (BASIC's
        // own string length limit) and keeping the terminator intact.
        emit("    ldy #0")
        emit("    ldx _cat_len")
        emit("@ca:")
        emit("    lda ($FB),y")
        emit("    beq @ca_done")
        emit("    sta _str_cat_buf,x")
        emit("    inx")
        emit("    beq @ca_full")            // wrapped past 255: stop
        emit("    iny")
        emit("    bne @ca")
        emit("@ca_full:")
        emit("    dex")                     // back to 255 for the terminator
        emit("@ca_done:")
        emit("    lda #0")
        emit("    sta _str_cat_buf,x")
        emit("    stx _cat_len")
        emit("    rts")
        emit("")

        emit("_rt_str_slice:")
        emit("    lda _str_src_lo"); emit("    sta $FB")
        emit("    lda _str_src_hi"); emit("    sta $FC")
        // Clamp start to the actual length: MID$(A$,10,...) on a 2-char
        // string used to point past the terminator and copy whatever
        // followed in memory until a stray zero.
        emit("    jsr _rt_strlen")
        emit("    cmp _str_slice_start")
        emit("    bcs @ss_stok")
        emit("    sta _str_slice_start")
        emit("@ss_stok:")
        emit("    lda $FB"); emit("    clc"); emit("    adc _str_slice_start"); emit("    sta $FB")
        emit("    lda $FC"); emit("    adc #0"); emit("    sta $FC")
        emit("    ldy #0"); emit("    ldx _str_slice_len")
        emit("@ss:"); emit("    cpx #0"); emit("    beq @ss_done")
        emit("    lda ($FB),y"); emit("    beq @ss_done")
        emit("    sta _str_slice_buf,y"); emit("    iny"); emit("    dex"); emit("    jmp @ss")
        emit("@ss_done:"); emit("    lda #0"); emit("    sta _str_slice_buf,y"); emit("    rts")
        emit("")

        emit("_rt_str_from_fac:")
        // FOUT builds a null-terminated ASCII string at $0100 (sign or
        // space first, matching BASIC's STR$ which includes the leading
        // space for positive numbers). It does NOT return a length in any
        // register, so copy until the terminator.
        emit("    jsr \(ROM.FOUT)")
        emit("    ldy #0")
        emit("@sf:")
        emit("    lda $0100,y"); emit("    sta _str_slice_buf,y")
        emit("    beq @sf_done")
        emit("    iny"); emit("    bne @sf")
        emit("@sf_done:")
        emit("    lda #<_str_slice_buf"); emit("    ldy #>_str_slice_buf"); emit("    rts")
        emit("")

        emit("_rt_input_str:")
        emit("    sta $FB"); emit("    sty $FC"); emit("    ldy #0"); emit("    lda #0")
        emit("    sta $CC"); emit("@is:")
        emit("    jsr $FFCF"); emit("    cmp #$0D"); emit("    beq @is_done")
        emit("    cmp #$14"); emit("    beq @is_bs"); emit("    cmp #$00"); emit("    beq @is")
        emit("    cpy #254"); emit("    bcs @is")
        emit("    sta ($FB),y"); emit("    iny"); emit("    jmp @is")
        emit("@is_bs:")
        emit("    cpy #0"); emit("    beq @is"); emit("    dey"); emit("    jmp @is")
        emit("@is_done:")
        emit("    lda #1"); emit("    sta $CC"); emit("    lda #$20"); emit("    jsr \(KERNAL.CHROUT)")
        emit("    lda #$14"); emit("    jsr \(KERNAL.CHROUT)")
        emit("    lda #0"); emit("    sta ($FB),y"); emit("    lda #$0D"); emit("    jsr \(KERNAL.CHROUT)")
        emit("    rts")
        emit("")

        emit("_rt_input_num:")
        emit("    lda #<_input_buf"); emit("    ldy #>_input_buf"); emit("    jsr _rt_input_str")
        emit("    lda #<_input_buf"); emit("    sta $22"); emit("    sta $FB")
        emit("    lda #>_input_buf"); emit("    sta $23"); emit("    sta $FC")
        emit("    jsr _rt_strlen"); emit("    sta $24"); emit("    jsr \(ROM.VAL)")
        emit("    rts")
        emit("")

        emit("_rt_input_num_int:")
        // AYINT is the SIGNED conversion (range -32768..32767); the old
        // FACINT/GETADR path threw ILLEGAL QUANTITY the moment the user
        // typed a minus sign. AYINT leaves hi at $64, lo at $65.
        emit("    jsr _rt_input_num"); emit("    jsr \(ROM.AYINT)")
        emit("    lda $65"); emit("    sta _input_lo")
        emit("    lda $64"); emit("    sta _input_hi"); emit("    rts")
        emit("")

        emit("_rt_char_to_digit:")
        // Interpreter semantics for numeric GET: 0 for no key, digit value
        // for '0'-'9', ?SYNTAX ERROR (program stop) for anything else.
        emit("    cmp #0")
        emit("    beq @cd_done")
        emit("    cmp #$30")
        emit("    bcc @cd_err")
        emit("    cmp #$3A")
        emit("    bcs @cd_err")
        emit("    and #$0F")
        emit("@cd_done:")
        emit("    rts")
        emit("@cd_err:")
        // Restore default channels before aborting: a GET# reaches this
        // with the input channel still redirected to a file/serial device,
        // and warm-starting in that state leaves READY reading from the
        // disk instead of the keyboard. For plain GET the defaults are
        // already active and CLRCHN is a harmless no-op.
        emit("    jsr \(KERNAL.CLRCHN)")
        emit("    jmp _program_end")
        emit("")

        emit("_rt_num_sep:")
        // Character printed after every number: cursor-right on the screen
        // (device 3), space when output is redirected (PRINT# or CMD).
        emit("    lda $9A")
        emit("    cmp #3")
        emit("    bne @ns_file")
        emit("    lda #$1D")
        emit("    jmp \(KERNAL.CHROUT)")
        emit("@ns_file:")
        emit("    lda #$20")
        emit("    jmp \(KERNAL.CHROUT)")
        emit("")

        emit("_rt_tab:")
        // TAB(n) positions the next character at column n (0-based),
        // matching the interpreter. The old version targeted n-1.
        emit("    sta _str_tmp")
        emit("@tl:")
        emit("    lda $D3")
        emit("    cmp _str_tmp")
        emit("    bcs @done")
        emit("    lda #$20")
        emit("    jsr \(KERNAL.CHROUT)")
        emit("    jmp @tl")
        emit("@done:"); emit("    rts")
        emit("")

        emit("_rt_spc:")
        // tax first: the entry flags belong to the CALLER's last
        // instruction, which for word-result expressions describes the
        // high byte in X, not A (SPC(I*2) with a product of 256 printed
        // 256 spaces). tax re-derives Z from A.
        emit("    tax"); emit("    beq @done"); emit("@sl: lda #$20")
        emit("jsr \(KERNAL.CHROUT)"); emit("dex"); emit("bne @sl")
        emit("@done:"); emit("    rts")
        emit("")

        emit("_rt_tab_to_next_col:")
        emit("    lda $D3"); emit("@m: cmp #10"); emit("bcc @g")
        emit("sbc #10"); emit("jmp @m"); emit("@g: sta _str_tmp")
        emit("lda #10"); emit("sec"); emit("sbc _str_tmp")
        emit("    jsr _rt_spc"); emit("    rts")
        emit("")

        if needsMul16 {
            // 16 x 16 -> low 16 bits, MSB-first shift-add.
            // ~350 cycles average vs ~2000+ for the float round trip.
            emit("_rt_mul16:")
            emit("    lda #0")
            emit("    sta _mul_r")
            emit("    sta _mul_r+1")
            emit("    ldy #16")
            emit("@ml:")
            emit("    asl _mul_r")
            emit("    rol _mul_r+1")
            emit("    asl _mul_b")
            emit("    rol _mul_b+1")
            emit("    bcc @ms")
            emit("    lda _mul_r")
            emit("    clc")
            emit("    adc _mul_a")
            emit("    sta _mul_r")
            emit("    lda _mul_r+1")
            emit("    adc _mul_a+1")
            emit("    sta _mul_r+1")
            emit("@ms:")
            emit("    dey")
            emit("    bne @ml")
            emit("    lda _mul_r")
            emit("    ldx _mul_r+1")
            emit("    rts")
            emit("")
        }

        if needsDiv16 {
            // Unsigned 16 / 16 restoring division. Quotient bits build in
            // _div_n as it shifts out; remainder tracks in _div_r. The
            // @force branch handles the 17-bit case (rol pushed remainder
            // bit 16 into carry, so the subtract is guaranteed and sbc
            // starts with C=1 from that same rol).
            emit("_rt_div16:")
            emit("    lda _div_d")
            emit("    ora _div_d+1")
            emit("    bne @dv")
            emit("    jmp _program_end")  // ?DIVISION BY ZERO
            emit("@dv:")
            emit("    lda #0")
            emit("    sta _div_r")
            emit("    sta _div_r+1")
            emit("    ldy #16")
            emit("@dl:")
            emit("    asl _div_n")
            emit("    rol _div_n+1")
            emit("    rol _div_r")
            emit("    rol _div_r+1")
            emit("    bcs @force")
            emit("    sec")
            emit("    lda _div_r")
            emit("    sbc _div_d")
            emit("    tax")
            emit("    lda _div_r+1")
            emit("    sbc _div_d+1")
            emit("    bcc @dn")
            emit("    bcs @store")
            emit("@force:")
            emit("    lda _div_r")
            emit("    sbc _div_d")
            emit("    tax")
            emit("    lda _div_r+1")
            emit("    sbc _div_d+1")
            emit("@store:")
            emit("    sta _div_r+1")
            emit("    stx _div_r")
            emit("    inc _div_n")
            emit("@dn:")
            emit("    dey")
            emit("    bne @dl")
            emit("    lda _div_n")
            emit("    ldx _div_n+1")
            emit("    rts")
            emit("")
        }

        if needsWideByteData {
            // Byte-table fetch with full 16-bit indexing, for DATA
            // tables longer than 256 bytes. Returns the item in A and
            // advances _data_ptr with carry into the high byte. The
            // Y-indexed inline path can't be used past 256 entries
            // because both ldy and inc only touch the pointer's low
            // byte, wrapping the read position back to item 0.
            emit("_rt_data_get_byte:")
            emit("    lda _data_ptr")
            emit("    clc")
            emit("    adc #<_data_table")
            emit("    sta $FD")
            emit("    lda _data_ptr+1")
            emit("    adc #>_data_table")
            emit("    sta $FE")
            emit("    inc _data_ptr")
            emit("    bne @nw")
            emit("    inc _data_ptr+1")
            emit("@nw:")
            emit("    ldy #0")
            emit("    lda ($FD),y")
            emit("    rts")
            emit("")
        }

        if dataHasString {
            emit("_rt_data_read_str:")
            emit("    sta $FB"); emit("    sty $FC")
            emit("    lda _data_ptr"); emit("    clc"); emit("    adc #<_data_table"); emit("    sta $FD")
            emit("    lda _data_ptr+1"); emit("    adc #>_data_table"); emit("    sta $FE")
            emit("    ldy #0"); emit("    lda ($FD),y"); emit("    cmp #$03"); emit("    bne @tymm")
            emit("    iny"); emit("    lda ($FD),y"); emit("    sta _str_tmp")
            emit("    lda $FD"); emit("    clc"); emit("    adc #2"); emit("    sta $FD")
            emit("    bcc @s1"); emit("    inc $FE"); emit("@s1:")
            emit("    ldy #0"); emit("@cp:")
            emit("    cpy _str_tmp"); emit("    beq @cdn")
            emit("    lda ($FD),y"); emit("    sta ($FB),y"); emit("    iny"); emit("    bne @cp")
            emit("@cdn:")
            emit("    lda #0"); emit("    sta ($FB),y")
            emit("    lda _data_ptr"); emit("    clc"); emit("    adc #2"); emit("    sta _data_ptr")
            emit("    bcc @s2"); emit("    inc _data_ptr+1"); emit("@s2:")
            emit("    lda _data_ptr"); emit("    clc"); emit("    adc _str_tmp"); emit("    sta _data_ptr")
            emit("    bcc @s3"); emit("    inc _data_ptr+1"); emit("@s3:")
            emit("    rts"); emit("@tymm:"); emit("    jmp _program_end")
            emit("")

            // Numeric READ from the tagged stream. Dispatches on the tag
            // byte, converts the item into FAC1 (GIVAYF for byte/word,
            // MOVFM for float), then advances _data_ptr by the item's
            // total encoded size including the tag. The caller stores
            // from FAC1 based on the target variable's analysed width.
            // Tag $03 (string) under a numeric READ is a type mismatch:
            // stop the program, same as _rt_data_read_str's @tymm.
            emit("_rt_data_read_num:")
            emit("    lda _data_ptr"); emit("    clc"); emit("    adc #<_data_table"); emit("    sta $FD")
            emit("    lda _data_ptr+1"); emit("    adc #>_data_table"); emit("    sta $FE")
            emit("    ldy #0"); emit("    lda ($FD),y")
            emit("    beq @byte")                       // tag $00
            emit("    cmp #$01"); emit("    beq @word") // tag $01
            emit("    cmp #$02"); emit("    beq @float")// tag $02
            emit("    jmp _program_end")                // tag $03: mismatch
            emit("@byte:")
            emit("    iny"); emit("    lda ($FD),y")    // value byte
            emit("    tay")                             // Y = lo
            emit("    lda #0")                          // A = hi (0..255 fits signed 16-bit)
            emit("    jsr \(ROM.INTFAC)")               // GIVAYF: A/Y -> FAC1
            emit("    lda #2")                          // advance: tag + 1
            emit("    bne @adv")                        // always (A != 0)
            emit("@word:")
            emit("    ldy #2"); emit("    lda ($FD),y") // hi byte
            emit("    tax")
            emit("    dey"); emit("    lda ($FD),y")    // lo byte
            emit("    tay")                             // Y = lo
            emit("    txa")                             // A = hi
            emit("    jsr \(ROM.INTFAC)")
            emit("    lda #3")                          // advance: tag + 2
            emit("    bne @adv")                        // always
            emit("@float:")
            emit("    ldy $FE")                         // MOVFM wants A=lo, Y=hi
            emit("    lda $FD")
            emit("    clc")
            emit("    adc #1")                          // skip the tag byte
            emit("    bcc @f1")
            emit("    iny")
            emit("@f1:")
            emit("    jsr \(ROM.MOVFM)")
            emit("    lda #6")                          // advance: tag + 5
            emit("@adv:")
            emit("    clc")
            emit("    adc _data_ptr")
            emit("    sta _data_ptr")
            emit("    bcc @nd")
            emit("    inc _data_ptr+1")
            emit("@nd:")
            emit("    rts")
            emit("")
        }

        for line in stringDataSection { emit(line) }
        for line in floatConstSection { emit(line) }
        emit("")

        emit("; ── Scratch storage ──")
        emit("_cmp_tmp:    .res 1"); emit("_cmp_lo:     .res 1"); emit("_cmp_hi:     .res 1")
        emit("_arith_tmp:  .res 1"); emit("_and_tmp:    .res 1"); emit("_xor_tmp:    .res 1")
        emit("_str_tmp:    .res 1")
        if needsMul16 {
            emit("_mul_a:      .res 2"); emit("_mul_b:      .res 2"); emit("_mul_r:      .res 2")
        }
        if needsDiv16 {
            emit("_div_n:      .res 2"); emit("_div_d:      .res 2"); emit("_div_r:      .res 2")
        }
        emit("_word_hi_tmp: .res 1"); emit("_word_tmp:   .res 1"); emit("_poke_val:   .res 1")
        emit("_poke_lo:    .res 1"); emit("_poke_hi:    .res 1"); emit("_peek_lo:    .res 1")
        emit("_peek_hi:    .res 1"); emit("_sys_lo:     .res 1"); emit("_sys_hi:     .res 1")
        emit("_data_ptr:   .word 0"); emit("_chr_buf:    .res 2"); emit("_str_src_lo: .res 1")
        emit("_str_src_hi: .res 1"); emit("_str_slice_start: .res 1"); emit("_str_slice_len:   .res 1")
        emit("_str_slice_buf:   .res 258"); emit("_arr_idx_lo: .res 1"); emit("_arr_idx_hi: .res 1")
        emit("_arr_mul_lo: .res 1"); emit("_arr_mul_hi: .res 1"); emit("_arr_ptr_lo: .res 1")
        emit("_arr_ptr_hi: .res 1"); emit("_open_log:   .res 1"); emit("_open_dev:   .res 1")
        emit("_open_sec:   .res 1"); emit("_input_lo:   .res 1"); emit("_input_hi:   .res 1")
        emit("_input_buf:  .res 256")
        emit("_cat_len:    .res 1"); emit("_ti_buf:     .res 3")
        emit("_str_cat_buf: .res 256")
        emit("_strcmp_lhs_buf: .res 256")

        if dataHasString {
            emit(""); emit("; ── DATA table (tagged stream, \(dataItems.count) items) ──")
            emit("_data_table:")
            for (i, item) in dataItems.enumerated() {
                switch item {
                case .byte(let b):
                    emit("    .byte $00, \(b)   ; DATA[\(i)] = \(b) (byte)")
                case .word(let w):
                    let u = UInt16(bitPattern: Int16(w))
                    let lo = String(format: "$%02X", u & 0xFF)
                    let hi = String(format: "$%02X", (u >> 8) & 0xFF)
                    emit("    .byte $01, \(lo), \(hi)   ; DATA[\(i)] = \(w) (word)")
                case .float(let f):
                    let bytes = encodeC64Float(f)
                    let s = bytes.map { String(format: "$%02X", $0) }.joined(separator: ", ")
                    emit("    .byte $02, \(s)   ; DATA[\(i)] = \(f) (float)")
                case .string(let s):
                    // Same PETSCII mapping as emitStringData: DATA strings
                    // must be byte-identical to string literals or READ
                    // A$ : IF A$="..." can never match.
                    var bytes = s.map { BasicTokenizer.asciiToPetscii($0) }
                    if bytes.count > 255 { bytes = Array(bytes.prefix(255)) }
                    let hex = bytes.map { String(format: "$%02X", $0) }.joined(separator: ", ")
                    let printable = s.replacingOccurrences(of: "\"", with: "\\\"")
                    emit("    .byte $03, \(bytes.count), \(hex)   ; DATA[\(i)] = \"\(printable)\"")
                }
            }
        } else if !dataBytes.isEmpty && dataIsAllByte {
            emit(""); emit("; ── DATA table (\(dataBytes.count) bytes) ──")
            emit("_data_table:")
            for (i, b) in dataBytes.enumerated() { emit("    .byte \(b)    ; DATA[\(i)]") }
        } else if !dataFloats.isEmpty {
            emit(""); emit("; ── DATA table (\(dataFloats.count) floats, \(dataFloats.count * 5) bytes) ──")
            emit("_data_table:")
            for (i, f) in dataFloats.enumerated() {
                let bytes = encodeC64Float(f)
                let s = bytes.map { String(format: "$%02X", $0) }.joined(separator: ", ")
                emit("    .byte \(s)   ; DATA[\(i)] = \(f)")
            }
        } else {
            emit("_data_table:")
        }
    }

    private var stringDataSection: [String] = []
    private var floatConstSection: [String] = []

    private mutating func emitStringData(_ label: String, _ s: String) {
        // Share the tokenizer's PETSCII mapping (Walleij table) instead of
        // masking with & 0x7F, which mangled every non-ASCII character:
        // a pound sign became '#', graphics chars became garbage.
        var bytes = s.map { BasicTokenizer.asciiToPetscii($0) }
        bytes.append(0)
        let hex = bytes.map { String(format: "$%02X", $0) }.joined(separator: ", ")
        stringDataSection.append("\(label): .byte \(hex)")
    }

    /// Labels already present in floatConstSection. Dedup used to be a
    /// linear scan of the whole section per emit, which made compilation
    /// quadratic in program size (5+ seconds at 4000 lines).
    private var emittedConstLabels: Set<String> = []

    private mutating func claimConstLabel(_ label: String) -> Bool {
        emittedConstLabels.insert(label).inserted
    }

    /// Read-only constants deduplicated by value: every occurrence of the
    /// same literal used to emit its own 5-byte MFLPT copy. Scratch slots
    /// that get WRITTEN (wcmp/ftmp/FN param saves) must NOT come through
    /// here - each needs its own storage.
    private var floatConstByValue: [Double: String] = [:]

    private mutating func emitFloatConstValue(_ value: Double) -> String {
        if let existing = floatConstByValue[value] { return existing }
        let lbl = newLabel("flt")
        emitFloatConst(lbl, value)
        floatConstByValue[value] = lbl
        return lbl
    }

    private mutating func emitFloatConst(_ label: String, _ value: Double) {
        guard claimConstLabel(label) else { return }
        let bytes = encodeC64Float(value)
        let hex = bytes.map { String(format: "$%02X", $0) }.joined(separator: ", ")
        floatConstSection.append("\(label): .byte \(hex)  ; = \(value)")
    }

    private mutating func emitFloatScratch(_ label: String) {
        guard claimConstLabel(label) else { return }
        floatConstSection.append("\(label): .res 5")
    }

    private mutating func emitWordScratch(_ label: String) {
        guard claimConstLabel(label) else { return }
        floatConstSection.append("\(label): .res 2")
    }

    private mutating func emitByteScratch(_ label: String) {
        guard claimConstLabel(label) else { return }
        floatConstSection.append("\(label): .res 1")
    }

    /// Encode a Double as a 5-byte C64 float (MFLPT format).
    /// Format: [exponent (bias 129, mantissa normalized to 0.5 up to but
    /// not including 1), mantissa bytes
    /// 1-4]. Mantissa bit 31 is implied 1 and its stored position holds the
    /// sign. Exponent byte 0 means zero.
    ///
    /// The old version computed UInt32(v * 2^32), which TRAPS when v rounds
    /// up to exactly 1.0 in Double (e.g. 0.9999999999999999 after
    /// normalization makes the product 2^32, out of UInt32 range), and it
    /// truncated instead of rounding, losing a bit of accuracy vs the ROM.
    private func encodeC64Float(_ value: Double) -> [UInt8] {
        if value == 0 || !value.isFinite { return [0, 0, 0, 0, 0] }
        let negative = value < 0
        var v = abs(value)
        var exp = 0
        while v >= 1 { v /= 2; exp += 1 }
        while v < 0.5 { v *= 2; exp -= 1 }

        // Round to nearest in 64-bit space, then handle the carry: if the
        // mantissa rounded up to 2^32, renormalize (shift right, bump exp).
        var mantissa64 = UInt64((v * 4294967296.0).rounded())
        if mantissa64 >= 0x1_0000_0000 {
            mantissa64 >>= 1
            exp += 1
        }

        let biased = exp + 128
        if biased < 1 { return [0, 0, 0, 0, 0] }          // underflow -> 0
        var m32: UInt32
        if biased > 255 {                                  // overflow: clamp
            m32 = 0xFFFF_FFFF                              // to largest float
        } else {
            m32 = UInt32(truncatingIfNeeded: mantissa64)
        }
        let expByte = UInt8(clamping: biased)
        if negative { m32 |=  0x8000_0000 }
        else        { m32 &= ~0x8000_0000 }
        return [
            expByte,
            UInt8((m32 >> 24) & 0xFF),
            UInt8((m32 >> 16) & 0xFF),
            UInt8((m32 >>  8) & 0xFF),
            UInt8( m32        & 0xFF)
        ]
    }

    // MARK: - Variable Storage
    private mutating func emitStorage(_ lines: [ParsedLine]) {
        emit(""); emit("; ════════════════════════════════════════")
        emit("; Variable storage")
        emit("; ════════════════════════════════════════")
        let allVars = table.types.keys.sorted()
        var forVarNames: Set<String> = []
        for line in lines {
            for stmt in line.stmts { collectForVars(stmt, into: &forVarNames) }
        }
        let reservedNames: Set<String> = ["TI", "ST", "TI$"]

        emit(""); emit("; ── Scalar variables ──")
        for name in allVars where !reservedNames.contains(name) {
            let typ = table[name]
            switch typ {
            case .string:
                emit("var_\(asm(name)): .res 256   ; \(name) (string)")
            case .numeric(let w, _):
                switch w {
                case .byte:  emit("var_\(asm(name)): .res 1   ; \(name) (byte)")
                case .word:  emit("var_\(asm(name)): .res 2   ; \(name) (word)")
                case .float: emit("var_\(asm(name)): .res 5   ; \(name) (float)")
                }
            }
        }

        if !forVarNames.isEmpty {
            emit(""); emit("; ── FOR loop aux variables ──")
            for name in forVarNames.sorted() {
                let varType = table[name]
                let bytes: Int
                switch varType.width {
                case .byte: bytes = 1
                case .word: bytes = 2
                default:    bytes = 5
                }
                if varType.width == .float {
                    emit("_for_start_\(asm(name)): .res \(bytes)")
                    emit("_for_limit_\(asm(name)): .res \(bytes)")
                    emit("_for_step_\(asm(name)):  .res \(bytes)")
                } else {
                    // Loops with compile-time step/limit never touch
                    // these; emit only what some loop actually stores.
                    if forLimitNeeded.contains(name) {
                        emit("_for_limit_\(asm(name)): .res \(bytes)")
                    }
                    if forStepNeeded.contains(name) {
                        emit("_for_step_\(asm(name)):  .res \(bytes)")
                    }
                }
            }
        }

        if !arrayDims.isEmpty {
            emit(""); emit("; ── Array storage ──")
            for (name, dims) in arrayDims {
                let total = dims.reduce(1, *)
                let bpe = Self.bytesPerElement(for: name)
                let dimStr = dims.map { String($0 - 1) }.joined(separator: ",")
                emit("arr_\(asm(name)): .res \(total * bpe)   ; \(name)(\(dimStr))")
            }
        }

        emit("")
        emit("_image_end:   ; end of the compiled image, used by SAVE")
    }

    private func collectForVars(_ stmt: Stmt, into set: inout Set<String>) {
        switch stmt {
        case .forStmt(let name, _, _, _): set.insert(name)
        case .ifThen(_, let t, let e):
            t.forEach { collectForVars($0, into: &set) }
            e?.forEach { collectForVars($0, into: &set) }
        default: break
        }
    }
}

// MARK: - Compiler Entry Point
struct BasicCompilerV2 {
    static func compile(_ source: String) -> CompileResultV2 {
        var parser = BasicParser()
        // Hardware name identity: only the first two characters (plus
        // suffix) are significant, so SCORE and SCALE must share storage
        // in compiled code exactly as they do in the interpreter. The
        // editor's own analysis path keeps full names for display.
        let lines = BasicNameCanonicalizer.rewrite(parser.parse(source))

        guard !lines.isEmpty else {
            return CompileResultV2(success: false, assembly: nil,
                                   parseErrors: ["No BASIC lines found"],
                                   symbolTable: SymbolTable())
        }

        let symbolTable = BasicTypeAnalyser().analyse(lines)
        var codegen = BasicCodeGen()
        let asm = codegen.compile(lines, symbolTable: symbolTable)

        return CompileResultV2(
            success: parser.errors.isEmpty,
            assembly: asm,
            parseErrors: parser.errors.map(\.description),
            symbolTable: symbolTable,
            warnings: codegen.warnings
        )
    }
}

struct CompileResultV2 {
    let success: Bool
    let assembly: String?
    let parseErrors: [String]
    let symbolTable: SymbolTable
    /// Non-fatal codegen diagnostics (unimplemented features, degraded
    /// constructs). Defaults to empty so existing call sites still build.
    var warnings: [String] = []
}

