//  AppDelegate+BuildActions.swift
//  C64 IDE
//
//  Build, run, debug, and disk export actions.

import Cocoa

extension AppDelegate {

    // MARK: - Build & Run Actions

    /// Triggers a standard Build & Run cycle.
    @objc func buildAndRun(_ sender: Any?) {
        mainWindowController?.performBuildAndRun(sender)
    }

    /// Builds the current file and launches it with source-level debugging enabled.
    @MainActor
    @objc func buildAndDebug(_ sender: Any?) {
        guard let wc = mainWindowController else { return }

        // Debugging requires a saved source file to generate debug info.
        guard let sourceURL = wc.editorViewController.document.fileURL else {
            wc.bottomPanelController.appendBuildOutput(
                "Save the file before Build & Debug.", type: .warning)
            wc.editorViewController.saveDocumentAs { [weak self] success in
                if success { Task { @MainActor in self?.buildAndDebug(sender) } }
            }
            return
        }

        let fileType = wc.editorViewController.document.fileType

        // Source-level debugging relies on assembler debug info (.dbg).
        // BASIC is tokenized at runtime, so there's no instruction-to-line mapping.
        guard !fileType.usesBasicHighlighting else {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Build & Debug is for Assembly"
            alert.informativeText = """
            Source-level debugging works on assembled programs (.asm/.s), where the
            assembler emits debug info that maps machine addresses back to source lines.

            BASIC programs are tokenized, not assembled, so there's no instruction-level
            debug info to step through. You can still Build & Run this program normally.

            Tip: Compile BASIC to 6502 assembly first, then use Build & Debug on the .asm file.
            """
            alert.addButton(withTitle: "Build & Run")
            alert.addButton(withTitle: "Cancel")

            if alert.runModal() == .alertFirstButtonReturn {
                buildAndRun(sender)
            }
            return
        }

        let entryPoint: UInt16 = fileType.usesAssemblyHighlighting ? 0x0810 : 0x0801
        let bpLines = wc.editorViewController.breakpointLines

        // Resolve gutter breakpoints against the last build's debug info.
        // Breakpoints remain valid as long as the memory layout hasn't shifted.
        var bpAddresses: [UInt16] = []
        if let dbg = wc.buildManager.lastDebugInfo {
            // Point the parser at the file these breakpoints actually came
            // from. Without this it assumes whichever file contributed the
            // most line mappings, so in a project with a large .include the
            // gutter lines resolved against the wrong file's line numbers.
            dbg.setPrimaryFile(named: sourceURL.lastPathComponent)
            bpAddresses = bpLines.compactMap { dbg.addressForLine($0) }
                                 .filter { $0 != entryPoint }
        } else if !bpLines.isEmpty {
            wc.bottomPanelController.appendBuildOutput(
                "ℹ Gutter breakpoints will apply after the first build generates debug info. "
              + "Breaking at entry point $\(String(format: "%04X", entryPoint)) for now.",
                type: .info)
        }

        let debugOptions = DebugOptions(
            entryPoint: entryPoint,
            breakpoints: bpAddresses,
            debugInfo: wc.buildManager.lastDebugInfo
        )

        openDebugger(sender)

        let target = RunTarget.forActiveDialect(
            c64Preference:   wc.buildConfig.preferredC64Emulator,
            projectOverride: ProjectManager.shared.activeProject?.buildOptions.preferredC64Emulator
        )

        // Some emulators don't support source-level debugging.
        guard target.isDebuggable else {
            wc.bottomPanelController.appendBuildOutput(
                "⚠ \(target.displayName) does not support source-level debugging. Running without breakpoints.",
                type: .warning)
            buildAndRun(sender)
            return
        }

        // Bind the debugger immediately after the coordinator launches the target.
        // This ensures the debugger captures the session before execution begins.
        // The closure is one-shot: it clears itself so a later plain Build & Run
        // doesn't silently rebind the debugger with stale debug info.
        EmulatorCoordinator.shared.onDidLaunch = { [weak self] launched in
            EmulatorCoordinator.shared.onDidLaunch = nil
            guard let self = self,
                  let dbgVC = self.debuggerController?.debuggerVC else { return }
            dbgVC.debugInfo   = self.mainWindowController?.buildManager.lastDebugInfo
            dbgVC.debugTarget = launched as? any DebuggableTarget
        }

        // Clear the debugger binding if the build fails to prevent stale closures
        // from affecting subsequent launches.
        runAfterNextBuild(wc) { result in
            if !result.success {
                EmulatorCoordinator.shared.onDidLaunch = nil
            }
        }

        wc.buildManager.buildAndRun(
            sourceFile: sourceURL,
            target: target,
            debugOptions: debugOptions
        )
    }

