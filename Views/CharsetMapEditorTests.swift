// MARK: - CharsetMapEditorTests.swift
//
// Unit tests for the Character Set Editor data model, the charset payload
// that links it to the Map Editor, and the Map Editor's document logic.
//
// Test Philosophy:
//   Each test pins one rule that is easy to break by accident — bit-pair
//   packing in multi-color mode, the compositing rule shared by the exporter
//   and the bank-conflict check, and the repairs applied to a decoded map.

import XCTest
@testable import C64IDE

// MARK: - Character Set Data

final class CharSetDataTests: XCTestCase {

    private func makeSet(row0: UInt8) -> CharSetData {
        let data = CharSetData()
        data.characters[1] = [row0, 0, 0, 0, 0, 0, 0, 0]
        return data
    }

    func test_hires_pixel_roundtrip() {
        let data = CharSetData()
        data.setPixel(char: 1, row: 0, col: 0, value: 1)
        data.setPixel(char: 1, row: 0, col: 7, value: 1)
        XCTAssertEqual(data.characters[1][0], 0x81)
        XCTAssertEqual(data.getPixel(char: 1, row: 0, col: 0), 1)
        XCTAssertEqual(data.getPixel(char: 1, row: 0, col: 3), 0)
    }

    func test_multicolor_pixel_roundtrip() {
        let data = CharSetData()
        data.isMultiColor = true
        for (col, value) in [(0, UInt8(0)), (1, 1), (2, 2), (3, 3)] {
            data.setMultiPixel(char: 1, row: 0, col: col, value: value)
        }
        XCTAssertEqual(data.characters[1][0], 0b00_01_10_11)
        for col in 0..<4 {
            XCTAssertEqual(data.getMultiPixel(char: 1, row: 0, col: col), UInt8(col))
        }
    }

    func test_out_of_range_indices_are_ignored() {
        let data = CharSetData()
        XCTAssertEqual(data.getPixel(char: -1, row: 0, col: 0), 0)
        XCTAssertEqual(data.getPixel(char: 256, row: 0, col: 0), 0)
        XCTAssertEqual(data.value(char: 1, row: -1, col: -1), 0)
        // Must not trap.
        data.setPixel(char: -1, row: 0, col: 0, value: 1)
        data.setValue(char: 1, row: 0, col: -1, value: 1)
        data.clearChar(-1)
        data.invertChar(999)
    }

    func test_column_count_follows_mode() {
        let data = CharSetData()
        XCTAssertEqual(data.columnCount, 8)
        data.isMultiColor = true
        XCTAssertEqual(data.columnCount, 4)
    }

    func test_palette_index_mapping() {
        let data = CharSetData()
        data.bgColor = 6; data.fgColor = 14
        data.multiColor1 = 1; data.multiColor2 = 11

        XCTAssertEqual(data.paletteIndex(forValue: 0), 6)
        XCTAssertEqual(data.paletteIndex(forValue: 1), 14)

        data.isMultiColor = true
        XCTAssertEqual(data.paletteIndex(forValue: 0), 6)   // $D021
        XCTAssertEqual(data.paletteIndex(forValue: 1), 1)   // $D022
        XCTAssertEqual(data.paletteIndex(forValue: 2), 11)  // $D023
        XCTAssertEqual(data.paletteIndex(forValue: 3), 14)  // color RAM
    }

    func test_mirror_h_reverses_bits_in_hires() {
        let data = makeSet(row0: 0b1101_0000)
        data.mirrorHChar(1)
        XCTAssertEqual(data.characters[1][0], 0b0000_1011)
    }

    func test_mirror_h_reverses_pixel_pairs_in_multicolor() {
        let data = makeSet(row0: 0b00_01_10_11)
        data.isMultiColor = true
        data.mirrorHChar(1)
        // Whole 2-bit pixels are reversed, so the colors survive the flip.
        XCTAssertEqual(data.characters[1][0], 0b11_10_01_00)
    }

    func test_mirror_v_reverses_rows() {
        let data = CharSetData()
        data.characters[1] = [1, 2, 3, 4, 5, 6, 7, 8]
        data.mirrorVChar(1)
        XCTAssertEqual(data.characters[1], [8, 7, 6, 5, 4, 3, 2, 1])
    }

