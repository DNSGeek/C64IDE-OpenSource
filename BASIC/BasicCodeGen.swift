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

    // First-pass collection:
    private var dataBytes: [UInt8] = []
    private var dataFloats: [Double] = []
    private var dataIsAllByte: Bool = true
    private var stringVarNames: Set<String> = []
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
        stringVarNames = []
        arrayDims = []

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
                    
                    if n >= 0 && n <= 255 && dataIsAllByte {
                        dataBytes.append(UInt8(n))
                    } else {
                        if dataIsAllByte {
                            dataFloats = dataBytes.map { Double($0) }
                            dataBytes = []
                            dataIsAllByte = false
                        }
                        dataFloats.append(Double(n))
                    }
                case .negative(let n):
                    let neg = -n
                    if neg >= -32768 && neg <= 32767 { dataItems.append(.word(neg)) }
                    else { dataItems.append(.float(Double(neg))) }
                    if dataIsAllByte {
                        dataFloats = dataBytes.map { Double($0) }
                        dataBytes = []
                        dataIsAllByte = false
                    }
                    dataFloats.append(Double(neg))
                case .float(let f):
                    dataItems.append(.float(f))
                    if dataIsAllByte {
                        dataFloats = dataBytes.map { Double($0) }
                        dataBytes = []
                        dataIsAllByte = false
                    }
                    dataFloats.append(f)
                case .string(let s):
                    dataItems.append(.string(s))
                    dataHasString = true
                }
            }
        case .dimStmt(let entries):
            for entry in entries {
                let sizes = entry.dims.map { e -> Int in
                    if case .intLit(let n) = e { return n + 1 }
                    return 11
                }
                arrayDims.append((name: entry.name, dims: sizes))
                if entry.name.hasSuffix("$") { stringVarNames.insert(entry.name) }
            }
        case .letStr(let name, _):
            stringVarNames.insert(name)
        case .defFn(let name, let param, let body):
            // Register during the first pass so FNA(x) works even when the
            // DEF FN line comes later in the program (the common layout:
            // definitions at the bottom). Previously registration happened
            // in genStmt, so forward references silently emitted
            // "; unimplemented function".
            userFunctions[name] = (param: param, body: body)
        case .getStmt(let name):
            if name.hasSuffix("$") { stringVarNames.insert(name) }
        case .inputStmt(_, let name):
            if name.hasSuffix("$") { stringVarNames.insert(name) }
        case .ifThen(_, let t, let e):
            t.forEach { collectStmt($0) }
            e?.forEach { collectStmt($0) }
        default: break
        }
    }

    // MARK: - Implicit Arrays (second first-pass walk)

    /// Registers an array referenced without a DIM. Real BASIC auto-DIMs
    /// to 11 elements per dimension (subscripts 0-10); without this, any
    /// implicit array produced an undefined arr_ symbol at assemble time.
    private mutating func registerImplicitArray(_ name: String, dimCount: Int) {
        guard !arrayDims.contains(where: { $0.name == name }) else { return }
        arrayDims.append((name: name, dims: Array(repeating: 11, count: max(1, dimCount))))
        if name.hasSuffix("$") { stringVarNames.insert(name) }
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
        case .inputHashStmt(let n, _), .getHashStmt(let n, _):
            collectArrayRefsExpr(n)
        case .dimStmt(let entries):
            entries.forEach { $0.dims.forEach { collectArrayRefsExpr($0) } }
        case .defFn(_, _, let body):
            collectArrayRefsExpr(body)
        default:
            break
        }
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
        case .getStmt(let name):
            emit("    jsr \(KERNAL.GETIN)")
            if name.hasSuffix("$") {
                emit("    sta var_\(asm(name))")
                emit("    lda #0")
                emit("    sta var_\(asm(name))+1")
            } else {
                let varType = table[name]
                if varType.width == .byte {
                    emit("    sta var_\(asm(name))")
                } else {
                    emit("    tay")
                    emit("    lda #0")
                    emit("    jsr \(ROM.INTFAC)")
                    genStoreFloat(name)
                }
            }
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
            emit("    and _and_tmp")
            emit("    eor _xor_tmp")
            emit("    beq \(lp)")
        case .printStmt(let items):
            genPrint(items)
        case .printHashStmt(let logNum, let items):
            genExprToByte(logNum)
            emit("    tax")
            emit("    jsr \(KERNAL.CHKOUT)")
            genPrint(items)
            emit("    jsr \(KERNAL.CLRCHN)")
        case .inputStmt(let prompt, let varName):
            genInput(prompt: prompt, varName: varName)
        case .inputHashStmt(let logNum, let names):
            genExprToByte(logNum)
            emit("    tax")
            emit("    jsr \(KERNAL.CHKIN)")
            for name in names { genInputOneVar(name) }
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
            genStrPtr(name)
            emit("    jsr _rt_strlen")      // A = length
            emit("    ldx $FB")             // X = name ptr lo
            emit("    ldy $FC")             // Y = name ptr hi
            emit("    jsr \(KERNAL.SETNAM)")
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
        case .getHashStmt(let logNum, let name):
            genExprToByte(logNum)
            emit("    tax")
            emit("    jsr \(KERNAL.CHKIN)")
            emit("    jsr \(KERNAL.GETIN)")
            emit("    jsr \(KERNAL.CLRCHN)")
            if name.hasSuffix("$") {
                emit("    sta var_\(asm(name))")
                emit("    lda #0")
                emit("    sta var_\(asm(name))+1")
            } else {
                let varType = table[name]
                if varType.width == .byte {
                    emit("    sta var_\(asm(name))")
                } else {
                    emit("    tay")
                    emit("    lda #0")
                    emit("    jsr \(ROM.INTFAC)")
                    genStoreFloat(name)
                }
            }
        case .saveStmt(let name, let dev):
            // Real KERNAL SAVE. BASIC's SAVE writes the program; the
            // compiled equivalent is the whole image from $0801 through
            // _image_end (code, runtime, data, and current variable
            // state), which re-loads as a runnable PRG.
            genStrPtr(name)
            emit("    jsr _rt_strlen")      // A = length
            emit("    ldx $FB")             // X = name ptr lo
            emit("    ldy $FC")             // Y = name ptr hi
            emit("    jsr \(KERNAL.SETNAM)")
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

        if let constAddr = constWordValue(addr) {
            emit("    lda _poke_val")
            if constAddr >= 0xA000 {
                emit("    pha")
                emit("    sei")
                emit("    lda #$35")
                emit("    sta $01")
                emit("    pla")
                emit("    sta \(hex(constAddr))")
                emit("    lda #$37")
                emit("    sta $01")
                emit("    cli")
            } else {
                emit("    sta \(hex(constAddr))")
            }
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
    private var forStack: [(name: String, bodyLabel: String, doneLabel: String)] = []

    private mutating func genFor(varName: String, from: Expr, to: Expr, step: Expr?) {
        let varType = table[varName]
        let bodyLabel = "for_\(asm(varName))_\(labelCounter)"
        let doneLabel = "fordn_\(asm(varName))_\(labelCounter)"
        labelCounter += 1
        forStack.append((name: varName, bodyLabel: bodyLabel, doneLabel: doneLabel))

        switch varType.width {
        case .byte:
            genExprToByte(from)
            emit("    sta var_\(asm(varName))")
            genExprToByte(to)
            emit("    sta _for_limit_\(asm(varName))")
            if let s = step { genExprToByte(s); emit("    sta _for_step_\(asm(varName))") }
            else { emit("    lda #1"); emit("    sta _for_step_\(asm(varName))") }
        case .word:
            genExprToWord(from)
            emit("    sta var_\(asm(varName))")
            emit("    stx var_\(asm(varName))+1")
            genExprToWord(to)
            emit("    sta _for_limit_\(asm(varName))")
            emit("    stx _for_limit_\(asm(varName))+1")
            if let s = step {
                genExprToWord(s)
                emit("    sta _for_step_\(asm(varName))")
                emit("    stx _for_step_\(asm(varName))+1")
            } else {
                emit("    lda #1"); emit("    sta _for_step_\(asm(varName))")
                emit("    lda #0"); emit("    sta _for_step_\(asm(varName))+1")
            }
        default:
            genExprToFloat(from); genStoreFloatNamed("_for_start_\(asm(varName))")
            genExprToFloat(to);   genStoreFloatNamed("_for_limit_\(asm(varName))")
            genExprToFloat(step ?? .intLit(1)); genStoreFloatNamed("_for_step_\(asm(varName))")
            genLoadFloatNamed("_for_start_\(asm(varName))")
            genStoreFloat(varName)
        }
        emit("\(bodyLabel):")
    }

    private mutating func genNext(varName: String?) {
        let entry: (name: String, bodyLabel: String, doneLabel: String)
        if let name = varName,
           let idx = forStack.lastIndex(where: { $0.name == name }) {
            entry = forStack.remove(at: idx)
        } else if let last = forStack.popLast() {
            entry = last
        } else {
            emit("    ; NEXT without FOR (ignored)")
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

    private mutating func genNextByte(_ e: (name: String, bodyLabel: String, doneLabel: String)) {
        let n = asm(e.name)
        let signed = table[e.name].isSigned

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
            emit("    lda _for_step_\(n)")
            emit("    bmi \(e.bodyLabel)_neg")
            emit("    lda var_\(n)")
            emit("    clc")
            emit("    adc _for_step_\(n)")
            emit("    sta var_\(n)")
            emit("    cmp _for_limit_\(n)")
            let posSkip = newLabel("nbps")
            emit("    beq \(posSkip)")
            emit("    bcs \(e.doneLabel)")
            emit("\(posSkip):")
            emit("    jmp \(e.bodyLabel)")
            emit("    jmp \(e.doneLabel)")
            emit("\(e.bodyLabel)_neg:")
            emit("    lda var_\(n)")
            emit("    clc")
            emit("    adc _for_step_\(n)")
            emit("    sta var_\(n)")
            emit("    cmp _for_limit_\(n)")
            let negSkip = newLabel("nbns")
            emit("    bcc \(negSkip)")
            emit("    jmp \(e.bodyLabel)")
            emit("\(negSkip):")
        }
    }

    private mutating func genNextWord(_ e: (name: String, bodyLabel: String, doneLabel: String)) {
        let n = asm(e.name)
        let negPath = newLabel("nwneg")

        // Runtime sign test on the step's high byte: STEP can be any
        // expression, so the direction isn't knowable at compile time.
        emit("    lda _for_step_\(n)+1")
        emit("    bmi \(negPath)")

        // -- Positive step: 16-bit add, exit on wrap past $FFFF,
        //    continue while var <= limit --
        emit("    lda var_\(n)")
        emit("    clc")
        emit("    adc _for_step_\(n)")
        emit("    sta var_\(n)")
        emit("    lda var_\(n)+1")
        emit("    adc _for_step_\(n)+1")
        emit("    sta var_\(n)+1")
        emit("    bcs \(e.doneLabel)")      // wrapped past 65535: done
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

        // -- Negative step (two's complement add): carry CLEAR means the
        //    subtraction borrowed past 0, so the loop is done. Otherwise
        //    continue while var >= limit. --
        emit("\(negPath):")
        emit("    lda var_\(n)")
        emit("    clc")
        emit("    adc _for_step_\(n)")
        emit("    sta var_\(n)")
        emit("    lda var_\(n)+1")
        emit("    adc _for_step_\(n)+1")
        emit("    sta var_\(n)+1")
        emit("    bcc \(e.doneLabel)")      // underflowed below 0: done
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

    private mutating func genNextFloat(_ e: (name: String, bodyLabel: String, doneLabel: String)) {
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
        emit("    jmp \(e.bodyLabel)")
        emit("\(negSkip):")
        let negSkip2 = newLabel("fnfns2")
        emit("    bpl \(negSkip2)")
        emit("    jmp \(e.bodyLabel)")
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

    private mutating func genByteComparison(op: String, left: Expr, right: Expr, falseLabel: String) {
        genExprToByte(left)
        if let k = constByteValue(right) {
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
            emit("    sta _cmp_tmp")
            genExprToByte(right)
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
        genExprToWord(right)
        emit("    sta _cmp_lo")
        emit("    stx _cmp_hi")
        genExprToWord(left)
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
        genStrPtr(left)
        emit("    lda $FB")
        emit("    sta _str_src_lo")
        emit("    lda $FC")
        emit("    sta _str_src_hi")
        genStrPtr(right)
        emit("    jsr _rt_strcmp")
        switch op {
        case "=":  emit("    bne \(falseLabel)")
        case "<>": emit("    beq \(falseLabel)")
        case "<":  emit("    bpl \(falseLabel)"); emit("    beq \(falseLabel)")
        case ">":  emit("    bmi \(falseLabel)"); emit("    beq \(falseLabel)")
        case "<=": emit("    bpl \(falseLabel)")
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
        }
    }

    // MARK: - INPUT
    private mutating func genInput(prompt: String?, varName: String) {
        if let p = prompt {
            let lbl = newLabel("ipr")
            emit("    lda #<\(lbl)")
            emit("    ldy #>\(lbl)")
            emit("    jsr _print_str")
            emitStringData(lbl, p)
            emit("    lda #$3F")
            emit("    jsr \(KERNAL.CHROUT)")
            emit("    lda #$20")
            emit("    jsr \(KERNAL.CHROUT)")
        }
        genInputOneVar(varName)
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
    private mutating func genRead(_ names: [String]) {
        if dataHasString {
            for name in names {
                if name.hasSuffix("$") {
                    emit("    lda #<var_\(asm(name))")
                    emit("    ldy #>var_\(asm(name))")
                    emit("    jsr _rt_data_read_str")
                } else {
                    emit("    ; NOTE: Tier-3 DATA with strings uses tagged format.")
                    emit("    ; Numeric READ fallback is intentionally omitted for v1.0.")
                    emit("    jmp _program_end")
                }
            }
            return
        }
        for name in names {
            let varType = table[name]
            if dataIsAllByte && varType.width == .byte {
                emit("    ldy _data_ptr")
                emit("    lda _data_table,y")
                emit("    sta var_\(asm(name))")
                emit("    inc _data_ptr")
            } else if dataIsAllByte && varType.width == .word {
                emit("    ldy _data_ptr")
                emit("    lda _data_table,y")
                emit("    sta var_\(asm(name))")
                emit("    lda #0")
                emit("    sta var_\(asm(name))+1")
                emit("    inc _data_ptr")
            } else {
                let lbl = newLabel("rd")
                emit("    ldy _data_ptr")
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
                switch varType.width {
                case .byte:
                    emit("    jsr \(ROM.FACINT)")
                    emit("    sty var_\(asm(name))")
                case .word:
                    emit("    jsr \(ROM.FACINT)")
                    emit("    sty var_\(asm(name))")
                    emit("    sta var_\(asm(name))+1")
                default:
                    genStoreFloat(name)
                }
                emit("    lda _data_ptr")
                emit("    clc")
                emit("    adc #5")
                emit("    sta _data_ptr")
                emit("    lda _data_ptr+1")
                emit("    adc #0")
                emit("    sta _data_ptr+1")
            }
        }
    }

    // MARK: - ON GOTO / GOSUB
    private mutating func genOnGotoGosub(expr: Expr, targets: [Int], isGosub: Bool) {
        guard !targets.isEmpty else { return }
        let done = newLabel("on_done")
        let op   = isGosub ? "jsr" : "jmp"
        genExprToByte(expr)
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
    private mutating func genOpen(logNum: Expr, device: Expr, secondary: Expr, filename: Expr?) {
        genExprToByte(logNum);    emit("    sta _open_log")
        genExprToByte(device);   emit("    sta _open_dev")
        genExprToByte(secondary);emit("    sta _open_sec")
        emit("    lda _open_log")
        emit("    ldx _open_dev")
        emit("    ldy _open_sec")
        emit("    jsr \(KERNAL.SETLFS)")
        if let fn = filename {
            genStrPtr(fn)
            emit("    jsr _rt_strlen")      // A = length (SETNAM wants A)
            emit("    ldx $FB")             // X = name ptr lo
            emit("    ldy $FC")             // Y = name ptr hi
            emit("    jsr \(KERNAL.SETNAM)")
        } else {
            emit("    lda #0")
            emit("    jsr \(KERNAL.SETNAM)")
        }
        emit("    jsr \(KERNAL.KOPEN)")
    }

    // MARK: - Array Write
    private mutating func genArrayWrite(name: String, indices: [Expr], rhs: Expr) {
        genArrayElementPtr(name: name, indices: indices)
        if name.hasSuffix("$") {
            // genStrPtr never touches _arr_ptr, so no save needed here.
            genStrPtr(rhs)
            emit("    lda _arr_ptr_lo")
            emit("    sta $FD")
            emit("    lda _arr_ptr_hi")
            emit("    sta $FE")
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

    private mutating func genArrayElementPtr(name: String, indices: [Expr]) {
        let dims = arrayDims.first(where: { $0.name == name })?.dims ?? [11]
        let bytesPerElem: Int
        if name.hasSuffix("$") { bytesPerElem = 256 }
        else if name.hasSuffix("%") { bytesPerElem = 2 }
        else { bytesPerElem = 5 }

        emit("    lda #0")
        emit("    sta _arr_idx_lo")
        emit("    sta _arr_idx_hi")

        for (i, idx) in indices.enumerated() {
            if i > 0 {
                let stride = dims[i]
                emit("    lda _arr_idx_lo")
                emit("    ldx #\(stride)")
                emit("    jsr _rt_mul8")
                emit("    lda _arr_mul_lo")
                emit("    sta _arr_idx_lo")
                emit("    lda _arr_mul_hi")
                emit("    sta _arr_idx_hi")
            }
            genExprToByte(idx)
            emit("    clc")
            emit("    adc _arr_idx_lo")
            emit("    sta _arr_idx_lo")
            emit("    bcc @ainc\(labelCounter)")
            emit("    inc _arr_idx_hi")
            emit("@ainc\(labelCounter):")
            labelCounter += 1
        }

        if bytesPerElem == 256 {
            emit("    lda _arr_idx_lo")
            emit("    sta _arr_idx_hi")
            emit("    lda #0")
            emit("    sta _arr_idx_lo")
        } else if bytesPerElem > 1 {
            emit("    lda _arr_idx_lo")
            emit("    ldx #\(bytesPerElem)")
            emit("    jsr _rt_mul8")
            emit("    lda _arr_mul_lo")
            emit("    sta _arr_idx_lo")
            emit("    lda _arr_mul_hi")
            emit("    sta _arr_idx_hi")
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
    mutating func genExprToByte(_ expr: Expr) {
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
            genExprToByte(l); emit("    sta _cmp_tmp"); genExprToByte(r); emit("    and _cmp_tmp")
        case .binaryOp("OR", let l, let r):
            genExprToByte(l); emit("    sta _cmp_tmp"); genExprToByte(r); emit("    ora _cmp_tmp")
        case .binaryOp("+", let l, let r):
            genExprToByte(l)
            if let k = constByteValue(r) { emit("    clc"); emit("    adc #\(k)") }
            else { emit("    sta _cmp_tmp"); genExprToByte(r); emit("    clc"); emit("    adc _cmp_tmp") }
        case .binaryOp("-", let l, let r):
            genExprToByte(l)
            if let k = constByteValue(r) { emit("    sec"); emit("    sbc #\(k)") }
            else {
                emit("    sta _cmp_tmp"); genExprToByte(r); emit("    sta _arith_tmp")
                emit("    lda _cmp_tmp"); emit("    sec"); emit("    sbc _arith_tmp")
            }
        case .unaryMinus(let e):
            genExprToByte(e); emit("    eor #$FF"); emit("    clc"); emit("    adc #1")
        case .funcCall("CHR$", _):
            if case .funcCall(_, let args) = expr, let a = args.first { genExprToByte(a) }
        default:
            genExprToFloat(expr); emit("    jsr _rt_fac_to_byte")
        }
    }

    mutating func genExprToWord(_ expr: Expr) {
        switch expr {
        case .intLit(let n):
            emit("    lda #<\(n)"); emit("    ldx #>\(n)")
        case .floatLit(let f):
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
                emit("    jsr \(ROM.FACINT)")
                emit("    sta _word_hi_tmp")
                emit("    tya"); emit("    ldx _word_hi_tmp")
            }
        case .intVar(let name):
            emit("    lda var_\(asm(name))"); emit("    ldx var_\(asm(name))+1")
        case .binaryOp("+", let l, let r):
            genExprToWord(l); emit("    sta _word_lo"); emit("    stx _word_hi")
            if let k = constWordValue(r) {
                emit("    lda _word_lo"); emit("    clc"); emit("    adc #<\(k)"); emit("    sta _word_lo")
                emit("    lda _word_hi"); emit("    adc #>\(k)"); emit("    tax"); emit("    lda _word_lo")
            } else {
                genExprToWord(r); emit("    sta _arith_tmp")
                emit("    clc"); emit("    lda _word_lo"); emit("    adc _arith_tmp"); emit("    sta _word_lo")
                emit("    txa"); emit("    adc _word_hi"); emit("    tax"); emit("    lda _word_lo")
            }
        case .binaryOp("-", let l, let r):
            genExprToWord(l); emit("    sta _word_lo"); emit("    stx _word_hi")
            if let k = constWordValue(r) {
                emit("    lda _word_lo"); emit("    sec"); emit("    sbc #<\(k)"); emit("    sta _word_lo")
                emit("    lda _word_hi"); emit("    sbc #>\(k)"); emit("    tax"); emit("    lda _word_lo")
            } else {
                genExprToWord(r); emit("    sta _arith_tmp")
                emit("    sec"); emit("    lda _word_lo"); emit("    sbc _arith_tmp"); emit("    sta _word_lo")
                emit("    txa"); emit("    sbc _word_hi"); emit("    tax"); emit("    lda _word_lo")
            }
        case .arrayRead(let name, let idxs) where name.hasSuffix("%"):
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
            genExprToFloat(expr); emit("    jsr \(ROM.FACINT)")
            emit("    sta _word_hi_tmp"); emit("    tya"); emit("    ldx _word_hi_tmp")
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
            let lbl = newLabel("flt")
            emitFloatConst(lbl, Double(n))
            emit("    lda #<\(lbl)"); emit("    ldy #>\(lbl)"); emit("    jsr \(ROM.MOVFM)")
        case .floatLit(let f):
            let lbl = newLabel("flt")
            emitFloatConst(lbl, f)
            emit("    lda #<\(lbl)"); emit("    ldy #>\(lbl)"); emit("    jsr \(ROM.MOVFM)")
        case .strLit, .strVar:
            break
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
            let lbl256 = newLabel("ti256")
            emitFloatConst(lbl256, 256.0)
            let tmp = newLabel("titmp")
            emitFloatScratch(tmp)
            emit("    lda #0"); emit("    ldy $A0"); emit("    jsr \(ROM.INTFAC)")
            emit("    lda #<\(lbl256)"); emit("    ldy #>\(lbl256)"); emit("    jsr \(ROM.FMUL)")
            emit("    ldx #<\(tmp)"); emit("    ldy #>\(tmp)"); emit("    jsr \(ROM.MOVMF)")
            emit("    lda #0"); emit("    ldy $A1"); emit("    jsr \(ROM.INTFAC)")
            emit("    lda #<\(tmp)"); emit("    ldy #>\(tmp)"); emit("    jsr \(ROM.FADD)")
            emit("    lda #<\(lbl256)"); emit("    ldy #>\(lbl256)"); emit("    jsr \(ROM.FMUL)")
            emit("    ldx #<\(tmp)"); emit("    ldy #>\(tmp)"); emit("    jsr \(ROM.MOVMF)")
            emit("    lda #0"); emit("    ldy $A2"); emit("    jsr \(ROM.INTFAC)")
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
        case "FRE":    if !args.isEmpty { genExprToFloat(args[0]); emit("    jsr $B37D") }
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
                emit("    ; unimplemented function: \(fn)")
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
            emit("    ; string ptr: unhandled expr")
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
                emit("    lda _str_tmp"); emit("    sec"); emit("    sbc _arith_tmp"); emit("    sta _str_slice_start")
                emit("    lda _arith_tmp"); emit("    sta _str_slice_len")
            } else {
                emit("    lda #0"); emit("    sta _str_slice_start")
                emit("    lda #255"); emit("    sta _str_slice_len")
            }
        case "MID$":
            if args.count > 1 { genExprToByte(args[1]); emit("    sec"); emit("    sbc #1"); emit("    sta _str_slice_start") }
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
    private func constWordValue(_ expr: Expr) -> Int? {
        if case .intLit(let n) = expr, n >= 0, n <= 65535 { return n }
        return nil
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
        emit("    lda _peek_lo"); emit("    sta @pk+1")
        emit("    lda _peek_hi"); emit("    sta @pk+2")
        emit("    sei"); emit("    lda #$35"); emit("    sta $01")
        emit("@pk:"); emit("    lda $0000"); emit("    pha")
        emit("    lda #$37"); emit("    sta $01"); emit("    cli")
        emit("    pla"); emit("    rts")
        emit("")

        emit("_rt_poke:")
        emit("    lda _poke_lo"); emit("    sta @pk+1")
        emit("    lda _poke_hi"); emit("    sta @pk+2")
        emit("    lda _poke_val"); emit("    sei")
        emit("    ldx #$35"); emit("    stx $01")
        emit("@pk:"); emit("    sta $0000")
        emit("    ldx #$37"); emit("    stx $01"); emit("    cli")
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
        emit("    lda _str_tmp"); emit("    sec"); emit("    sbc ($FB),y"); emit("    rts")
        emit("")

        emit("_rt_str_slice:")
        emit("    lda _str_src_lo"); emit("    sta $FB")
        emit("    lda _str_src_hi"); emit("    sta $FC")
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
        emit("    jsr _rt_input_num"); emit("    jsr \(ROM.FACINT)")
        emit("    sty _input_lo"); emit("    sta _input_hi"); emit("    rts")
        emit("")

        emit("_rt_tab:")
        emit("    beq @done"); emit("    sec"); emit("    sbc #1"); emit("    sta _str_tmp")
        emit("    lda $D3"); emit("    cmp _str_tmp"); emit("    bcs @done")
        emit("@tl:"); emit("    lda #$20"); emit("    jsr \(KERNAL.CHROUT)")
        emit("    lda $D3"); emit("    cmp _str_tmp"); emit("    bcc @tl")
        emit("@done:"); emit("    rts")
        emit("")

        emit("_rt_spc:")
        emit("    beq @done"); emit("    tax"); emit("@sl: lda #$20")
        emit("jsr \(KERNAL.CHROUT)"); emit("dex"); emit("bne @sl")
        emit("@done:"); emit("    rts")
        emit("")

        emit("_rt_tab_to_next_col:")
        emit("    lda $D3"); emit("@m: cmp #10"); emit("bcc @g")
        emit("sbc #10"); emit("jmp @m"); emit("@g: sta _str_tmp")
        emit("lda #10"); emit("sec"); emit("sbc _str_tmp")
        emit("    jsr _rt_spc"); emit("    rts")
        emit("")

        emit("_rt_mul8:")
        emit("    sta _arr_mul_lo"); emit("    lda #0"); emit("    sta _arr_mul_hi")
        emit("    ldy #8"); emit("@ml:")
        emit("    asl _arr_mul_lo"); emit("    rol _arr_mul_hi"); emit("    bcc @mn")
        emit("    txa"); emit("    clc"); emit("    adc _arr_mul_lo"); emit("    sta _arr_mul_lo")
        emit("    lda _arr_mul_hi"); emit("    adc #0"); emit("    sta _arr_mul_hi")
        emit("@mn:"); emit("dey"); emit("bne @ml")
        emit("    rts")
        emit("")

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
        }

        for line in stringDataSection { emit(line) }
        for line in floatConstSection { emit(line) }
        emit("")

        emit("; ── Scratch storage ──")
        emit("_cmp_tmp:    .res 1"); emit("_cmp_lo:     .res 1"); emit("_cmp_hi:     .res 1")
        emit("_arith_tmp:  .res 1"); emit("_and_tmp:    .res 1"); emit("_xor_tmp:    .res 1")
        emit("_str_tmp:    .res 1"); emit("_word_lo:    .res 1"); emit("_word_hi:    .res 1")
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
                    var bytes = s.unicodeScalars.map { UInt8($0.value & 0x7F) }
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
        var bytes = s.unicodeScalars.map { UInt8($0.value & 0x7F) }
        bytes.append(0)
        let hex = bytes.map { String(format: "$%02X", $0) }.joined(separator: ", ")
        stringDataSection.append("\(label): .byte \(hex)")
    }

    private mutating func emitFloatConst(_ label: String, _ value: Double) {
        if floatConstSection.contains(where: { $0.hasPrefix("\(label):") }) { return }
        let bytes = encodeC64Float(value)
        let hex = bytes.map { String(format: "$%02X", $0) }.joined(separator: ", ")
        floatConstSection.append("\(label): .byte \(hex)  ; = \(value)")
    }

    private mutating func emitFloatScratch(_ label: String) {
        if floatConstSection.contains(where: { $0.hasPrefix("\(label):") }) { return }
        floatConstSection.append("\(label): .res 5")
    }

    private mutating func emitWordScratch(_ label: String) {
        if floatConstSection.contains(where: { $0.hasPrefix("\(label):") }) { return }
        floatConstSection.append("\(label): .res 2")
    }

    /// Encode a Double as a 5-byte C64 float.
    /// Format: [exponent (bias 128), mantissa byte 1, 2, 3, 4]
    /// Mantissa bit 31 holds the sign. Exponent byte 0 = 0 means zero.
    private func encodeC64Float(_ value: Double) -> [UInt8] {
        if value == 0 { return [0, 0, 0, 0, 0] }
        let negative = value < 0
        var v = abs(value)
        var exp = 0
        while v >= 1 { v /= 2; exp += 1 }
        while v < 0.5 { v *= 2; exp -= 1 }
        let biasedExp = UInt8(clamping: exp + 128)
        var mantissa = UInt32(v * pow(2.0, 32))
        if negative { mantissa |= 0x8000_0000 }
        else        { mantissa &= 0x7FFF_FFFF }
        return [
            biasedExp,
            UInt8((mantissa >> 24) & 0xFF),
            UInt8((mantissa >> 16) & 0xFF),
            UInt8((mantissa >>  8) & 0xFF),
            UInt8((mantissa      ) & 0xFF)
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
                }
                emit("_for_limit_\(asm(name)): .res \(bytes)")
                emit("_for_step_\(asm(name)):  .res \(bytes)")
            }
        }

        if !arrayDims.isEmpty {
            emit(""); emit("; ── Array storage ──")
            for (name, dims) in arrayDims {
                let total = dims.reduce(1, *)
                let bpe: Int
                if name.hasSuffix("$") { bpe = 256 }
                else if name.hasSuffix("%") { bpe = 2 }
                else { bpe = 5 }
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
        let lines = parser.parse(source)

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
            symbolTable: symbolTable
        )
    }
}

struct CompileResultV2 {
    let success: Bool
    let assembly: String?
    let parseErrors: [String]
    let symbolTable: SymbolTable
}

