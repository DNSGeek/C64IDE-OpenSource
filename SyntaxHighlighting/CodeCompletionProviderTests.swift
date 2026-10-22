// MARK: - CodeCompletionProviderTests.swift
//
// Tests for the offline completion provider: BASIC keywords (V2 and
// dialect), in-file variables, line-number targets after GOTO / GOSUB /
// THEN, assembly mnemonics, directives, labels, symbols and ROM names, the
// ranking rules, and every place completion must stay quiet.

import XCTest
@testable import C64IDE

final class CodeCompletionProviderTests: XCTestCase {

    // MARK: - Helpers

    /// `source` with a `|` marking the cursor.
    private func request(_ source: String, _ fileType: C64FileType,
                         dialect: BasicDialect? = nil,
                         variables: [CodeCompletionProvider.Variable] = []) -> CodeCompletionProvider.Request {
        let ns = source as NSString
        let cursor = ns.range(of: "|").location
        precondition(cursor != NSNotFound, "mark the cursor with |")
        let text = ns.replacingCharacters(in: NSRange(location: cursor, length: 1), with: "")
        return CodeCompletionProvider.Request(source: text, cursor: cursor, fileType: fileType,
                                              dialect: dialect, variables: variables)
    }

    private func basic(_ source: String, trigger: CodeCompletionProvider.Trigger = .automatic,
                       dialect: BasicDialect? = nil,
                       variables: [CodeCompletionProvider.Variable] = []) -> CodeCompletionProvider.Result? {
        CodeCompletionProvider.complete(request(source, .basic, dialect: dialect, variables: variables),
                                        trigger: trigger)
    }

    private func asm(_ source: String, trigger: CodeCompletionProvider.Trigger = .automatic) -> CodeCompletionProvider.Result? {
        CodeCompletionProvider.complete(request(source, .assembly), trigger: trigger)
    }

    private func texts(_ result: CodeCompletionProvider.Result?) -> [String] {
        result?.items.map(\.text) ?? []
    }

    private lazy var simonsLike: BasicDialect = try! JSONDecoder().decode(BasicDialect.self, from: Data("""
    {
      "name": "TestBASIC",
      "extendsBasicV2": true,
      "keywords": [
        {"keyword": "CIRCLE", "type": "command", "token": 1, "syntax": "CIRCLE x, y, r"},
        {"keyword": "cset",   "type": "command", "token": 2, "description": "Select character set"},
        {"keyword": "JOY",    "type": "function", "token": 3},
        {"keyword": "ELSE",   "type": "conditional", "token": 4}
      ]
    }
    """.utf8))

    // MARK: - BASIC keywords

    func testBasicKeywordsAreOfferedInUppercaseWithSyntaxDetail() {
        let r = basic("10 pri|")
        XCTAssertEqual(texts(r), ["PRINT", "PRINT#"])
        XCTAssertEqual(r?.range, NSRange(location: 3, length: 3))
        XCTAssertEqual(r?.items.first?.kind, .keyword)
        XCTAssertEqual(r?.items.first?.detail, C64BasicSyntax.commandReference["PRINT"]?.syntax)
    }

    func testBasicFunctionsOperatorsAndSystemVariablesAreOffered() {
        XCTAssertEqual(texts(basic("10 X=le|")), ["LEFT$", "LEN", "LET"])
        XCTAssertEqual(texts(basic("10 IF A an|")), ["AND"])
        XCTAssertNil(basic("10 PRINT ti|"))   // TI itself is an exact match
        XCTAssertEqual(texts(basic("10 PRINT ti|", trigger: .manual)), ["TI$"])
    }

    func testGoIsNeverOfferedSoGotoAndGosubStillCompleteAfterGO() {
        let r = basic("10 go|")
        XCTAssertEqual(texts(r), ["GOSUB", "GOTO"])
        XCTAssertFalse(texts(basic("10 g|", trigger: .manual)).contains("GO"))
    }