    func test_shift_wraps_one_bit_in_hires() {
        let data = makeSet(row0: 0b1000_0001)
        data.shiftChar(1, dx: 1, dy: 0)
        XCTAssertEqual(data.characters[1][0], 0b1100_0000)
        data.shiftChar(1, dx: -1, dy: 0)
        XCTAssertEqual(data.characters[1][0], 0b1000_0001)
    }

    func test_shift_wraps_one_pixel_pair_in_multicolor() {
        let data = makeSet(row0: 0b00_01_10_11)
        data.isMultiColor = true
        data.shiftChar(1, dx: 1, dy: 0)
        XCTAssertEqual(data.characters[1][0], 0b11_00_01_10)
        data.shiftChar(1, dx: -1, dy: 0)
        XCTAssertEqual(data.characters[1][0], 0b00_01_10_11)
    }

    func test_shift_vertical_wraps_rows() {
        let data = CharSetData()
        data.characters[1] = [1, 2, 3, 4, 5, 6, 7, 8]
        data.shiftChar(1, dx: 0, dy: -1)
        XCTAssertEqual(data.characters[1], [2, 3, 4, 5, 6, 7, 8, 1])
        data.shiftChar(1, dx: 0, dy: 1)
        XCTAssertEqual(data.characters[1], [1, 2, 3, 4, 5, 6, 7, 8])
    }

    func test_rom_sets_are_distinct_and_complete() {
        let upper = CharSetData()
        upper.loadROMCharset(.uppercaseGraphics)
        let lower = CharSetData()
        lower.loadROMCharset(.lowercaseUppercase)

        XCTAssertEqual(upper.toBytes().count, CharSetData.byteCount)
        XCTAssertEqual(lower.toBytes().count, CharSetData.byteCount)
        XCTAssertNotEqual(upper.characters, lower.characters)
        // Char 1 is "A" in set 1 and "a" in set 2.
        XCTAssertNotEqual(upper.characters[1], lower.characters[1])
        // The editor's default set must match what the Map Editor falls back
        // to, or "Send to Map Editor" would visibly change an untouched map.
        XCTAssertEqual(Data(upper.toBytes()), C64ROMCharset.data)
    }

    func test_deep_copy_is_independent() {
        let data = CharSetData()
        data.characters[5] = [1, 2, 3, 4, 5, 6, 7, 8]
        let copy = data.deepCopy()
        data.characters[5] = Array(repeating: 0, count: 8)
        XCTAssertEqual(copy.characters[5], [1, 2, 3, 4, 5, 6, 7, 8])
    }
}

// MARK: - Charset Import

final class CharsetImportTests: XCTestCase {

    func test_accepts_exact_charset() {
        let raw = Data(repeating: 0xAB, count: 2048)
        XCTAssertEqual(CharEditorViewController.extractCharset(from: raw)?.count, 2048)
    }

    func test_strips_prg_load_address() {
        var raw = Data([0x00, 0x30])              // load address $3000
        raw.append(Data(repeating: 0xCD, count: 2048))
        let bytes = CharEditorViewController.extractCharset(from: raw)
        XCTAssertEqual(bytes?.count, 2048)
        XCTAssertEqual(bytes?.first, 0xCD, "the load address must not leak into char 0")
    }

    func test_strips_load_address_from_full_4k_rom_dump() {
        var raw = Data([0x00, 0xD0])
        raw.append(Data(repeating: 0xEF, count: 4096))
        XCTAssertEqual(CharEditorViewController.extractCharset(from: raw)?.first, 0xEF)
    }

    func test_keeps_headerless_4k_file_intact() {
        var raw = Data(repeating: 0x11, count: 2048)
        raw.append(Data(repeating: 0x22, count: 2048))
        XCTAssertEqual(CharEditorViewController.extractCharset(from: raw)?.first, 0x11)
    }

    func test_rejects_short_files() {
        XCTAssertNil(CharEditorViewController.extractCharset(from: Data(repeating: 0, count: 100)))
        XCTAssertNil(CharEditorViewController.extractCharset(from: Data()))
    }
}

// MARK: - Charset Payload (Character Editor ↔ Map Editor link)

final class CharsetPayloadTests: XCTestCase {