    // MARK: - One-Shot Build Completion

    /// Runs `continuation` on the main actor after the next build completes.
    ///
    /// Installs a single wrapper around `buildManager.onBuildComplete` that restores
    /// the prior handler once fired. If a continuation is already pending, it is
    /// replaced rather than chained, so triggering Build & Debug and Build & Save
    /// to Disk in quick succession runs only the most recent intent instead of both.
    @MainActor
    func runAfterNextBuild(_ wc: MainWindowController, _ continuation: @escaping (BuildResult) -> Void) {
        if pendingBuildContinuation == nil {
            let bm = wc.buildManager
            let prior = bm?.onBuildComplete
            bm?.onBuildComplete = { [weak self] result in
                bm?.onBuildComplete = prior
                prior?(result)
                Task { @MainActor in
                    guard let self else { return }
                    let pending = self.pendingBuildContinuation
                    self.pendingBuildContinuation = nil
                    pending?(result)
                }
            }
        }
        pendingBuildContinuation = continuation
    }

    /// Triggers a build without running the output.
    @objc func buildOnly(_ sender: Any?) {
        mainWindowController?.performBuildOnly(sender)
    }

    /// Stops the current build or emulator session.
    @objc func stopBuild(_ sender: Any?) {
        mainWindowController?.performStop(sender)
    }

    // MARK: - Build & Save to Disk

    /// Compiles the current file and exports it to a D64/D81 disk image.
    ///
    /// BASIC files are tokenized synchronously; assembly files are built through
    /// the (asynchronous) build pipeline, and the disk export runs from the build
    /// completion callback rather than immediately, so the PRG on disk is never stale.
    @MainActor
    @objc func buildAndSaveToD64(_ sender: Any?) {
        guard let wc = mainWindowController else { return }

        if wc.editorViewController.document.fileURL == nil {
            wc.bottomPanelController.appendBuildOutput("File must be saved before building.", type: .warning)
            wc.editorViewController.saveDocumentAs { [weak self] success in
                if success { Task { @MainActor in self?.buildAndSaveToD64(sender) } }
            }
            return
        }

        wc.editorViewController.saveDocument()
        guard let fileURL = wc.editorViewController.document.fileURL else { return }

        let buildDir = fileURL.deletingLastPathComponent().appendingPathComponent("build")
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let prgURL   = buildDir.appendingPathComponent("\(baseName).prg")
        let doc      = wc.editorViewController.document

        wc.bottomPanelController.selectTab(.build)

        if doc.fileType.usesBasicHighlighting {
            // Tokenization is synchronous, so the PRG is ready as soon as it succeeds.
            do {
                try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
                try BasicTokenizer.tokenizeToFile(doc.content, outputURL: prgURL,
                    stripWhitespace: wc.buildConfig.basicStripWhitespace)
                wc.bottomPanelController.appendBuildOutput("✓ Tokenized \(fileURL.lastPathComponent)", type: .success)
            } catch {
                wc.bottomPanelController.appendBuildOutput("✗ Tokenization failed: \(error.localizedDescription)", type: .error)
                return
            }
            promptDiskExport(prgURL: prgURL, baseName: baseName, wc: wc)
        } else if doc.fileType.usesAssemblyHighlighting {
            // The build runs asynchronously; export from the completion callback.
            runAfterNextBuild(wc) { [weak self] result in
                guard let self, let wc = self.mainWindowController else { return }
                guard result.success else {
                    wc.bottomPanelController.appendBuildOutput(
                        "Build failed. Disk export cancelled.", type: .error)
                    return
                }
                self.promptDiskExport(prgURL: prgURL, baseName: baseName, wc: wc)
            }
            wc.performBuildOnly(sender)
        } else {
            wc.bottomPanelController.appendBuildOutput("Unknown file type.", type: .error)
            return
        }
    }