    func testDialectKeywordsJoinTheV2Set() {
        let r = basic("10 ci|", dialect: simonsLike)
        XCTAssertEqual(texts(r), ["CIRCLE"])
        XCTAssertEqual(r?.items.first?.detail, "CIRCLE x, y, r")
        // Lowercase in the plugin still comes out uppercase; description
        // stands in when there is no syntax string.
        let cset = basic("10 cs|", dialect: simonsLike)
        XCTAssertEqual(texts(cset), ["CSET"])
        XCTAssertEqual(cset?.items.first?.detail, "Select character set")
        XCTAssertEqual(basic("10 X=jo|", dialect: simonsLike)?.items.first?.kind, .function)
        // V2 keywords are still there under a dialect.
        XCTAssertEqual(texts(basic("10 pri|", dialect: simonsLike)), ["PRINT", "PRINT#"])
    }

    func testVariablesFromTheScanAreOfferedWithTheirSuffix() {
        let vars = [CodeCompletionProvider.Variable(name: "SC%", detail: "integer"),
                    CodeCompletionProvider.Variable(name: "SCORE$", detail: "string"),
                    CodeCompletionProvider.Variable(name: "A", detail: "float")]
        let r = basic("20 PRINT sc|", variables: vars)
        XCTAssertEqual(texts(r), ["SC%", "SCORE$"])
        XCTAssertEqual(r?.items.map(\.kind), [.variable, .variable])
        XCTAssertEqual(r?.items.first?.detail, "integer")
    }

    func testVariableBridgeDescribesScalarsArraysAndFunctions() {
        func info(_ name: String, _ kind: BasicVariableInfo.Kind, dims: String? = nil) -> BasicVariableInfo {
            BasicVariableInfo(name: name, kind: kind, type: .float, firstLine: 10, lines: [10],
                              readCount: 0, writeCount: 1, initialValue: nil, dims: dims, collidesWith: [])
        }
        XCTAssertEqual(CodeCompletionProvider.Variable(info("A$", .scalar)).detail, "string")
        XCTAssertEqual(CodeCompletionProvider.Variable(info("N%", .scalar)).detail, "integer")
        XCTAssertEqual(CodeCompletionProvider.Variable(info("M", .array, dims: "10,5")).detail, "array (10,5)")
        XCTAssertEqual(CodeCompletionProvider.Variable(info("FNA", .function)).detail, "user function")
    }

    func testManualTriggerOnAnEmptyWordListsEverything() {
        let r = basic("10 |", trigger: .manual, variables: [.init(name: "Z9")])
        XCTAssertNil(basic("10 |"))
        XCTAssertTrue(texts(r).contains("PRINT"))
        XCTAssertTrue(texts(r).contains("Z9"))
        XCTAssertEqual(r?.range, NSRange(location: 3, length: 0))
    }

    // MARK: - Line numbers

    private let program = """
    10 PRINT "HELLO"
    20 GOSUB 100
    100 X=X+1
    200 RETURN
    """

    func testLineNumbersAfterGotoGosubThenAndGoTo() {
        let r = basic(program + "\n30 GOTO 1|")
        XCTAssertEqual(texts(r), ["10", "100"])
        XCTAssertEqual(r?.items.map(\.kind), [.lineNumber, .lineNumber])
        XCTAssertEqual(r?.items.first?.detail, "PRINT \"HELLO\"")
        XCTAssertEqual(r?.range, NSRange(location: (program as NSString).length + 9, length: 1))

        XCTAssertEqual(texts(basic(program + "\n30 GOSUB 2|")), ["20", "200"])
        XCTAssertEqual(texts(basic(program + "\n30 IF X=1 THEN 2|")), ["20", "200"])
        XCTAssertEqual(texts(basic(program + "\n30 IF X=1 THEN2|")), ["20", "200"])
        XCTAssertEqual(texts(basic(program + "\n30 GO TO 1|")), ["10", "100"])
        XCTAssertEqual(texts(basic(program + "\n30 ON X GOTO 10,2|")), ["20", "200"])
        XCTAssertEqual(texts(basic(program + "\n30 goto 1|")), ["10", "100"])
    }