    func test_payload_survives_a_notification_roundtrip() {
        let source = CharSetData()
        source.loadROMCharset(.uppercaseGraphics)
        source.fgColor = 3
        source.bgColor = 9
        source.isMultiColor = true
        source.multiColor1 = 7
        source.multiColor2 = 12

        let note = Notification(name: .charsetDidChange, object: nil, userInfo: source.payload.userInfo)
        let decoded = CharsetPayload(notification: note)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.charset, Data(source.toBytes()))
        XCTAssertEqual(decoded?.fgColor, 3)
        XCTAssertEqual(decoded?.bgColor, 9)
        XCTAssertEqual(decoded?.isMultiColor, true)
        XCTAssertEqual(decoded?.multiColor1, 7)
        XCTAssertEqual(decoded?.multiColor2, 12)
    }

    func test_payload_rejects_an_undersized_charset() {
        let note = Notification(name: .charsetDidChange, object: nil,
                                userInfo: ["charsetData": Data(repeating: 0, count: 16)])
        XCTAssertNil(CharsetPayload(notification: note))
    }

    func test_payload_rejects_missing_data() {
        let note = Notification(name: .charsetDidChange, object: nil, userInfo: ["fgColor": 1])
        XCTAssertNil(CharsetPayload(notification: note))
    }

    func test_payload_rebases_a_data_slice() {
        // A slice with a nonzero startIndex would make integer subscripting
        // downstream read past the end.
        let sliced = Data(repeating: 0x55, count: 2050).dropFirst(2)
        let note = Notification(name: .charsetDidChange, object: nil, userInfo: ["charsetData": sliced])
        let payload = CharsetPayload(notification: note)
        XCTAssertEqual(payload?.charset.startIndex, 0)
        XCTAssertEqual(payload?.charset.count, 2048)
    }
}

// MARK: - Map Document

