import XCTest
@testable import C64IDE

// ═══════════════════════════════════════════════════════════
// MARK: - ReferencePanelDialectTests
// ═══════════════════════════════════════════════════════════

/// Covers the reference panel's Commands tab tracking the active BASIC dialect.
///
/// This wiring is easy to lose: the panel built its list once in `viewDidLoad`
/// from a fixed BASIC V2 table, so selecting Simons' BASIC changed tokenizing,
/// highlighting and tooltips but left the documented keyword list on V2. These
/// tests exercise the real `CommandListViewController` against the real bundled
/// plugins, so the list and the `.basicDialectDidChange` notification that
/// refreshes it stay connected.
final class ReferencePanelDialectTests: XCTestCase {

    private var previousDialect: BasicDialect?

    override func setUp() {
        super.setUp()
        previousDialect = BasicDialectManager.shared.activeDialect
        // The test host is the app itself, so the bundled .c64basic plugins
        // are on disk in its Resources.
        if BasicDialectManager.shared.availableDialects.isEmpty {
            BasicDialectManager.shared.loadDefaultPlugins()
        }
    }

    override func tearDown() {
        BasicDialectManager.shared.setActiveDialect(previousDialect)
        super.tearDown()
    }

    // ── Helpers ────────────────────────────────────────────

    /// A fully loaded panel. Touching `view` forces `loadView` and `viewDidLoad`,
    /// which build the entries and subscribe to dialect changes.
    /// (`loadViewIfNeeded()` would be clearer but needs macOS 14; this project
    /// deploys to 13.3.)
    private func makeLoadedPanel() -> CommandListViewController {
        let vc = CommandListViewController()
        _ = vc.view
        return vc
    }

    private func keywords(_ panel: CommandListViewController) -> Set<String> {
        Set(panel.basicEntries.map(\.keyword))
    }

    private func dialect(named name: String) throws -> BasicDialect {
        try XCTUnwrap(BasicDialectManager.shared.availableDialects.first { $0.name == name },
                      "\(name) plugin should be bundled with the app")
    }

    // ═══════════════════════════════════════════════════════
    // MARK: Baseline — standard BASIC V2
    // ═══════════════════════════════════════════════════════

    func test_standardV2_listsV2KeywordsOnly() {
        BasicDialectManager.shared.setActiveDialect(nil)
        let panel = makeLoadedPanel()

        XCTAssertTrue(keywords(panel).contains("PRINT"))
        XCTAssertTrue(keywords(panel).contains("POKE"))
        XCTAssertFalse(keywords(panel).contains("HIRES"),
                       "A Simons' BASIC keyword must not show under standard V2")
    }

    // ═══════════════════════════════════════════════════════
    // MARK: Switching dialect
    // ═══════════════════════════════════════════════════════

    func test_selectingDialect_addsItsKeywords() throws {
        BasicDialectManager.shared.setActiveDialect(nil)
        let panel = makeLoadedPanel()
        let v2Count = panel.basicEntries.count

        BasicDialectManager.shared.setActiveDialect(try dialect(named: "Simons' BASIC"))

        XCTAssertGreaterThan(panel.basicEntries.count, v2Count,
                             "Selecting a dialect should extend the list")
        XCTAssertTrue(keywords(panel).contains("HIRES"))
        XCTAssertTrue(keywords(panel).contains("CIRCLE"))
        XCTAssertTrue(keywords(panel).contains("PRINT"),
                      "Simons' extends V2, so V2 keywords remain listed")
    }

    func test_switchingBackToV2_dropsDialectKeywords() throws {
        let panel = makeLoadedPanel()
        BasicDialectManager.shared.setActiveDialect(try dialect(named: "Simons' BASIC"))
        XCTAssertTrue(keywords(panel).contains("HIRES"))

        BasicDialectManager.shared.setActiveDialect(nil)
        XCTAssertFalse(keywords(panel).contains("HIRES"))
        XCTAssertTrue(keywords(panel).contains("PRINT"))
    }

    func test_switchingBetweenDialects_doesNotAccumulate() throws {
        let panel = makeLoadedPanel()

        BasicDialectManager.shared.setActiveDialect(try dialect(named: "Simons' BASIC"))
        let simonsCount = panel.basicEntries.count

        BasicDialectManager.shared.setActiveDialect(try dialect(named: "VIC-20 Super Expander"))
        XCTAssertFalse(keywords(panel).contains("HIRES"),
                       "Keywords from the previous dialect must be cleared")

        BasicDialectManager.shared.setActiveDialect(try dialect(named: "Simons' BASIC"))
        XCTAssertEqual(panel.basicEntries.count, simonsCount,
                       "Rebuilding must replace the list, not append to it")
    }

    // ═══════════════════════════════════════════════════════
    // MARK: Entry content
    // ═══════════════════════════════════════════════════════

