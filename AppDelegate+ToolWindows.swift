//  AppDelegate+ToolWindows.swift
//  C64 IDE
//
//  Handles opening and managing tool windows, file operations, BASIC dialect management,
//  and application UI actions.

import Cocoa
import SwiftUI

// MARK: - Tool Windows

extension AppDelegate {

    /// Opens or focuses the Sprite Editor window.
    @objc func openSpriteEditor(_ sender: Any?) {
        if spriteEditorController == nil { spriteEditorController = SpriteEditorWindowController() }
        spriteEditorController?.window?.makeKeyAndOrderFront(nil)
    }

    /// Opens or focuses the Character Set Editor window.
    @objc func openCharEditor(_ sender: Any?) {
        if charEditorController == nil { charEditorController = CharEditorWindowController() }
        charEditorController?.window?.makeKeyAndOrderFront(nil)
    }

    /// Opens or focuses the Source Debugger window.
    @MainActor
    @objc func openDebugger(_ sender: Any?) {
        if debuggerController == nil {
            debuggerController = DebuggerWindowController()
            if let debuggerVC = debuggerController?.window?.contentViewController as? DebuggerViewController {
                // Bind the editor line highlight callback once during initialization.
                debuggerVC.onDebugLineChanged = { [weak self] line in
                    if let line = line {
                        self?.mainWindowController?.highlightDebugLine(line)
                    } else {
                        self?.mainWindowController?.clearDebugHighlight()
                    }
                }
            }
        }

        // Refresh debug info whenever the debugger window opens to ensure
        // PC→line mapping matches the most recent build output.
        if let debuggerVC = debuggerController?.debuggerVC {
            debuggerVC.debugInfo = mainWindowController?.buildManager.lastDebugInfo

            // Attach to a live emulator session if one is already running.
            if debuggerVC.debugTarget == nil,
               let live = EmulatorCoordinator.shared.debuggable {
                debuggerVC.debugTarget = live
            }
        }

        debuggerController?.window?.makeKeyAndOrderFront(nil)
    }

    /// Opens or focuses the 6502 Disassembler window.
    @objc func openDisassembler(_ sender: Any?) {
        if disassemblerController == nil { disassemblerController = DisassemblerWindowController() }
        disassemblerController?.window?.makeKeyAndOrderFront(nil)
    }

    /// Opens the disassembler and loads a specific file (used by the D64 browser).
    func openDisassemblerWith(url: URL) {
        if disassemblerController == nil { disassemblerController = DisassemblerWindowController() }
        disassemblerController?.window?.makeKeyAndOrderFront(nil)
        if let vc = disassemblerController?.window?.contentViewController as? DisassemblerViewController {
            vc.loadFile(url)
        }
    }

    /// Opens or focuses the D64 Disk Image Browser window.
    @objc func openD64Browser(_ sender: Any?) {
        if diskBrowserController == nil { diskBrowserController = D64BrowserWindowController() }
        diskBrowserController?.window?.makeKeyAndOrderFront(nil)
    }

    /// Opens or focuses the TAP Tape Image Browser window.
    @objc func openTAPBrowser(_ sender: Any?) {
        if tapBrowserController == nil { tapBrowserController = TAPBrowserWindowController() }
        tapBrowserController?.window?.makeKeyAndOrderFront(nil)
    }

    /// Opens or focuses the SID Sound Chip Editor window.
    @objc func openSIDEditor(_ sender: Any?) {
        if sidEditorController == nil { sidEditorController = SIDEditorWindowController() }
        sidEditorController?.window?.makeKeyAndOrderFront(nil)
    }

    /// Opens or focuses the Graphics Editor window.
    @objc func openGfxEditor(_ sender: Any?) {
        if gfxEditorController == nil { gfxEditorController = GfxEditorWindowController() }
        gfxEditorController?.window?.makeKeyAndOrderFront(nil)
    }

    /// Opens or focuses the Number Base Converter window.
    @objc func openNumberConverter(_ sender: Any?) {
        if numberConverterController == nil { numberConverterController = NumberConverterWindowController() }
        numberConverterController?.window?.makeKeyAndOrderFront(nil)
    }

    /// Opens or focuses the PETSCII Character Map window.
    @objc func openPETSCIIMap(_ sender: Any?) {
        if petsciiMapController == nil { petsciiMapController = PETSCIIMapWindowController() }
        petsciiMapController?.window?.makeKeyAndOrderFront(nil)
    }

