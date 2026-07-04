import AppKit

// MARK: - Build Pipeline Support

/// Shared helpers used by the various "build & run on target X" pipelines
/// (VICE x64sc, VICE x128, VICE pet, xemu xmega65, MEGA65 hardware via etherload,
/// U64 hardware). Extracted here so the build logic lives in exactly one place
/// rather than drifting across half a dozen copy-pasted siblings.
///
/// Caseless enum = namespace. There's no intent to ever instantiate this.
enum BuildPipelineSupport {

    /// Build the current document into a `.prg` on disk and return its URL.
    ///
    /// Handles both paths the IDE currently supports:
    ///  - BASIC source → `BasicTokenizer.tokenizeToFile` (synchronous, fast)
    ///  - Assembly source → `BuildManager.build` (asynchronous; we bridge its
    ///    callback-based API to Swift concurrency via a continuation so callers
    ///    can treat it as synchronous. This prevents the assembler from
    ///    wedging the main thread if it hangs.)
    ///
    /// All progress messages are routed through the window controller's
    /// bottom panel, matching how the pipelines already log. If/when we want
    /// headless builds (e.g. unit tests or a future CLI), this is the place
    /// to swap in a logging closure.
    ///
    /// - Parameters:
    ///   - wc:  The active window controller. Used for reading the current
    ///          document, triggering a save, and logging build output.
    ///   - doc: The document to build. Typically `wc.editorViewController.document`
    ///          — passed in explicitly rather than re-read so callers have a
    ///          single source of truth about which document they're building.
    /// - Returns: URL of the built `.prg` on success, `nil` on failure. On
    ///   failure, a human-readable error has already been logged.
    @MainActor
    static func buildPRG(windowController wc: MainWindowController,
                         document doc: C64Document) async -> URL? {

        guard let fileURL = doc.fileURL else {
            log("✗ Save the file before building.", .warning, wc: wc)
            return nil
        }

        wc.editorViewController.saveDocument()

        let buildDir = fileURL.deletingLastPathComponent().appendingPathComponent("build")
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let prgURL   = buildDir.appendingPathComponent("\(baseName).prg")

        if doc.fileType.usesBasicHighlighting {
            do {
                try FileManager.default.createDirectory(at: buildDir,
                                                        withIntermediateDirectories: true)
                try BasicTokenizer.tokenizeToFile(
                    doc.content, outputURL: prgURL,
                    stripWhitespace: wc.buildConfig.basicStripWhitespace)
                log("✓ Tokenized \(fileURL.lastPathComponent)", .success, wc: wc)
                _ = wc.buildManager.bundleDisks(outputPRG: prgURL, buildDir: buildDir)
            } catch {
                log("✗ Tokenization failed: \(error.localizedDescription)", .error, wc: wc)
                return nil
            }

        } else if doc.fileType.usesAssemblyHighlighting {
            // Bridge BuildManager's callback-based async into Swift concurrency
            // via a continuation. No more main-thread semaphore wait, so a
            // wedged assembler can't beach-ball the IDE.
            let buildSuccess: Bool = await withCheckedContinuation { continuation in
                // Capture the current callback and restore it after our bridge completes.
                // This prevents race conditions if the manager fires the callback
                // before we finish setting ours up.
                let previousCallback = wc.buildManager.onBuildComplete
                wc.buildManager.onBuildComplete = { result in
                    wc.buildManager.onBuildComplete = previousCallback
                    continuation.resume(returning: result.success)
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    wc.buildManager.build(sourceFile: fileURL, type: .assemblyPrg)
                }
            }
            guard buildSuccess else { return nil }

        } else {
            log("✗ Unknown file type.", .error, wc: wc)
            return nil
        }

        guard FileManager.default.fileExists(atPath: prgURL.path) else {
            log("✗ PRG file not found after build.", .error, wc: wc)
            return nil
        }

        return prgURL
    }

    // MARK: - Private

    /// Thin wrapper so we don't have to pepper the function above with
    /// `wc.bottomPanelController.appendBuildOutput(...)` boilerplate.
    @MainActor
    private static func log(_ message: String, _ type: MessageType,
                            wc: MainWindowController) {
        wc.bottomPanelController.appendBuildOutput(message, type: type)
    }
}

