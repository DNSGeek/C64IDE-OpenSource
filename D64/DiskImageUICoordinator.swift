import AppKit
import SwiftUI

// ═══════════════════════════════════════════════════════════
// MARK: - DiskImageUICoordinator
// ═══════════════════════════════════════════════════════════

/// Coordinates UI recovery when a required disk image file is missing.
///
/// `DiskImageService` throws `.imageNotFound(URL)` when a disk image path
/// is absent. This coordinator intercepts that error and presents a modal
/// sheet offering three actions:
///
/// - **Create New**: Formats a blank D64/D81 image at the expected path.
/// - **Locate Existing**: Opens a file panel to point to a moved/renamed image.
/// - **Cancel**: Aborts the operation.
///
/// On successful creation or relocation, the coordinator updates the project
/// model so the new path is persisted. Non-`.imageNotFound` errors are
/// silently ignored, allowing callers to pass any `DiskImageError` safely.
final class DiskImageUICoordinator {

    // MARK: - Singleton

    static let shared = DiskImageUICoordinator()
    private init() {}

    // MARK: - Public API

    /// Attempts recovery from a `DiskImageError.imageNotFound`.
    ///
    /// - Parameters:
    ///   - error:        The error thrown by `DiskImageService`.
    ///   - disk:         The project disk configuration associated with the missing file.
    ///   - parentWindow: The NSWindow that will own the recovery sheet.
    ///   - retry:        Closure to execute after successful recovery.
    func recover(
        from error: Error,
        disk: ProjectDisk,
        parentWindow: NSWindow,
        retry: @escaping () -> Void
    ) {
        guard case DiskImageError.imageNotFound(let url) = error else { return }
        presentRecoverySheet(missingURL: url, disk: disk,
                             parentWindow: parentWindow, retry: retry)
    }

    /// Convenience overload for callers that already have the missing URL.
    func recover(
        missingURL: URL,
        disk: ProjectDisk,
        parentWindow: NSWindow,
        retry: @escaping () -> Void
    ) {
        presentRecoverySheet(missingURL: missingURL, disk: disk,
                             parentWindow: parentWindow, retry: retry)
    }

    // MARK: - Recovery Sheet

