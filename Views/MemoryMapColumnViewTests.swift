import XCTest
@testable import C64IDE

// ═══════════════════════════════════════════════════════════
// MARK: - MemoryMapColumnViewTests
// ═══════════════════════════════════════════════════════════

/// Guards the Memory Map column strip against the two failure modes that are
/// invisible until they bite: an address the 64K strip cannot hold (which used
/// to trap on unsigned underflow while drawing), and a hit test that disagrees
/// with the drawing order (which selected the wrong nested region).
final class MemoryMapColumnViewTests: XCTestCase {

    private func makeColumn(role: MemoryMapColumnView.Role = .planned) -> MemoryMapColumnView {
        let view = MemoryMapColumnView()
        view.role = role
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 2621)   // 64K at 0.04 px/byte
        return view
    }

    private func region(_ name: String, start: UInt32?, size: UInt32?,
                        startLiteral: Bool = true, sizeLiteral: Bool = true) -> CfgMemoryRegion {
        CfgMemoryRegion(
            name: name, start: start, size: size,
            rawStart: start.map { String(format: "$%04X", $0) } ?? "expr",
            rawSize:  size.map  { String(format: "$%04X", $0) } ?? "expr",
            file: "%O", isStartLiteral: startLiteral, isSizeLiteral: sizeLiteral
        )
    }

    /// Renders the view the way AppKit would, so an arithmetic trap in `draw`
    /// fails the test instead of shipping.
    private func render(_ view: MemoryMapColumnView) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return XCTFail("could not allocate a bitmap to draw into")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
    }

    // ═══════════════════════════════════════════════════════
    // MARK: - Address-space safety
    // ═══════════════════════════════════════════════════════

    /// Regression: `end` was clamped to $FFFF while `start` was not, so a region
    /// above the address space produced `end < start`, and `end - start` traps.
    func test_region_above_address_space_is_not_plotted() {
        let view = makeColumn()
        view.setLayout(memory: [region("REU", start: 0x10000, size: 0x1000)], segmentLoads: [])
        XCTAssertEqual(view.boxCount, 0)
        render(view)
    }

    func test_region_running_past_the_top_of_memory_is_clamped() {
        let view = makeColumn()
        view.setLayout(memory: [region("HUGE", start: 0xF000, size: 0xFFFF)], segmentLoads: [])
        XCTAssertEqual(view.boxCount, 1, "it starts inside memory, so it is drawn — clamped")
        render(view)
    }

    func test_pathological_size_does_not_trap() {
        let view = makeColumn()
        view.setLayout(memory: [region("BAD", start: 0x8000, size: UInt32.max)], segmentLoads: [])
        render(view)
    }

    func test_unresolved_start_is_not_plotted() {
        let view = makeColumn()
        view.setLayout(memory: [region("EXPR", start: nil, size: 0x100, startLiteral: false)],
                       segmentLoads: [])
        XCTAssertEqual(view.boxCount, 0)
        render(view)
    }

    func test_isPlottable_agrees_with_what_gets_drawn() {
        let regions = [
            region("OK",    start: 0x1000,  size: 0x100),
            region("HIGH",  start: 0x10000, size: 0x100),
            region("UNSET", start: nil,     size: 0x100, startLiteral: false),
        ]
        let view = makeColumn()
        view.setLayout(memory: regions, segmentLoads: [])
        XCTAssertEqual(view.boxCount, regions.filter(MemoryMapColumnView.isPlottable).count)
    }

    func test_built_column_survives_a_zero_size_segment() {
        let view = makeColumn(role: .built)
        // Defence in depth: MapFileParser normalises these, but the view must
        // not depend on that.
        view.setSegments([MapFileSegment(name: "EMPTY", start: 0x1000, end: 0x0FFF, size: 0)],
                         memoryRegions: [])
        XCTAssertEqual(view.boxCount, 0)
        render(view)
    }

    // ═══════════════════════════════════════════════════════
    // MARK: - Hit testing
    // ═══════════════════════════════════════════════════════

    /// Regression: drawing paints large regions first so small ones stay
    /// visible, but the hit test returned the last match in *data* order —
    /// clicking a nested region selected the enclosing one.
    func test_nested_region_wins_the_hit_test() {
        let view = makeColumn()
        view.pixelsPerByte = 0.04
        view.setLayout(memory: [
            region("MAIN", start: 0x0800, size: 0xC800),   // encloses…
            region("IO",   start: 0xD000, size: 0x1000),
            region("VIC",  start: 0xD000, size: 0x0040),   // …this one
        ], segmentLoads: [])

        let y = CGFloat(0xD010) * view.pixelsPerByte
        XCTAssertEqual(view.regionLabel(at: NSPoint(x: 100, y: y)), "VIC")
    }

    func test_address_gutter_is_not_click_targetable() {
        let view = makeColumn()
        view.setLayout(memory: [region("MAIN", start: 0x0000, size: 0x10000)], segmentLoads: [])
        let y = CGFloat(0x4000) * view.pixelsPerByte
        XCTAssertNil(view.regionLabel(at: NSPoint(x: 10, y: y)), "x=10 is inside the address gutter")
        XCTAssertEqual(view.regionLabel(at: NSPoint(x: 100, y: y)), "MAIN")
    }

    func test_empty_space_hits_nothing() {
        let view = makeColumn()
        view.setLayout(memory: [region("ZP", start: 0x0002, size: 0x001A)], segmentLoads: [])
        let y = CGFloat(0x8000) * view.pixelsPerByte
        XCTAssertNil(view.regionLabel(at: NSPoint(x: 100, y: y)))
    }

    // ═══════════════════════════════════════════════════════
    // MARK: - Selection lifecycle
    // ═══════════════════════════════════════════════════════

    /// Regression: a reload that removed the selected region cleared the view's
    /// highlight but never told the controller, leaving the inspector editing a
    /// region that no longer existed.
    func test_reload_dropping_the_selection_notifies_the_controller() {
        let view = makeColumn()
        view.setLayout(memory: [region("MAIN", start: 0x0800, size: 0x100)], segmentLoads: [])
        view.selectedLabel = "MAIN"

        var notified = false
        var reported: String? = "unset"
        view.onSelect = { notified = true; reported = $0 }

        view.setLayout(memory: [region("OTHER", start: 0x0800, size: 0x100)], segmentLoads: [])

        XCTAssertTrue(notified)
        XCTAssertNil(reported)
        XCTAssertNil(view.selectedLabel)
    }

    func test_reload_keeps_a_selection_that_still_exists() {
        let view = makeColumn()
        view.setLayout(memory: [region("MAIN", start: 0x0800, size: 0x100)], segmentLoads: [])
        view.selectedLabel = "MAIN"

        var notified = false
        view.onSelect = { _ in notified = true }
        view.setLayout(memory: [region("MAIN", start: 0x0900, size: 0x200)], segmentLoads: [])

        XCTAssertEqual(view.selectedLabel, "MAIN")
        XCTAssertFalse(notified, "an unchanged selection must not churn the inspector")
    }

    // ═══════════════════════════════════════════════════════
    // MARK: - Geometry
    // ═══════════════════════════════════════════════════════

    func test_address_and_y_round_trip() {
        let view = makeColumn()
        view.pixelsPerByte = 0.04
        for address: UInt32 in [0x0000, 0x0801, 0x8000, 0xFFFF] {
            XCTAssertEqual(view.address(atY: view.y(forAddress: address)), address)
        }
    }

    func test_address_is_clamped_to_the_address_space() {
        let view = makeColumn()
        view.pixelsPerByte = 0.04
        XCTAssertEqual(view.address(atY: -5000), 0)
        XCTAssertEqual(view.address(atY: 500_000), 0xFFFF)
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - MemoryMapViewControllerTests
// ═══════════════════════════════════════════════════════════

/// Smoke tests for the window's own layout. The controller positions every
/// control by hand from the view bounds, so a window small enough to make an
/// intermediate width or height go negative is the failure worth pinning.
final class MemoryMapViewControllerTests: XCTestCase {

    private func loadedController() -> MemoryMapViewController {
        let vc = MemoryMapViewController()
        _ = vc.view              // triggers loadView + viewDidLoad
        return vc
    }

    func test_builds_its_hierarchy_without_a_project() {
        let vc = loadedController()
        XCTAssertFalse(vc.view.subviews.isEmpty)
    }

    func test_survives_being_resized_very_small() {
        let vc = loadedController()
        vc.view.frame = NSRect(x: 0, y: 0, width: 120, height: 90)
        vc.view.layoutSubtreeIfNeeded()

        guard let rep = vc.view.bitmapImageRepForCachingDisplay(in: vc.view.bounds) else {
            return XCTFail("could not allocate a bitmap to draw into")
        }
        vc.view.cacheDisplay(in: vc.view.bounds, to: rep)
    }

    func test_survives_a_wide_resize() {
        let vc = loadedController()
        vc.view.frame = NSRect(x: 0, y: 0, width: 2400, height: 1400)
        vc.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(vc.view.subviews.isEmpty)
    }
}
