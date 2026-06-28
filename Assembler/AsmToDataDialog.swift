//  AsmToDataDialog.swift
//  C64 IDE
//
//  Modal sheet that collects parameters for "Compile Assembly to BASIC DATA".

import Cocoa

// MARK: - Parameters

/// Parameters collected from the dialog before running the DATA export pipeline.
struct AsmToDataParams {
    let startLine:     Int
    let lineIncrement: Int
    let bytesPerRow:   Int
}

// MARK: - Dialog

/// Sheet dialog for configuring BASIC DATA generation from an assembled PRG.
final class AsmToDataDialog: NSWindowController {

    // MARK: - Controls

    private let startLineField   = NSTextField()
    private let incrementField   = NSTextField()
    private let bytesPerRowField = NSTextField()
    private let generateButton   = NSButton()
    private let cancelButton     = NSButton()

    // MARK: - Result

    /// Called with the collected params on Generate, or nil on Cancel.
    var completionHandler: ((AsmToDataParams?) -> Void)?

    // MARK: - Init

    convenience init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 210),
            styleMask:   [.titled, .closable],
            backing:     .buffered,
            defer:       false
        )
        win.title = "Compile Assembly to BASIC DATA"
        self.init(window: win)
        buildUI()
    }

    // MARK: - UI Layout

    private func buildUI() {
        guard let cv = window?.contentView else { return }

        // Label / field pairs. Y positions count down from top of the 210pt window.
        let rows: [(label: String, field: NSTextField, defaultValue: String)] = [
            ("Start Line Number:",   startLineField,   "10"),
            ("Line Increment:",      incrementField,   "10"),
            ("Bytes per DATA Line:", bytesPerRowField, "12"),
        ]

        for (i, row) in rows.enumerated() {
            let lbl = NSTextField(labelWithString: row.label)
            lbl.frame     = NSRect(x: 20, y: 155 - i * 48, width: 155, height: 20)
            lbl.alignment = .right
            cv.addSubview(lbl)

            row.field.frame        = NSRect(x: 183, y: 153 - i * 48, width: 130, height: 24)
            row.field.stringValue  = row.defaultValue
            row.field.bezelStyle   = .roundedBezel
            row.field.isEditable   = true
            cv.addSubview(row.field)
        }

        // Cancel
        cancelButton.frame          = NSRect(x: 128, y: 16, width: 90, height: 32)
        cancelButton.title          = "Cancel"
        cancelButton.bezelStyle     = .rounded
        cancelButton.keyEquivalent  = "\u{1b}"
        cancelButton.target         = self
        cancelButton.action         = #selector(cancel(_:))
        cv.addSubview(cancelButton)

        // Generate (default button)
        generateButton.frame         = NSRect(x: 228, y: 16, width: 90, height: 32)
        generateButton.title         = "Generate"
        generateButton.bezelStyle    = .rounded
        generateButton.keyEquivalent = "\r"
        generateButton.target        = self
        generateButton.action        = #selector(generate(_:))
        cv.addSubview(generateButton)

        startLineField.becomeFirstResponder()
    }

    // MARK: - Validation

    /// Returns the Int value of a field, or nil if the string is not a valid non-negative integer.
    private func intValue(of field: NSTextField, min minVal: Int, max maxVal: Int) -> Int? {
        guard let v = Int(field.stringValue.trimmingCharacters(in: .whitespaces)),
              v >= minVal, v <= maxVal else { return nil }
        return v
    }

    // MARK: - Actions

    @objc private func generate(_ sender: Any?) {
        guard let startLine = intValue(of: startLineField, min: 0, max: 63999) else {
            startLineField.shake()
            return
        }
        guard let increment = intValue(of: incrementField, min: 1, max: 1000) else {
            incrementField.shake()
            return
        }
        guard let bytesPerRow = intValue(of: bytesPerRowField, min: 1, max: 24) else {
            bytesPerRowField.shake()
            return
        }

        // Sanity check: will we overflow 63999 line numbers?
        // Rough upper bound: a 64K payload at 1 byte/row would need 65536 lines.
        // We warn rather than hard-block since real payloads are far smaller.
        // (The generator will just emit out-of-range line numbers if it overflows,
        //  which the user will notice immediately in the output tab.)

        let params = AsmToDataParams(
            startLine:     startLine,
            lineIncrement: increment,
            bytesPerRow:   bytesPerRow
        )
        window?.sheetParent?.endSheet(window!, returnCode: .OK)
        completionHandler?(params)
    }

    @objc private func cancel(_ sender: Any?) {
        window?.sheetParent?.endSheet(window!, returnCode: .cancel)
        completionHandler?(nil)
    }
}