final class MapDocumentTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MapDocumentTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Saves `document`, applies `edit` to the raw JSON, and returns the file.
    private func writeMutated(_ document: MapDocument,
                              _ edit: (inout [String: Any]) -> Void) throws -> URL {
        let url = scratch.appendingPathComponent("map.c64map")
        try document.save(to: url)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        edit(&json)
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        return url
    }

    func test_roundtrips_through_disk() throws {
        let doc = MapDocument(width: 5, height: 4)
        doc.setTile(0x41, color: 7, atCol: 2, row: 1)
        doc.isMultiColorMode = true
        doc.extraColor1 = 3
        let url = scratch.appendingPathComponent("rt.c64map")
        try doc.save(to: url)

        let loaded = try MapDocument.load(from: url)
        XCTAssertEqual(loaded.width, 5)
        XCTAssertEqual(loaded.height, 4)
        XCTAssertEqual(loaded.tile(atCol: 2, row: 1), 0x41)
        XCTAssertEqual(loaded.color(atCol: 2, row: 1), 7)
        XCTAssertTrue(loaded.isMultiColorMode)
        XCTAssertEqual(loaded.extraColor1, 3)
    }

    func test_load_repairs_ragged_layers() throws {
        let url = try writeMutated(MapDocument(width: 4, height: 3)) { json in
            var layers = json["layers"] as! [[String: Any]]
            layers[0]["tiles"] = [[9, 9]]     // 1×2 instead of 3×4
            layers[0]["colors"] = [[5, 5]]
            json["layers"] = layers
        }

        let loaded = try MapDocument.load(from: url)
        XCTAssertEqual(loaded.layers[0].tiles.count, 3)
        XCTAssertEqual(loaded.layers[0].tiles[0].count, 4)
        XCTAssertEqual(loaded.layers[0].tiles[0][0], 9, "overlapping cells are preserved")
        XCTAssertEqual(loaded.layers[0].tiles[2][3], 0x20, "new cells are filled with spaces")
    }

    func test_load_replaces_an_empty_layer_list() throws {
        let url = try writeMutated(MapDocument(width: 4, height: 3)) { json in
            json["layers"] = [[String: Any]]()
        }
        let loaded = try MapDocument.load(from: url)
        XCTAssertEqual(loaded.layers.count, 1)
        XCTAssertEqual(loaded.layers[0].tiles.count, 3)
    }

    func test_load_clamps_an_out_of_range_active_layer() throws {
        let url = try writeMutated(MapDocument(width: 4, height: 3)) { json in
            json["activeLayerIndex"] = 17
        }
        let loaded = try MapDocument.load(from: url)
        XCTAssertEqual(loaded.activeLayerIndex, 0)
        XCTAssertNotNil(loaded.activeLayer)
    }

    func test_load_rejects_invalid_dimensions() throws {
        let url = try writeMutated(MapDocument(width: 4, height: 3)) { json in
            json["width"] = 0
        }
        XCTAssertThrowsError(try MapDocument.load(from: url))
    }

    func test_load_rejects_a_future_format_version() throws {
        let url = try writeMutated(MapDocument(width: 4, height: 3)) { json in
            json["formatVersion"] = MapDocument.formatVersion + 1
        }
        XCTAssertThrowsError(try MapDocument.load(from: url))
    }

    func test_resize_clamps_and_preserves_overlap() {
        let doc = MapDocument(width: 4, height: 4)
        doc.setTile(0x41, color: 2, atCol: 1, row: 1)
        doc.resize(to: 0, height: 10_000)
        XCTAssertEqual(doc.width, 1)
        XCTAssertEqual(doc.height, MapDocument.maxDimension)

        let wide = MapDocument(width: 4, height: 4)
        wide.setTile(0x41, color: 2, atCol: 1, row: 1)
        wide.resize(to: 8, height: 8)
        XCTAssertEqual(wide.tile(atCol: 1, row: 1), 0x41)
        XCTAssertEqual(wide.tile(atCol: 7, row: 7), 0x20)
    }

    func test_remove_layer_ignores_an_out_of_range_index() {
        let doc = MapDocument(width: 2, height: 2)
        doc.addLayer()
        doc.removeLayer(at: 99)
        doc.removeLayer(at: -1)
        XCTAssertEqual(doc.layers.count, 2)
    }

    func test_remove_layer_keeps_at_least_one() {
        let doc = MapDocument(width: 2, height: 2)
        doc.removeLayer(at: 0)
        XCTAssertEqual(doc.layers.count, 1)
    }

    func test_export_uses_the_lowest_visible_layer_as_the_base() {
        let doc = MapDocument(width: 2, height: 1)
        doc.layers[0].isVisible = false
        doc.layers[0].tiles[0] = [0x41, 0x41]
        doc.addLayer()
        doc.layers[1].tiles[0] = [0x20, 0x42]
        doc.layers[1].colors[0] = [7, 7]

        let (screen, color) = doc.exportFlattened()
        XCTAssertEqual(Array(screen), [0x20, 0x42])
        // The lowest *visible* layer owns every cell, spaces included, so its
        // color reaches color RAM instead of the default.
        XCTAssertEqual(Array(color), [7, 7])
    }

    func test_upper_layer_spaces_let_lower_layers_through() {
        let doc = MapDocument(width: 2, height: 1)
        doc.layers[0].tiles[0] = [0x41, 0x41]
        doc.layers[0].colors[0] = [1, 1]
        doc.addLayer()
        doc.layers[1].tiles[0] = [0x20, 0x42]
        doc.layers[1].colors[0] = [7, 7]

        let (screen, color) = doc.exportFlattened()
        XCTAssertEqual(Array(screen), [0x41, 0x42])
        XCTAssertEqual(Array(color), [1, 7])
    }

    func test_composited_tile_matches_the_exporter() {
        let doc = MapDocument(width: 3, height: 2)
        doc.layers[0].tiles = [[0x41, 0x42, 0x43], [0x44, 0x45, 0x46]]
        doc.addLayer()
        doc.layers[1].tiles = [[0x20, 0x81, 0x20], [0x20, 0x20, 0x82]]

        let (screen, _) = doc.exportFlattened()
        for row in 0..<doc.height {
            for col in 0..<doc.width {
                XCTAssertEqual(doc.compositedTile(col: col, row: row),
                               screen[row * doc.width + col],
                               "cell \(col),\(row)")
            }
        }
    }

    func test_bank_status_reports_a_single_bank() {
        let doc = MapDocument(width: 2, height: 1)
        XCTAssertEqual(doc.charsetBankStatus(), .clean, "an all-spaces map uses neither bank")

        doc.layers[0].tiles[0] = [0x41, 0x20]
        XCTAssertEqual(doc.charsetBankStatus(), .bankZeroOnly)

        doc.layers[0].tiles[0] = [0x81, 0x20]
        XCTAssertEqual(doc.charsetBankStatus(), .bankOneOnly)
    }

    func test_bank_status_reports_mixed_banks() {
        let doc = MapDocument(width: 2, height: 1)
        doc.layers[0].tiles[0] = [0x41, 0x81]
        XCTAssertEqual(doc.charsetBankStatus(), .mixed)
    }

    func test_bank_status_ignores_tiles_hidden_behind_an_upper_layer() {
        let doc = MapDocument(width: 1, height: 1)
        doc.layers[0].tiles[0] = [0x41]        // bank 0, fully covered
        doc.addLayer()
        doc.layers[1].tiles[0] = [0x81]        // bank 1 wins the cell
        XCTAssertEqual(doc.charsetBankStatus(), .bankOneOnly)
    }

    func test_bank_status_ignores_invisible_layers() {
        let doc = MapDocument(width: 1, height: 1)
        doc.layers[0].tiles[0] = [0x41]
        doc.addLayer()
        doc.layers[1].tiles[0] = [0x81]
        doc.layers[1].isVisible = false
        XCTAssertEqual(doc.charsetBankStatus(), .bankZeroOnly)
    }

    func test_assembly_export_sanitizes_the_label() {
        let doc = MapDocument(width: 1, height: 1)
        let asm = doc.exportAsAssembly(label: "9 my map!")
        XCTAssertTrue(asm.contains("_9_my_map__screen:"), asm)
        XCTAssertFalse(asm.contains("!"))
    }

    func test_assembly_export_emits_multicolor_registers_only_when_enabled() {
        let doc = MapDocument(width: 1, height: 1)
        XCTAssertFalse(doc.exportAsAssembly(label: "m").contains("$D022"))
        doc.isMultiColorMode = true
        XCTAssertTrue(doc.exportAsAssembly(label: "m").contains("$D022"))
    }
}