    private func presentRecoverySheet(
        missingURL: URL,
        disk: ProjectDisk,
        parentWindow: NSWindow,
        retry: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "Disk Image Not Found"
        alert.informativeText = """
            The disk image "\(missingURL.lastPathComponent)" for "\(disk.label)" \
            could not be found at:

            \(missingURL.path)

            You can create a new blank image, locate the existing file, or cancel.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Create New")
        alert.addButton(withTitle: "Locate...")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: parentWindow) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.presentNewImageDialog(suggestedURL: missingURL, disk: disk,
                                           parentWindow: parentWindow, retry: retry)
            case .alertSecondButtonReturn:
                self.presentLocatePanel(missingURL: missingURL, disk: disk,
                                        parentWindow: parentWindow, retry: retry)
            default:
                break
            }
        }
    }

    // MARK: - Create New Flow

    private func presentNewImageDialog(
        suggestedURL: URL,
        disk: ProjectDisk,
        parentWindow: NSWindow,
        retry: @escaping () -> Void
    ) {
        var sheetWindow: NSWindow?

        let rootView = NewDiskImageView(suggestedURL: suggestedURL, disk: disk) { [weak self] result in
            if let sheet = sheetWindow {
                parentWindow.endSheet(sheet)
                // Break the retain cycle: sheet -> hostingController -> rootView
                // -> this closure -> captured sheetWindow box -> sheet. Without
                // this, every New Disk Image sheet leaks its NSWindow.
                sheetWindow = nil
            }
            guard let self else { return }
            if case .created(let url) = result {
                MainActor.assumeIsolated {
                    self.updateProjectDiskFilename(disk: disk, newURL: url)
                }
                retry()
            }
        }

        let hostingController = NSHostingController(rootView: rootView)
        let sheet = NSWindow(contentViewController: hostingController)
        sheet.setContentSize(NSSize(width: 420, height: 300))
        sheetWindow = sheet
        parentWindow.beginSheet(sheet) { _ in }
    }

    // MARK: - Locate Flow

    private func presentLocatePanel(
        missingURL: URL,
        disk: ProjectDisk,
        parentWindow: NSWindow,
        retry: @escaping () -> Void
    ) {
        let panel = NSOpenPanel()
        panel.title = "Locate Disk Image"
        panel.message = "Locate the disk image for \"\(disk.label)\""
        panel.prompt = "Use This Image"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .init(filenameExtension: "d64")!,
            .init(filenameExtension: "d81")!
        ]
        panel.directoryURL = missingURL.deletingLastPathComponent()

        panel.beginSheetModal(for: parentWindow) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                self.updateProjectDiskFilename(disk: disk, newURL: url)
            }
            retry()
        }
    }

    // MARK: - Project Model Update

    @MainActor private func updateProjectDiskFilename(disk: ProjectDisk, newURL: URL) {
        guard let root = ProjectManager.shared.projectRoot else { return }
        let relative = newURL.path.hasPrefix(root.path + "/")
            ? String(newURL.path.dropFirst(root.path.count + 1))
            : newURL.path

        ProjectManager.shared.updateProject { project in
            guard var config = project.diskConfig,
                  let idx = config.disks.firstIndex(where: { $0.id == disk.id })
            else { return }
            config.disks[idx].filename = relative
            project.diskConfig = config
        }
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - NewDiskImageView
// ═══════════════════════════════════════════════════════════

/// SwiftUI view that presents a dialog for creating a blank C64 disk image.
///
/// Supports two initialization modes:
/// - **Recovery Mode**: Pre-fills fields from an existing `ProjectDisk`.
/// - **Standalone Mode**: Initializes with default values for `File → New Disk Image...`.
struct NewDiskImageView: View {

    enum CreateResult {
        case created(URL)
        case cancelled
    }

    // MARK: - State

    @State private var diskName:   String
    @State private var diskID:     String
    @State private var format:     DiskFormat
    @State private var outputURL:  URL
    @State private var errorMsg:   String?
    @State private var isCreating: Bool = false

    private let onComplete: (CreateResult) -> Void

    // MARK: - Initialization

    /// Initializes the view using metadata from an existing `ProjectDisk`.
    init(suggestedURL: URL, disk: ProjectDisk, onComplete: @escaping (CreateResult) -> Void) {
        _diskName  = State(initialValue: disk.cbmDiskName)
        _diskID    = State(initialValue: disk.cbmDiskID)
        _format    = State(initialValue: disk.format)
        _outputURL = State(initialValue: suggestedURL)
        self.onComplete = onComplete
    }

    /// Initializes the view with default values for standalone creation.
    init(suggestedURL: URL, onComplete: @escaping (CreateResult) -> Void) {
        _diskName  = State(initialValue: "NEW DISK")
        _diskID    = State(initialValue: "C6")
        _format    = State(initialValue: .d81)
        _outputURL = State(initialValue: suggestedURL)
        self.onComplete = onComplete
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            Text("New Disk Image")
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(.cyan)

            VStack(alignment: .leading, spacing: 4) {
                label("Format")
                Picker("", selection: $format) {
                    Text("D81  (1581, 800KB)").tag(DiskFormat.d81)
                    Text("D64  (1541, 170KB)").tag(DiskFormat.d64)
                }
                .pickerStyle(.segmented)
                .onChange(of: format) { f in
                    // Keep the output path's extension in lockstep with the
                    // chosen format. Without this, a recovery-suggested URL
                    // like "game.d81" plus a D64 selection would create the
                    // wrong image type.
                    outputURL = outputURL
                        .deletingPathExtension()
                        .appendingPathExtension(f == .d81 ? "d81" : "d64")
                }
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    label("Disk Name")
                    TextField("MY DISK", text: $diskName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onChange(of: diskName) { v in
                            diskName = String(v.uppercased().prefix(16))
                        }
                    hint("Max 16 chars")
                }
                VStack(alignment: .leading, spacing: 4) {
                    label("ID")
                    TextField("C6", text: $diskID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: 60)
                        .onChange(of: diskID) { v in
                            diskID = String(v.uppercased().prefix(2))
                        }
                    hint("2 chars")
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                label("Save As")
                HStack {
                    Text(outputURL.lastPathComponent)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Change...") { chooseSaveLocation() }
                        .font(.system(size: 11, design: .monospaced))
                }
                hint(outputURL.deletingLastPathComponent().path)
            }

            if let err = errorMsg {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                        .font(.system(size: 11))
                    Text(err)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.yellow)
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button("Cancel") { onComplete(.cancelled) }
                    .font(.system(.body, design: .monospaced))
                    .keyboardShortcut(.cancelAction)
                Button(isCreating ? "Creating..." : "Create") { createImage() }
                    .font(.system(.body, design: .monospaced))
                    .keyboardShortcut(.defaultAction)
                    .disabled(diskName.isEmpty || diskID.isEmpty || isCreating)
            }
        }
        .padding(24)
        .frame(width: 420, height: 300)
    }

    // MARK: - Helpers

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(.gray)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(.gray.opacity(0.6))
            .lineLimit(1)
            .truncationMode(.head)
    }

    private func chooseSaveLocation() {
        let panel = NSSavePanel()
        panel.title = "Save Disk Image"
        panel.nameFieldStringValue = outputURL.lastPathComponent
        panel.directoryURL = outputURL.deletingLastPathComponent()
        panel.allowedContentTypes = [
            .init(filenameExtension: format == .d81 ? "d81" : "d64")!
        ]
        if panel.runModal() == .OK, let url = panel.url {
            outputURL = url
        }
    }

    private func createImage() {
        isCreating = true
        errorMsg = nil

        // Belt and braces: normalize the extension to the chosen format and
        // pass the format explicitly so the service never has to guess.
        let url = outputURL
            .deletingPathExtension()
            .appendingPathExtension(format == .d81 ? "d81" : "d64")

        do {
            try DiskImageService.shared.createImage(
                at: url, format: format, diskName: diskName, diskID: diskID
            )
            onComplete(.created(url))
        } catch {
            isCreating = false
            errorMsg = error.localizedDescription
        }
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - BuildManager + Recovery Integration
// ═══════════════════════════════════════════════════════════

extension BuildManager {

    /// Runs the disk bundle phase with automatic missing-image recovery.
    ///
    /// Drop-in replacement for `bundleDisks`. If any disk image is missing,
    /// the recovery sheet appears. Upon successful creation or relocation,
    /// the bundle phase automatically retries.
    ///
    /// The failed result is matched to its `ProjectDisk` by resolving each
    /// disk's image path against the missing URL. Positional pairing (the old
    /// `zip(results, diskConfig.disks)`) silently mispaired whenever
    /// `bundleDisks` skipped or reordered a disk - and a mispaired recovery
    /// would rewrite the wrong disk's filename in the project model.
    @MainActor func bundleDisksWithRecovery(outputPRG: URL, buildDir: URL, parentWindow: NSWindow) {
        guard let proj = project, let diskConfig = proj.diskConfig else { return }

        let results = bundleDisks(outputPRG: outputPRG, buildDir: buildDir)

        for result in results {
            guard !result.success,
                  let error = result.error,
                  case DiskImageError.imageNotFound(let url) = error else { continue }

            guard let disk = Self.disk(matching: url, in: diskConfig) else {
                // No configured disk resolves to the missing path. Recovery
                // would guess, and guessing rewrites project state - skip.
                continue
            }

            DiskImageUICoordinator.shared.recover(
                missingURL: url,
                disk: disk,
                parentWindow: parentWindow
            ) { [weak self] in
                self?.bundleDisksWithRecovery(outputPRG: outputPRG, buildDir: buildDir,
                                              parentWindow: parentWindow)
            }
            return  // Process one missing image at a time
        }
    }

    /// Finds the `ProjectDisk` whose image path resolves to `url`.
    /// Falls back to a filename match if full-path resolution finds nothing
    /// (e.g. project root unavailable, or symlinked build directories).
    @MainActor private static func disk(matching url: URL, in config: ProjectDiskConfig) -> ProjectDisk? {
        let target = url.standardizedFileURL.path
        if let match = config.disks.first(where: {
            imageURL(for: $0)?.standardizedFileURL.path == target
        }) {
            return match
        }
        return config.disks.first {
            URL(fileURLWithPath: $0.filename).lastPathComponent == url.lastPathComponent
        }
    }

    /// Resolves a disk's stored filename. Relative filenames are anchored at
    /// the project root; absolute filenames (set by the Locate flow for
    /// images outside the project) pass through unchanged.
    @MainActor private static func imageURL(for disk: ProjectDisk) -> URL? {
        if disk.filename.hasPrefix("/") {
            return URL(fileURLWithPath: disk.filename)
        }
        guard let root = ProjectManager.shared.projectRoot else { return nil }
        return root.appendingPathComponent(disk.filename)
    }
}