    func testLineNumbersAreNumericOrderAndSkipTheExactMatch() {
        XCTAssertEqual(texts(basic(program + "\n30 GOTO |", trigger: .manual)), ["10", "20", "30", "100", "200"])
        XCTAssertNil(basic(program + "\n30 GOTO |"))          // nothing typed yet
        XCTAssertNil(basic(program + "\n30 GOTO 10|"))        // typed in full: leave Return alone
        XCTAssertEqual(texts(basic(program + "\n30 GOTO 10|", trigger: .manual)), ["100"])
        XCTAssertNil(basic(program + "\n30 GOTO 4|"))         // no such line
    }

    func testNumbersElsewhereAreNotCompleted() {
        XCTAssertNil(basic("10 X=12|"))
        XCTAssertNil(basic("10|"))
        XCTAssertNil(basic("10 POKE 532|", trigger: .manual))
    }

    func testThenFollowedByAStatementCompletesKeywords() {
        XCTAssertEqual(texts(basic("10 IF X THEN pri|")), ["PRINT", "PRINT#"])
    }

    func testKeywordsRunTogetherWithoutSpaces() {
        // The ROM tokenizer reads "THENPR" as THEN + PR; so does completion.
        let r = basic("10 IF X THENpri|")
        XCTAssertEqual(texts(r), ["PRINT", "PRINT#"])
        XCTAssertEqual(r?.range, NSRange(location: 12, length: 3))
        XCTAssertEqual(texts(basic("10 FORI=1TO10:PRINTsc|", variables: [.init(name: "SC%")])), ["SC%"])
        XCTAssertEqual(texts(basic(program + "\n30 GOTO1|")), ["10", "100"])
        XCTAssertEqual(texts(basic(program + "\n30 IF X THEN GOSUB2|")), ["20", "200"])
        XCTAssertNil(basic("10 REMpri|"))
        XCTAssertNil(basic("10 PRINTI|"))   // "I" alone is too short to pop up
        XCTAssertNil(basic("10 PRINTqz|"))  // nothing matches after PRINT either
    }

    // MARK: - BASIC: when to stay quiet

    func testNoCompletionInsideStringsAfterRemOrInData() {
        XCTAssertNil(basic("10 PRINT \"PRI|"))
        XCTAssertNil(basic("10 PRINT \"A\";\"PRI|"))
        XCTAssertNotNil(basic("10 PRINT \"A\";pri|"))
        XCTAssertNil(basic("10 REM PRI|"))
        XCTAssertNil(basic("10 X=1:REM PRI|"))
        XCTAssertNil(basic("10 REMPRI|"))
        XCTAssertNil(basic("10 DATA PRI|"))
        XCTAssertNil(basic("10 DATA 1,2,PRI|"))
        XCTAssertNotNil(basic("10 DATA 1,2:PRI|"))
        XCTAssertNotNil(basic("10 TREMOR=1:PRI|"))   // REM inside a name is not a comment
    }

    func testAutomaticTriggerNeedsTwoCharactersAndTheEndOfTheWord() {
        XCTAssertNil(basic("10 p|"))
        XCTAssertNotNil(basic("10 p|", trigger: .manual))
        XCTAssertNil(basic("10 PR|NT"))
        XCTAssertNotNil(basic("10 PR|NT", trigger: .manual))
        XCTAssertNil(basic("10 PRINT|"))   // exact match: no popup over a finished word
        XCTAssertEqual(texts(basic("10 PRINT|", trigger: .manual)), ["PRINT#"])
    }

    func testLeadingDigitsAreNotPartOfTheWord() {
        let r = basic("10pri|")
        XCTAssertEqual(texts(r), ["PRINT", "PRINT#"])
        XCTAssertEqual(r?.range, NSRange(location: 2, length: 3))
        XCTAssertEqual(texts(basic("10 FORI=1to|", trigger: .manual)), [])   // TO typed in full
        XCTAssertEqual(texts(basic("10 FORI=1t|", trigger: .manual)), ["TAB", "TAN", "THEN", "TI", "TI$", "TO"])
    }