    /// Verifies the built PRG exists on disk and prompts for the export destination.
    @MainActor
    private func promptDiskExport(prgURL: URL, baseName: String, wc: MainWindowController) {
        guard FileManager.default.fileExists(atPath: prgURL.path),
              let prgData = try? Data(contentsOf: prgURL) else {
            wc.bottomPanelController.appendBuildOutput("No PRG file found. Build may have failed.", type: .error)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Save to Disk Image"
        alert.informativeText = "\(baseName).prg (\(prgData.count) bytes)\nCreate a new disk image or add to an existing one?"
        alert.addButton(withTitle: "New Disk…")
        alert.addButton(withTitle: "Existing Disk…")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            savePRGToNewDisk(baseName: baseName, prgData: prgData, wc: wc)
        } else if response == .alertSecondButtonReturn {
            savePRGToExistingDisk(baseName: baseName, prgData: prgData, wc: wc)
        }
    }

    /// Creates a new D64 or D81 disk image and writes the PRG to it.
    private func savePRGToNewDisk(baseName: String, prgData: Data, wc: MainWindowController) {
        let fmtAlert = NSAlert()
        fmtAlert.messageText = "Choose Disk Format"
        fmtAlert.informativeText = "D64 — 1541 (170 KB)   ·   D81 — 1581 (800 KB)"
        fmtAlert.addButton(withTitle: "D64")
        fmtAlert.addButton(withTitle: "D81")
        fmtAlert.addButton(withTitle: "Cancel")
        let fmtResponse = fmtAlert.runModal()
        guard fmtResponse != .alertThirdButtonReturn else { return }

        let useD81 = (fmtResponse == .alertSecondButtonReturn)
        let ext    = useD81 ? "d81" : "d64"

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: ext)!]
        panel.nameFieldStringValue = "\(baseName).\(ext)"
        panel.begin { saveResponse in
            guard saveResponse == .OK, let url = panel.url else { return }
            let disk: any DiskImage = useD81
                ? D81Image(diskName: baseName.uppercased(), diskID: "C6")
                : D64Image(diskName: baseName.uppercased(), diskID: "C6")
            let filename = String(baseName.uppercased().prefix(16))
            if disk.writeFile(name: filename, type: 0x82, data: Array(prgData)) {
                do {
                    try disk.save(to: url)
                    wc.bottomPanelController.appendBuildOutput("✓ Saved to \(ext.uppercased()): \(url.lastPathComponent)", type: .success)
                } catch {
                    wc.bottomPanelController.appendBuildOutput("✗ Could not save disk image: \(error.localizedDescription)", type: .error)
                }
            } else {
                wc.bottomPanelController.appendBuildOutput("✗ Failed to write to disk image.", type: .error)
            }
        }
    }

    /// Appends a PRG to an existing D64 or D81 disk image.
    private func savePRGToExistingDisk(baseName: String, prgData: Data, wc: MainWindowController) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .init(filenameExtension: "d64")!,
            .init(filenameExtension: "d81")!,
        ]
        panel.begin { openResponse in
            guard openResponse == .OK, let url = panel.url else { return }
            do {
                let disk = try D64BrowserViewController.loadDiskImage(from: url)
                let filename = String(baseName.uppercased().prefix(16))
                if disk.writeFile(name: filename, type: 0x82, data: Array(prgData)) {
                    try disk.save()
                    let ext = url.pathExtension.uppercased()
                    wc.bottomPanelController.appendBuildOutput(
                        "✓ Added to \(ext): \(url.lastPathComponent) (\(disk.freeBlocks) blocks free)",
                        type: .success)
                } else {
                    wc.bottomPanelController.appendBuildOutput("✗ Failed to write — disk may be full.", type: .error)
                }
            } catch {
                wc.bottomPanelController.appendBuildOutput("✗ Error: \(error.localizedDescription)", type: .error)
            }
        }
    }

    // MARK: - BASIC Compiler

    /// Compiles BASIC source to 6502 assembly, opens the result in a new tab, and reports diagnostics.
    @objc func compileBASIC(_ sender: Any?) {
        guard let wc = mainWindowController else { return }
        let doc = wc.editorViewController.document

        guard doc.fileType.usesBasicHighlighting else {
            wc.bottomPanelController.appendBuildOutput("Compile BASIC requires a .bas file.", type: .warning)
            return
        }

        wc.bottomPanelController.selectTab(.build)
        wc.bottomPanelController.clearBuildOutput()
        wc.bottomPanelController.appendBuildOutput("═══════════════════════════════════════", type: .plain)
        wc.bottomPanelController.appendBuildOutput("Compiling BASIC to 6502 assembly…", type: .plain)
        wc.bottomPanelController.appendBuildOutput("═══════════════════════════════════════", type: .plain)

        let result = BasicCompilerV2.compile(doc.content)

        let diagnostics = result.parseErrors.map {
            BuildDiagnostic(severity: .error, file: doc.displayTitle,
                            line: parseLineNumber(from: $0), column: nil,
                            message: $0, rawLine: $0)
        }
        let buildResult = BuildResult(success: result.success, outputFile: nil,
                                      diagnostics: diagnostics,
                                      assembleTime: 0, linkTime: 0)
        wc.reportBuildResult(buildResult)

        for error in result.parseErrors {
            wc.bottomPanelController.appendBuildOutput("⚠ \(error)", type: .warning)
        }

        if result.success, let asm = result.assembly {
            let table      = result.symbolTable
            let floatVars  = table.types.filter { $0.value.width == .float  }.count
            let wordVars   = table.types.filter { $0.value.width == .word   }.count
            let byteVars   = table.types.filter { $0.value.width == .byte   }.count
            let stringVars = table.types.filter { $0.value.isString         }.count
            wc.bottomPanelController.appendBuildOutput(
                "Type analysis: \(byteVars) byte, \(wordVars) word, \(floatVars) float, \(stringVars) string variable(s)",
                type: .info)
            if floatVars == 0 {
                wc.bottomPanelController.appendBuildOutput(
                    "✓ No floating-point variables — zero ROM float calls generated.",
                    type: .success)
            }

            let asmDoc = C64Document(fileType: .assembly, content: asm)
            let baseName = doc.fileURL?.deletingPathExtension().lastPathComponent ?? "compiled"
            asmDoc.customTitle = "\(baseName)_compiled.s"
            wc.addNewTab(with: asmDoc)

            wc.bottomPanelController.appendBuildOutput(
                "✓ Compiled to assembly (\(asm.components(separatedBy: "\n").count) lines)",
                type: .success)
            wc.bottomPanelController.appendBuildOutput("The generated assembly is in a new tab.", type: .info)
            wc.bottomPanelController.appendBuildOutput("Use Build & Run (⌘R) on the .asm tab to assemble and run.", type: .info)
        } else {
            wc.bottomPanelController.appendBuildOutput("✗ Compilation failed.", type: .error)
        }
    }

    /// Extracts a 1-based line number from a BASIC parse error string (e.g., "Line 80: ...").
    func parseLineNumber(from error: String) -> Int? {
        let pattern = /[Ll]ine\s+(\d+)/
        if let match = error.firstMatch(of: pattern) {
            return Int(match.1)
        }
        return nil
    }
}