    /// Opens or focuses the Image Format Converter window.
    @objc func openImageConverter(_ sender: Any?) {
        if imageConverterController == nil { imageConverterController = ImageConverterWindowController() }
        imageConverterController?.window?.makeKeyAndOrderFront(nil)
    }

    /// Opens or focuses the ROM Character Set Viewer window.
    @objc func openCharROMViewer(_ sender: Any?) {
        if charROMViewerController == nil { charROMViewerController = CharROMViewerWindowController() }
        charROMViewerController?.window?.makeKeyAndOrderFront(nil)
    }

    /// Opens or focuses the Tile Map Editor window.
    @objc func openMapEditor(_ sender: Any?) {
        if mapEditorController == nil { mapEditorController = MapEditorWindowController() }
        mapEditorController?.window?.makeKeyAndOrderFront(nil)
    }

    /// Opens or focuses the Memory Map Viewer window.
    @objc func openMemoryMap(_ sender: Any?) {
        if memoryMapController == nil { memoryMapController = MemoryMapWindowController() }
        memoryMapController?.window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - File & Editor Actions

extension AppDelegate {

    /// Creates a new untitled BASIC file in a new tab or window.
    @objc func newBasicFile(_ sender: Any?) {
        if let wc = mainWindowController {
            wc.addNewTab(with: C64Document(fileType: .basic, content: ""))
        } else {
            openNewWindow()
        }
    }

    /// Creates a new assembly file with a standard BASIC stub and load address.
    @objc func newAssemblyFile(_ sender: Any?) {
        guard let wc = mainWindowController else { openNewWindow(); return }

        let dialect      = BasicDialectManager.shared.activeDialect
        let loadAddr     = dialect?.loadAddress ?? 0x0801
        let needsStub    = dialect?.requiresSYSStub ?? true
        let sysAddr      = dialect?.activationSYS ?? (loadAddr + 0x0C)

        let loadAddrHex  = String(format: "$%04X", loadAddr)
        let sysAddrStr   = String(sysAddr)
        let dialectNote  = dialect.map { "; dialect: \($0.name)" }
                           ?? "; dialect: Standard BASIC V2"

        var lines: [String] = [
            "; ── New Assembly Program ──",
            dialectNote,
            "",
            ".export __LOADADDR__: absolute = 1",
            "",
            ".segment \"LOADADDR\"",
            "    .word \(loadAddrHex)",
            "",
        ]

        if needsStub {
            let lineNum = 10
            lines += [
                ".segment \"STARTUP\"",
                "    ; BASIC stub: \(lineNum) SYS \(sysAddrStr)",
                "    .word @end",
                "    .word \(lineNum)",
                "    .byte $9E",
                "    .byte \"\(sysAddrStr)\",0",
                "@end:",
                "    .word 0",
                "",
            ]
        }

        lines += [
            ".segment \"CODE\"",
            "",
            "_start:",
            "    ; Your code here",
            "",
            "    rts",
        ]

        wc.addNewTab(with: C64Document(fileType: .assembly, content: lines.joined(separator: "\n")))
    }

    /// Closes the active editor tab.
    @objc func closeTab(_ sender: Any?) {
        mainWindowController?.closeActiveTab()
    }

    /// Opens a file picker for BASIC, assembly, or PRG files.
    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .init(filenameExtension: "bas")!,
            .init(filenameExtension: "asm")!,
            .init(filenameExtension: "s")!,
            .init(filenameExtension: "prg")!,
            .init(filenameExtension: "txt")!,
        ]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url {
                self?.mainWindowController?.loadDocument(from: url)
            }
        }
    }
}

// MARK: - BASIC Dialect & Plugins

extension AppDelegate {

    /// Switches the active BASIC dialect and updates syntax highlighting.
    @objc func selectDialect(_ sender: NSMenuItem) {
        let manager = BasicDialectManager.shared
        if sender.tag == -1 {
            manager.setActiveDialect(nil as BasicDialect?)
        } else if sender.tag < manager.availableDialects.count {
            manager.setActiveDialect(manager.availableDialects[sender.tag])
        }

        if let dialectMenu = sender.menu {
            for item in dialectMenu.items { item.state = item === sender ? .on : .off }
        }

        let name = manager.activeDialect?.name ?? "Standard BASIC V2"
        mainWindowController?.bottomPanelController.appendBuildOutput(
            "BASIC dialect: \(name) (\(manager.allKeywordNames.count) keywords)", type: .info)
    }