    func testTextFilesGetNoCompletion() {
        XCTAssertNil(CodeCompletionProvider.complete(request("pri|", .text), trigger: .manual))
    }

    // MARK: - Assembly: mnemonics and directives

    func testMnemonicsInInstructionPositionMatchTypedCase() {
        let lower = asm("  ld|")
        XCTAssertEqual(texts(lower), ["lda", "ldx", "ldy"])
        XCTAssertEqual(lower?.items.first?.kind, .mnemonic)
        XCTAssertEqual(lower?.items.first?.detail, "Load Accumulator")
        XCTAssertEqual(lower?.range, NSRange(location: 2, length: 2))
        XCTAssertEqual(texts(asm("LD|")), ["LDA", "LDX", "LDY"])
        XCTAssertEqual(texts(asm("start:  ld|")), ["lda", "ldx", "ldy"])
        XCTAssertEqual(texts(asm("start:\n  ld|")), ["lda", "ldx", "ldy"])
    }

    func testUndocumentedOpcodesAreMarked() {
        let r = asm("  la|")
        XCTAssertTrue(texts(r).contains("lax"))
        let lax = r?.items.first { $0.text == "lax" }
        XCTAssertTrue(lax?.detail?.hasSuffix("(undocumented)") == true)
    }

    func testDirectivesCompleteAfterADot() {
        XCTAssertEqual(texts(asm("  .by|")), [".byte"])
        XCTAssertEqual(texts(asm(".BY|")), [".BYTE"])
        XCTAssertEqual(asm("  .by|")?.items.first?.kind, .directive)
        XCTAssertEqual(asm("  .by|")?.range, NSRange(location: 2, length: 3))
        XCTAssertTrue(texts(asm("  .ma|")).contains(".macro"))
        // Inside an operand a dot starts a pseudo function, not a directive.
        XCTAssertEqual(texts(asm("  lda #.lob|")), [".lobyte"])
        XCTAssertFalse(texts(asm("  lda #.|", trigger: .manual)).contains(".byte"))
    }

    // MARK: - Assembly: labels, symbols, ROM names

    func testLabelsDefinedInTheFileAreOfferedInOperands() {
        let src = """
        loop:   lda #0
        @skip:  sta $d020
        done: rts
                jmp loo|
        """
        let r = asm(src)
        XCTAssertEqual(texts(r), ["loop"])
        XCTAssertEqual(r?.items.first?.kind, .label)
        XCTAssertEqual(r?.items.first?.detail, "label")
        // "lo" alone also brings in the KERNAL's LOAD entries, after the label.
        XCTAssertEqual(texts(asm(src.replacingOccurrences(of: "jmp loo|", with: "jmp lo|"))),
                       ["load", "load_int", "loop"])
        let cheap = src.replacingOccurrences(of: "jmp loo|", with: "bne @s|")
        XCTAssertEqual(texts(asm(cheap)), ["@skip"])
        XCTAssertEqual(asm(cheap)?.range, NSRange(location: (cheap as NSString).length - 3, length: 2))
    }

    func testLabelsKeepTheirOwnCase() {
        XCTAssertEqual(texts(asm("Draw:\n  jsr dr|")), ["Draw"])
        XCTAssertEqual(texts(asm("Draw:\n  jsr DR|")), ["Draw"])
    }

    func testLabelsWithoutColonsFeature() {
        let src = """
        .feature labels_without_colons
        mainloop lda #0
                jmp mainl|
        """
        XCTAssertEqual(texts(asm(src)), ["mainloop"])
        // Without the feature a bare word in column one is not a label.
        XCTAssertNil(asm("mainloop lda #0\n        jmp mainl|"))
        // And with it, the word after a colon-less label is an instruction.
        XCTAssertEqual(texts(asm(".feature labels_without_colons\nloop ld|")), ["lda", "ldx", "ldy"])
    }