// MARK: - Palette

final class C64PaletteTests: XCTestCase {

    func test_map_and_character_editors_share_one_palette() {
        XCTAssertEqual(C64Palette.colors.count, C64Reference.colorPalette.count)
        for (index, reference) in C64Reference.colorPalette.enumerated() {
            let rgb = C64Palette.rgb(for: index)
            XCTAssertEqual(Int(rgb.r), reference.rgb.r, "red for color \(index)")
            XCTAssertEqual(Int(rgb.g), reference.rgb.g, "green for color \(index)")
            XCTAssertEqual(Int(rgb.b), reference.rgb.b, "blue for color \(index)")
        }
    }

    func test_color_index_is_masked_to_four_bits() {
        XCTAssertEqual(C64Palette.nsColor(for: 16), C64Palette.nsColor(for: 0))
        XCTAssertEqual(C64Palette.nsColor(for: 255), C64Palette.nsColor(for: 15))
    }
}

// MARK: - Glyph Cache

final class GlyphCacheTests: XCTestCase {

    func test_returns_a_cached_image_per_character_and_color() {
        let cache = GlyphCache()
        let first = cache.image(tile: 1, colorIndex: 14, multiColor: false)
        let second = cache.image(tile: 1, colorIndex: 14, multiColor: false)
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second, "the same request must reuse the cached image")
        XCTAssertFalse(first === cache.image(tile: 1, colorIndex: 3, multiColor: false))
        XCTAssertFalse(first === cache.image(tile: 1, colorIndex: 14, multiColor: true))
    }

    func test_changing_the_charset_rebuilds_glyphs() {
        let cache = GlyphCache()
        let rom = cache.image(tile: 1, colorIndex: 1, multiColor: false)
        cache.setCharset(Data(repeating: 0xFF, count: CharSetData.byteCount))
        XCTAssertFalse(rom === cache.image(tile: 1, colorIndex: 1, multiColor: false))
    }

    func test_glyph_pixels_are_stored_bottom_up_for_a_flipped_view() throws {
        // MapGridView and TilePickerView are flipped, and CGContext.draw
        // mirrors images vertically under a flipped CTM — so a glyph whose
        // top row is set must occupy the *last* scanline of the image.
        let cache = GlyphCache()
        var charset = [UInt8](repeating: 0, count: CharSetData.byteCount)
        charset[8] = 0xFF                      // char 1, top row solid
        cache.setCharset(Data(charset))
        let image = try XCTUnwrap(cache.image(tile: 1, colorIndex: 1, multiColor: false))

        let pixels = try XCTUnwrap(image.dataProvider?.data as Data?)
        XCTAssertEqual(pixels.count, 8 * 8 * 4)
        let alpha = { (row: Int, col: Int) in pixels[(row * 8 + col) * 4 + 3] }
        XCTAssertEqual(alpha(7, 0), 255, "the glyph's top row belongs on the image's last scanline")
        XCTAssertEqual(alpha(0, 0), 0)
    }
}