    func test_dialectEntry_carriesPluginDocumentation() throws {
        BasicDialectManager.shared.setActiveDialect(try dialect(named: "Simons' BASIC"))
        let panel = makeLoadedPanel()

        let hires = try XCTUnwrap(panel.basicEntries.first { $0.keyword == "HIRES" })
        XCTAssertTrue(hires.detail.contains("Simons' BASIC"), "Detail names the dialect")
        XCTAssertTrue(hires.detail.contains("SYNTAX"))
        XCTAssertTrue(hires.detail.contains("DESCRIPTION"))
        XCTAssertTrue(hires.detail.contains("PARAMETERS"), "HIRES documents mode and color")
        XCTAssertTrue(hires.detail.contains("EXAMPLE"))
        XCTAssertTrue(hires.detail.contains("TOKEN"), "Prefixed token should be reported")
    }

    func test_v2EntriesKeepTheirOwnFormatting() {
        BasicDialectManager.shared.setActiveDialect(nil)
        let panel = makeLoadedPanel()

        let printEntry = panel.basicEntries.first { $0.keyword == "PRINT" }
        XCTAssertNotNil(printEntry)
        XCTAssertFalse(printEntry?.detail.contains("Dialect:") ?? true,
                       "Built-in V2 entries are not attributed to a plugin")
    }

    // ═══════════════════════════════════════════════════════
    // MARK: Search interaction
    // ═══════════════════════════════════════════════════════

    func test_activeSearchSurvivesDialectChange() throws {
        BasicDialectManager.shared.setActiveDialect(nil)
        let panel = makeLoadedPanel()
        panel.filter(by: "CIRCLE")
        // The filter also searches the detail text, so assert on the keyword
        // rather than on an empty result -- a V2 entry is free to mention the
        // word in its notes without CIRCLE becoming a V2 keyword.
        XCTAssertFalse(panel.filteredEntries.contains { $0.keyword == "CIRCLE" },
                       "CIRCLE is not a V2 keyword")

        BasicDialectManager.shared.setActiveDialect(try dialect(named: "Simons' BASIC"))
        XCTAssertTrue(panel.filteredEntries.contains { $0.keyword == "CIRCLE" },
                      "The filter should be re-applied to the rebuilt list")
    }

    // ═══════════════════════════════════════════════════════
    // MARK: Every bundled dialect
    // ═══════════════════════════════════════════════════════

    func test_everyBundledDialectContributesDocumentedKeywords() {
        let panel = makeLoadedPanel()
        BasicDialectManager.shared.setActiveDialect(nil)
        let v2 = keywords(panel)

        for dialect in BasicDialectManager.shared.availableDialects {
            BasicDialectManager.shared.setActiveDialect(dialect)
            let listed = keywords(panel)
            XCTAssertTrue(v2.isSubset(of: listed),
                          "\(dialect.name): V2 keywords should still be listed")
            let added = listed.subtracting(v2)
            XCTAssertFalse(added.isEmpty, "\(dialect.name): should contribute keywords")
        }
    }

    // ═══════════════════════════════════════════════════════
    // MARK: V2 reference completeness
    // ═══════════════════════════════════════════════════════

    /// The Commands tab is the only place a V2 keyword is documented, so a
    /// keyword the tokenizer knows but the reference does not is invisible to
    /// the user. `BasicTokenizer.tokenTable` is the authoritative $80-$CB list.
    func test_everyV2TokenIsDocumented() {
        for (keyword, token) in BasicTokenizer.tokenTable {
            // TAB( and SPC( carry the opening parenthesis in the token; the
            // reference documents them under the bare keyword.
            let key = keyword.hasSuffix("(") ? String(keyword.dropLast()) : keyword
            guard let ref = C64BasicSyntax.commandReference[key] else {
                XCTFail("No reference entry for V2 keyword \(keyword)")
                continue
            }
            XCTAssertEqual(ref.token, token,
                           "\(keyword): documented token does not match the tokenizer's")
        }
    }

    /// Every entry should carry the sections the reference panel renders, so
    /// that built-in V2 keywords read the same as dialect plugin keywords.
    func test_everyV2EntryHasSyntaxExampleAndNotes() {
        for (key, ref) in C64BasicSyntax.commandReference {
            XCTAssertEqual(key, ref.keyword, "Dictionary key and keyword should agree")
            XCTAssertFalse(ref.syntax.isEmpty, "\(key): missing syntax")
            XCTAssertFalse(ref.description.isEmpty, "\(key): missing description")
            XCTAssertFalse(ref.example?.isEmpty ?? true, "\(key): missing example")
            XCTAssertFalse(ref.notes?.isEmpty ?? true, "\(key): missing notes")
        }
    }

    /// The four entries that are documented but are not ROM tokens: the
    /// reserved variables, and GET#, which crunches as GET plus a "#".
    func test_nonTokenEntriesCarryNoTokenByte() {
        for key in ["TI", "TI$", "ST", "GET#"] {
            guard let ref = C64BasicSyntax.commandReference[key] else {
                XCTFail("\(key) should be documented")
                continue
            }
            XCTAssertNil(ref.token, "\(key) is not a BASIC V2 token")
        }
    }
}