    /// Opens the plugin directory in Finder.
    @objc func openPluginsFolder(_ sender: Any?) {
        let dir = BasicDialectManager.pluginDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    /// Opens the Plugin Editor for the currently active dialect.
    @objc func openPluginEditor(_ sender: Any?) {
        if pluginEditorController == nil { pluginEditorController = PluginEditorWindowController() }

        if let activeDialect = BasicDialectManager.shared.activeDialect {
            let safeName = activeDialect.name.replacingOccurrences(of: " ", with: "_")
            let possibleURLs = [
                BasicDialectManager.pluginDirectory.appendingPathComponent("\(safeName).c64basic"),
                Bundle.main.resourceURL?.appendingPathComponent("\(safeName).c64basic"),
                Bundle.main.resourceURL?.appendingPathComponent("Plugins/\(safeName).c64basic"),
            ].compactMap { $0 }
            let sourceURL = possibleURLs.first { FileManager.default.fileExists(atPath: $0.path) }
            pluginEditorController?.loadDialect(activeDialect, from: sourceURL)
        }

        pluginEditorController?.window?.makeKeyAndOrderFront(nil)
    }

    /// Prompts the user to install a `.c64basic` plugin file.
    @objc func installPlugin(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "c64basic")!]
        panel.title = "Install BASIC Dialect Plugin"
        panel.message = "Select a .c64basic plugin file to install"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }

            guard let dialect = BasicDialectManager.shared.loadPlugin(from: url) else {
                let alert = NSAlert()
                alert.messageText = "Invalid Plugin"
                alert.informativeText = "The file could not be parsed as a valid .c64basic plugin."
                alert.alertStyle = .warning
                alert.runModal()
                return
            }

            let destDir = BasicDialectManager.pluginDirectory
            try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
            let destURL = destDir.appendingPathComponent(url.lastPathComponent)

            if FileManager.default.fileExists(atPath: destURL.path) {
                let existing = BasicDialectManager.shared.loadPlugin(from: destURL)
                let existingVer = existing?.version ?? "unknown"
                let newVer = dialect.version ?? "unknown"

                let alert = NSAlert()
                alert.messageText = "Plugin Already Installed"
                alert.informativeText = "\"\(dialect.name)\" is already installed (v\(existingVer)). Replace with v\(newVer)?"
                alert.addButton(withTitle: "Replace")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                try? FileManager.default.removeItem(at: destURL)
            }

            do {
                try FileManager.default.copyItem(at: url, to: destURL)
                BasicDialectManager.shared.addDialect(dialect)

                self?.mainWindowController?.bottomPanelController.appendBuildOutput(
                    "✓ Installed plugin: \(dialect.name) (\(dialect.keywords.count) keywords)", type: .success)

                let alert = NSAlert()
                alert.messageText = "Plugin Installed"
                alert.informativeText = "\"\(dialect.name)\" has been installed with \(dialect.keywords.count) keywords. Select it from Tools → BASIC Dialect."
                alert.runModal()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Installation Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    /// Opens the BASIC line renumbering dialog.
    @objc func renumberLines(_ sender: Any?) {
        mainWindowController?.editorViewController.performRenumber()
    }
}

// MARK: - View Actions

extension AppDelegate: NSMenuItemValidation {
    /// Validates menu items dynamically. Extend this method to add more validation rules.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(showProjectSettings(_:)) {
            return ProjectManager.shared.isProjectOpen
        }
        return true
    }
}

extension AppDelegate {

    /// Toggles the right-side reference panel.
    @objc func toggleReference(_ sender: Any?) {
        mainWindowController?.toggleRightPanel(sender)
    }

    /// Toggles the bottom console panel.
    @objc func toggleConsole(_ sender: Any?) {
        mainWindowController?.toggleBottomPanel(sender)
    }

    /// Opens the build and emulator preferences sheet.
    @objc func showPreferences(_ sender: Any?) {
        mainWindowController?.showBuildPreferences(sender)
    }

    /// Opens the active project settings sheet.
    @objc func showProjectSettings(_ sender: Any?) {
        mainWindowController?.showProjectSettings(sender)
    }