    func testAssignedSymbolsProcsImportsAndMacros() {
        let src = """
        screen  = $0400
        border  := $d020
        .proc main
                rts
        .endproc
        .import chrout, getin:zp
        .macro setcolor c
                lda #c
        .endmacro
        """
        let defs = CodeCompletionProvider.scanAssemblyDefinitions(src)
        XCTAssertEqual(defs.symbols.map(\.text), ["screen", "border", "main", "chrout", "getin"])
        XCTAssertEqual(defs.symbols[0].detail, "= $0400")
        XCTAssertEqual(defs.symbols[1].detail, "= $d020")
        XCTAssertEqual(defs.symbols[2].detail, "proc")
        XCTAssertEqual(defs.symbols[3].detail, "imported")
        XCTAssertEqual(defs.macroNames, ["setcolor"])

        let screen = asm(src + "\n  lda sc|")?.items.first { $0.text == "screen" }
        XCTAssertEqual(screen?.detail, "= $0400")
        XCTAssertEqual(screen?.kind, .symbol)
        // Macros complete in instruction position, like mnemonics.
        let macro = asm(src + "\n  setc|")
        XCTAssertEqual(texts(macro), ["setcolor"])
        XCTAssertEqual(macro?.items.first?.kind, .macro)
        // An imported name shadows the ROM table entry of the same name.
        let shadowed = asm(src + "\n  jsr chro|")
        XCTAssertEqual(texts(shadowed), ["chrout", "chrout_int"])
        XCTAssertEqual(shadowed?.items.first?.detail, "imported")
    }

    func testRomSymbolsCompleteInOperandsWithTheirAddress() {
        let r = asm("  jsr chro|")
        XCTAssertEqual(texts(r), ["chrout", "chrout_int"])
        XCTAssertEqual(r?.items.first?.kind, .symbol)
        XCTAssertTrue(r?.items.first?.detail?.hasPrefix("$FFD2") == true)
        XCTAssertEqual(texts(asm("  JSR CHRO|")), ["CHROUT", "CHROUT_INT"])
        XCTAssertTrue(texts(asm("  lda #<scr|", trigger: .manual)).contains("screen"))
    }

    func testMnemonicsAreNotOfferedInOperands() {
        let r = asm("  lda de|", trigger: .manual)
        XCTAssertFalse(r?.items.contains { $0.kind == .mnemonic } ?? false)
    }

    // MARK: - Assembly: when to stay quiet

    func testNoCompletionInCommentsStringsOrNumbers() {
        XCTAssertNil(asm("  lda #0 ; ld|"))
        XCTAssertNil(asm("; ld|"))
        XCTAssertNil(asm("  .byte \"ld|"))
        XCTAssertNil(asm("  lda #'l|"))
        XCTAssertNil(asm("  lda $d0|"))
        XCTAssertNil(asm("  lda #$de|"))
        XCTAssertNil(asm("  lda #%10|"))
        XCTAssertNil(asm("  lda 12|"))
        XCTAssertNil(asm("  l|"))
        XCTAssertNil(asm("  ld|a"))
        XCTAssertNil(asm("  lda|"))          // typed in full
        XCTAssertNil(asm("  lda #0\n  jmp |"))
        XCTAssertNotNil(asm("  .byte \"x\", chro|", trigger: .manual))
    }

    // MARK: - Ranking

    func testRankingPutsSameCasePrefixMatchesFirstThenAlphabetical() {
        let items = [CodeCompletion("Loop", .label), CodeCompletion("loop2", .label),
                     CodeCompletion("lamp", .label), CodeCompletion("LOAD", .keyword),
                     CodeCompletion("lo", .label)]
        XCTAssertEqual(CodeCompletionProvider.rank(items, word: "lo", trigger: .manual)?.map(\.text),
                       ["loop2", "LOAD", "Loop"])
        XCTAssertNil(CodeCompletionProvider.rank(items, word: "lo", trigger: .automatic))
        XCTAssertEqual(CodeCompletionProvider.rank(Array(items.dropLast()), word: "LO", trigger: .automatic)?.map(\.text),
                       ["LOAD", "Loop", "loop2"])
        XCTAssertNil(CodeCompletionProvider.rank(items, word: "zz", trigger: .manual))
    }
}