    /// Opens a SwiftUI-based font preferences sheet.
    @objc func showFontPreferences(_ sender: Any?) {
        let viewModel = EditorFontPreferencesViewModel()
        let hostingController = NSHostingController(rootView:
            EditorFontPreferencesView(viewModel: viewModel, onDismiss: { [weak self] in
                guard let self = self, let sheet = self.mainWindowController?.window?.attachedSheet else { return }
                self.mainWindowController?.window?.endSheet(sheet)
            })
        )
        let prefsWindow = NSWindow(contentViewController: hostingController)
        prefsWindow.title = "Editor Font"
        prefsWindow.styleMask = [.titled, .closable]
        prefsWindow.center()
        mainWindowController?.window?.beginSheet(prefsWindow) { _ in }
    }

    @objc func increaseFontSize(_ sender: Any?) { EditorFontManager.shared.increaseFontSize() }
    @objc func decreaseFontSize(_ sender: Any?) { EditorFontManager.shared.decreaseFontSize() }
    @objc func resetFontSize(_ sender: Any?)    { EditorFontManager.shared.resetToDefaults() }
}

// MARK: - About Panel

extension AppDelegate {

    /// Displays the custom About panel with version info, website, and contact links.
    @objc func showAboutPanel(_ sender: Any?) {
        if let panel = aboutPanel {
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 260),
            styleMask: NSWindow.StyleMask([.titled, .closable]),
            backing: .buffered,
            defer: false
        )
        panel.title = "About C64 IDE"
        panel.isReleasedWhenClosed = false
        panel.center()

        let container = NSView(frame: panel.contentView!.bounds)
        container.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(container)

        let iconView = NSImageView(frame: NSRect(x: 130, y: 180, width: 80, height: 80))
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        container.addSubview(iconView)

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""

        let nameLabel = NSTextField(labelWithString: "C64 IDE")
        nameLabel.font = NSFont.boldSystemFont(ofSize: 16)
        nameLabel.alignment = .center
        nameLabel.frame = NSRect(x: 20, y: 148, width: 300, height: 22)
        container.addSubview(nameLabel)

        let versionLabel = NSTextField(labelWithString: "Version \(version) (\(build))")
        versionLabel.font = NSFont.systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .center
        versionLabel.frame = NSRect(x: 20, y: 124, width: 300, height: 18)
        container.addSubview(versionLabel)

        let copyrightLabel = NSTextField(labelWithString: "© \(Calendar.current.component(.year, from: Date())) Gopher Broke Software")
        copyrightLabel.font = NSFont.systemFont(ofSize: 11)
        copyrightLabel.textColor = .secondaryLabelColor
        copyrightLabel.alignment = .center
        copyrightLabel.frame = NSRect(x: 20, y: 102, width: 300, height: 16)
        container.addSubview(copyrightLabel)

        let websiteButton = NSButton(frame: NSRect(x: 70, y: 64, width: 200, height: 24))
        websiteButton.title = "gopherbrokesoftware.com"
        websiteButton.bezelStyle = .inline
        websiteButton.isBordered = false
        websiteButton.contentTintColor = NSColor.linkColor
        websiteButton.font = NSFont.systemFont(ofSize: 13)
        websiteButton.target = self
        websiteButton.action = #selector(openWebsite(_:))
        container.addSubview(websiteButton)

        let contactButton = NSButton(frame: NSRect(x: 70, y: 36, width: 200, height: 24))
        contactButton.title = "Contact Developer"
        contactButton.bezelStyle = .inline
        contactButton.isBordered = false
        contactButton.contentTintColor = NSColor.linkColor
        contactButton.font = NSFont.systemFont(ofSize: 13)
        contactButton.target = self
        contactButton.action = #selector(contactDeveloper(_:))
        container.addSubview(contactButton)

        self.aboutPanel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    @objc func openWebsite(_ sender: Any?) {
        if let url = URL(string: "https://gopherbrokesoftware.com/") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func contactDeveloper(_ sender: Any?) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let subject = "C64 IDE Feedback - v.\(version)"
        let encoded = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject
        if let url = URL(string: "mailto:tknox@mac.com?subject=\(encoded)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        UpdateChecker.shared.checkForUpdates(silently: false)
    }
}

