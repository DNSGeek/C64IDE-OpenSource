import SwiftUI
import AppKit

// MARK: - Adaptive Colors for Settings Views

/// Provides adaptive accent and background colors based on the current color scheme.
private struct SettingsColors {
    let scheme: ColorScheme
    var accent: Color { scheme == .dark ? .cyan : Color(red: 0.05, green: 0.40, blue: 0.80) }
    var dim:    Color { scheme == .dark ? .gray : Color(white: 0.45) }
    var panelBg: Color { scheme == .dark ? Color(NSColor(red: 0.10, green: 0.10, blue: 0.13, alpha: 1)) : Color(NSColor.windowBackgroundColor) }
}

// MARK: - ProjectSettingsView (shell + tab bar)

/// Root view for the Project Settings sheet.
/// Hosts a tab bar (Disks | Build) and delegates each pane to its own child view.
/// The shell owns the Save / Cancel footer to ensure consistent dismiss behavior.
struct ProjectSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    private var c: SettingsColors { SettingsColors(scheme: colorScheme) }

    // MARK: State

    @StateObject private var viewModel: ProjectSettingsViewModel
    @State private var selectedTab: ProjectSettingsTab = .disks

    var onDismiss: () -> Void

    init(project: C64Project, onDismiss: @escaping () -> Void) {
        _viewModel  = StateObject(wrappedValue: ProjectSettingsViewModel(project: project))
        self.onDismiss = onDismiss
    }
    
    // MARK: Body
    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {

                // ── Tab bar ──────────────────────────────────
                tabBar

                Divider()

                // ── Active pane ──────────────────────────────
                Group {
                    switch selectedTab {
                    case .disks: DisksPane(viewModel: viewModel)
                    case .build: BuildDiskPane(viewModel: viewModel)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                
                // ── C64 Emulator Override ────────────────────
                Toggle("Override global C64 emulator for this project",
                       isOn: $viewModel.overrideC64Emulator)

                if viewModel.overrideC64Emulator {
                    Picker("", selection: $viewModel.projectC64Emulator) {
                        Text("VirtualC64 (embedded)").tag(RunTarget.vc64)
                        Text("VICE x64sc (external)").tag(RunTarget.viceX64sc)
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }

                // ── Footer ───────────────────────────────────
                footer
            }

            // Close button — top-left, matches Build Preferences style
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(10)
        }
        .frame(width: 620, height: 680)
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(ProjectSettingsTab.allCases) { tab in
                tabButton(tab)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .background(c.panelBg)
    }

    private func tabButton(_ tab: ProjectSettingsTab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            VStack(spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: tab.icon)
                        .font(.system(size: 12))
                    Text(tab.title)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                }
                .foregroundColor(selectedTab == tab ? .cyan : .gray)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

                // Active indicator
                Rectangle()
                    .fill(selectedTab == tab ? c.accent : Color.clear)
                    .frame(height: 2)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            // Validation errors
            if !viewModel.validationErrors.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                    .font(.system(size: 12))
                Text(viewModel.validationErrors[0])
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.yellow)
                    .lineLimit(1)
            }

            Spacer()

            Button("Cancel") {
                onDismiss()
            }
            .font(.system(.body, design: .monospaced))
            .keyboardShortcut(.cancelAction)

            Button("Save") {
                viewModel.save()
                onDismiss()
            }
            .font(.system(.body, design: .monospaced))
            .keyboardShortcut(.defaultAction)
            .disabled(!viewModel.isValid)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(c.panelBg)
    }
}

// MARK: - Tab enum

enum ProjectSettingsTab: String, CaseIterable, Identifiable {
    case disks = "Disks"
    case build = "Build"

    var id: String { rawValue }
    var title: String { rawValue }

    var icon: String {
        switch self {
        case .disks: return "externaldrive.fill"
        case .build: return "hammer.fill"
        }
    }
}

// MARK: - ProjectSettingsViewModel

@MainActor
final class ProjectSettingsViewModel: ObservableObject {

    // MARK: Published state

    /// NOTE: `@Published` on an array of `ObservableObject` does not automatically
    /// trigger SwiftUI updates for in-place mutations. Use `objectWillChange.send()`
    /// on `disks` if mutating items directly, or replace the array when reordering.
    @Published var disks: [DiskEntry]
    @Published var primaryDiskID: UUID?
    @Published var outputCBMName: String
    @Published var targetDiskID: UUID?
    @Published var overrideC64Emulator: Bool = false
    @Published var projectC64Emulator: RunTarget = .vc64

    // MARK: Private

    private let originalProject: C64Project

    // MARK: Init

    init(project: C64Project) {
        self.originalProject = project

        if let config = project.diskConfig {
            self.disks = config.disks.map { DiskEntry(from: $0) }
            self.primaryDiskID = config.primaryDiskID
        } else {
            self.disks = []
            self.primaryDiskID = nil
        }

        if let output = project.buildOptions.diskOutput {
            self.outputCBMName = output.outputCBMName
            self.targetDiskID  = output.targetDiskID
        } else {
            self.outputCBMName = project.name.uppercased().prefix(16).description
            self.targetDiskID  = nil
        }
        if let override = project.buildOptions.preferredC64Emulator {
            self.overrideC64Emulator = true
            self.projectC64Emulator  = override
        }
    }

    // MARK: Validation

    var validationErrors: [String] {
        var errors: [String] = []

        // Duplicate drive numbers
        let drives = disks.map { $0.driveNumber }
        let dupes  = Dictionary(grouping: drives, by: { $0 }).filter { $1.count > 1 }.keys
        for d in dupes.sorted() {
            errors.append("Drive \(d) is assigned to more than one disk")
        }

        // Drive numbers out of valid C64 range
        for disk in disks where disk.driveNumber < 8 || disk.driveNumber > 11 {
            errors.append("\"\(disk.label)\": drive number must be 8–11")
        }

        // Empty filenames
        for disk in disks where disk.filename.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("\"\(disk.label)\": filename cannot be empty")
        }

        // Build output name too long
        if outputCBMName.count > 16 {
            errors.append("Output CBM name exceeds 16 characters")
        }

        return errors
    }

    var isValid: Bool { validationErrors.isEmpty }

    // MARK: Mutations

    func addDisk() {
        let nextDrive = (disks.map { $0.driveNumber }.max() ?? 7) + 1
        let entry = DiskEntry(
            label:       "New Disk",
            filename:    "build/disk\(disks.count + 1).d81",
            format:      .d81,
            cbmDiskName: "DISK",
            cbmDiskID:   "C6",
            driveNumber: min(nextDrive, 11),
            bootProgramName: nil,
            allowWrites: true
        )
        disks.append(entry)
        if primaryDiskID == nil { primaryDiskID = entry.id }
    }

    func removeDisk(at offsets: IndexSet) {
        let removedIDs = offsets.map { disks[$0].id }
        disks.remove(atOffsets: offsets)
        if let pid = primaryDiskID, removedIDs.contains(pid) {
            primaryDiskID = disks.first?.id
        }
        if let tid = targetDiskID, removedIDs.contains(tid) {
            targetDiskID = disks.first?.id
        }
    }

    func moveDisk(from source: IndexSet, to destination: Int) {
        disks.move(fromOffsets: source, toOffset: destination)
        objectWillChange.send() // Ensure SwiftUI refreshes on in-place array mutation
    }

    // MARK: Save

    func save() {
        ProjectManager.shared.updateProject { project in
            if disks.isEmpty {
                project.diskConfig = nil
            } else {
                let projectDisks = disks.map { $0.toProjectDisk() }
                var config = ProjectDiskConfig(disks: projectDisks)
                config.primaryDiskID = primaryDiskID ?? projectDisks[0].id
                project.diskConfig = config
            }

            if !outputCBMName.isEmpty, let tid = targetDiskID {
                project.buildOptions.diskOutput = ProjectBuildDiskOutput(
                    targetDiskID:  tid,
                    outputCBMName: outputCBMName
                )
            } else {
                project.buildOptions.diskOutput = nil
            }

            // C64 emulator override
            project.buildOptions.preferredC64Emulator = overrideC64Emulator ? projectC64Emulator : nil
        }
        // Flush to disk immediately — user clicked Save, they expect it to stick
        try? ProjectManager.shared.saveProject()

        // The override sits ahead of the global preference in the chain the
        // Monitor reference tab reads, so changing it can flip the command set.
        let newOverride = overrideC64Emulator ? projectC64Emulator : nil
        if newOverride != originalProject.buildOptions.preferredC64Emulator {
            NotificationCenter.default.post(name: .preferredEmulatorDidChange, object: nil)
        }
    }
}

// MARK: - DiskEntry (view model for a single disk row)

/// Mutable view-model representation of a `ProjectDisk`.
/// UUID identity is preserved across edits so primary/target references remain valid.
final class DiskEntry: ObservableObject, Identifiable {

    let id: UUID

    @Published var label:           String
    @Published var filename:        String
    @Published var format:          DiskFormat
    @Published var cbmDiskName:     String
    @Published var cbmDiskID:       String
    @Published var driveNumber:     Int
    @Published var bootProgramName: String
    @Published var allowWrites:     Bool

    init(from disk: ProjectDisk) {
        self.id              = disk.id
        self.label           = disk.label
        self.filename        = disk.filename
        self.format          = disk.format
        self.cbmDiskName     = disk.cbmDiskName
        self.cbmDiskID       = disk.cbmDiskID
        self.driveNumber     = disk.driveNumber
        self.bootProgramName = disk.bootProgramName ?? ""
        self.allowWrites     = disk.allowWrites
    }

    init(label: String, filename: String, format: DiskFormat,
         cbmDiskName: String, cbmDiskID: String, driveNumber: Int,
         bootProgramName: String?, allowWrites: Bool) {
        self.id              = UUID()
        self.label           = label
        self.filename        = filename
        self.format          = format
        self.cbmDiskName     = cbmDiskName
        self.cbmDiskID       = cbmDiskID
        self.driveNumber     = driveNumber
        self.bootProgramName = bootProgramName ?? ""
        self.allowWrites     = allowWrites
    }

    func toProjectDisk() -> ProjectDisk {
        var disk = ProjectDisk(
            label:           label,
            filename:        filename,
            format:          format,
            cbmDiskName:     cbmDiskName.uppercased(),
            cbmDiskID:       cbmDiskID.uppercased(),
            driveNumber:     driveNumber,
            assetFolders:    [],
            explicitFiles:   [],
            excludes:        [],
            bootProgramName: bootProgramName.isEmpty ? nil : bootProgramName.uppercased(),
            allowWrites:     allowWrites
        )
        disk.id = self.id   // Preserve identity across edits
        return disk
    }
}

// MARK: - DisksPane

struct DisksPane: View {
    @Environment(\.colorScheme) private var colorScheme
    private var c: SettingsColors { SettingsColors(scheme: colorScheme) }

    @ObservedObject var viewModel: ProjectSettingsViewModel
    @State private var selectedDiskID: UUID? = nil

    var body: some View {
        HSplitView {
            // ── Left: disk list ──────────────────────────────
            diskList
                .frame(minWidth: 180, maxWidth: 220)

            // ── Right: disk detail ───────────────────────────
            if let id = selectedDiskID,
               let entry = viewModel.disks.first(where: { $0.id == id }) {
                DiskDetailView(entry: entry, viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyDetail
            }
        }
        .onAppear {
            if selectedDiskID == nil {
                selectedDiskID = viewModel.disks.first?.id
            }
        }
    }

    // MARK: Disk list

    private var diskList: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("DISKS")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(c.dim)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(c.panelBg)

            Divider()

            // List
            List {
                ForEach(viewModel.disks) { entry in
                    DiskRowView(
                        entry:      entry,
                        isPrimary:  entry.id == viewModel.primaryDiskID,
                        isSelected: entry.id == selectedDiskID
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedDiskID = entry.id
                    }
                    .listRowBackground(
                        entry.id == selectedDiskID
                            ? c.accent.opacity(0.15)
                            : Color.clear
                    )
                }
                .onMove(perform: viewModel.moveDisk)
                .onDelete(perform: viewModel.removeDisk)
            }
            .listStyle(.sidebar)

            Divider()

            // Add / Remove toolbar
            HStack(spacing: 2) {
                Button {
                    viewModel.addDisk()
                    selectedDiskID = viewModel.disks.last?.id
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 24)  // Larger hit area
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(6)
                .help("Add disk")

                Button {
                    if let id = selectedDiskID,
                       let idx = viewModel.disks.firstIndex(where: { $0.id == id }),
                       let entry = viewModel.disks.first(where: { $0.id == id }) {
                        let alert = NSAlert()
                        alert.messageText = "Remove \"\(entry.label)\"?"
                        alert.informativeText = "This removes the disk from the project configuration. The image file on disk is not deleted."
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "Remove")
                        alert.addButton(withTitle: "Cancel")
                        guard alert.runModal() == .alertFirstButtonReturn else { return }
                        viewModel.removeDisk(at: IndexSet([idx]))
                        selectedDiskID = viewModel.disks.first?.id
                    }
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(selectedDiskID == nil || viewModel.disks.isEmpty)
                .help("Remove selected disk")

                Spacer()
            }
            .background(c.panelBg)
        }
    }

    // MARK: Empty detail

    private var emptyDetail: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 36))
                .foregroundColor(.gray.opacity(0.4))
            Text("No disks configured")
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.gray.opacity(0.5))
            Text("Click + to add a disk image to this project")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.gray.opacity(0.4))
            Button("Add Disk") {
                viewModel.addDisk()
                selectedDiskID = viewModel.disks.last?.id
            }
            .font(.system(.body, design: .monospaced))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - DiskRowView

struct DiskRowView: View {
    @Environment(\.colorScheme) private var colorScheme
    private var c: SettingsColors { SettingsColors(scheme: colorScheme) }

    @ObservedObject var entry: DiskEntry
    let isPrimary:  Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.format == .d81 ? "externaldrive.fill" : "externaldrive")
                .font(.system(size: 12))
                .foregroundColor(isSelected ? .cyan : .gray)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.label)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(isSelected ? .cyan : .primary)
                    if isPrimary {
                        Text("BOOT")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(c.accent)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(c.accent.opacity(0.15))
                            .cornerRadius(3)
                    }
                }
                Text("Drive \(entry.driveNumber) · \(entry.format == .d81 ? "D81" : "D64")")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(c.dim)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - DiskDetailView

struct DiskDetailView: View {
    @Environment(\.colorScheme) private var colorScheme
    private var c: SettingsColors { SettingsColors(scheme: colorScheme) }

    @ObservedObject var entry: DiskEntry
    @ObservedObject var viewModel: ProjectSettingsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // ── Identity ─────────────────────────────────
                sectionHeader("Identity")

                labeledField("Label", hint: "Human-readable name shown in the IDE") {
                    TextField("Boot Disk", text: $entry.label)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }

                HStack(spacing: 12) {
                    Toggle("Primary (boot) disk", isOn: Binding(
                        get: { viewModel.primaryDiskID == entry.id },
                        set: { if $0 { viewModel.primaryDiskID = entry.id } }
                    ))
                    .font(.system(.body, design: .monospaced))
                    Spacer()
                }

                Divider()

                // ── File ─────────────────────────────────────
                sectionHeader("Image File")

                labeledField("Filename", hint: "Relative to project root, e.g. build/game.d81") {
                    TextField("build/game.d81", text: $entry.filename)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }

                labeledField("Format", hint: nil) {
                    Picker("", selection: $entry.format) {
                        Text("D81  (1581, 800KB)").tag(DiskFormat.d81)
                        Text("D64  (1541, 170KB)").tag(DiskFormat.d64)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                }

                Divider()

                // ── CBM Metadata ──────────────────────────────
                sectionHeader("CBM Metadata")

                HStack(alignment: .top, spacing: 16) {
                    labeledField("Disk Name", hint: "Max 16 chars, ASCII") {
                        TextField("MY DISK", text: $entry.cbmDiskName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .onChange(of: entry.cbmDiskName) { newValue in
                                entry.cbmDiskName = String(newValue.prefix(16)).uppercased()
                            }
                    }

                    labeledField("Disk ID", hint: "2 chars") {
                        TextField("C6", text: $entry.cbmDiskID)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: 60)
                            .onChange(of: entry.cbmDiskID) { newValue in
                                entry.cbmDiskID = String(newValue.prefix(2)).uppercased()
                            }
                    }
                }

                labeledField("Drive Number", hint: "8–11 (8 = default)") {
                    Stepper(value: $entry.driveNumber, in: 8...11) {
                        Text("\(entry.driveNumber)")
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 24)
                    }
                }

                Divider()

                // ── Boot ──────────────────────────────────────
                sectionHeader("Boot")

                labeledField("Boot Program", hint: "CBM name to LOAD and RUN first. Leave blank for LOAD\"*\",8,1") {
                    TextField("MYGAME", text: $entry.bootProgramName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onChange(of: entry.bootProgramName) { newValue in
                            entry.bootProgramName = String(newValue.prefix(16)).uppercased()
                        }
                }

                Toggle("Allow emulator writes to this image", isOn: $entry.allowWrites)
                    .font(.system(.body, design: .monospaced))

            }
            .padding(20)
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 15, weight: .bold, design: .monospaced))
            .foregroundColor(c.accent)
    }

    @ViewBuilder
    private func labeledField<Content: View>(
        _ label: String,
        hint: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(c.dim)
            content()
            if let hint = hint {
                Text(hint)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray.opacity(0.6))
            }
        }
    }
}

// MARK: - BuildDiskPane

struct BuildDiskPane: View {
    @Environment(\.colorScheme) private var colorScheme
    private var c: SettingsColors { SettingsColors(scheme: colorScheme) }

    @ObservedObject var viewModel: ProjectSettingsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // ── Context banner ────────────────────────────
                HStack(spacing: 6) {
                    Image(systemName: "hammer.fill")
                        .foregroundColor(c.accent)
                        .font(.caption)
                    Text("Disk output settings — where the compiled PRG lands on disk")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(c.accent)
                }
                .padding(8)
                .background(c.accent.opacity(0.08))
                .cornerRadius(6)

                // ── No disks guard ────────────────────────────
                if viewModel.disks.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                        Text("Add at least one disk in the Disks tab first.")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.yellow)
                    }
                    .padding(10)
                    .background(Color.yellow.opacity(0.08))
                    .cornerRadius(6)

                } else {

                    // ── Output name ───────────────────────────
                    sectionHeader("Compiled PRG")

                    VStack(alignment: .leading, spacing: 4) {
                        Text("CBM Filename on Disk")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(c.dim)
                        TextField("MYGAME", text: $viewModel.outputCBMName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: 240)
                            .onChange(of: viewModel.outputCBMName) { newValue in
                                viewModel.outputCBMName = String(newValue.prefix(16)).uppercased()
                            }
                        Text("Max 16 chars, ASCII. This is the name LOAD will look for on disk.")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.gray.opacity(0.6))
                    }

                    Divider()

                    // ── Target disk ───────────────────────────
                    sectionHeader("Target Disk")

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Write compiled PRG to")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(c.dim)

                        Picker("", selection: $viewModel.targetDiskID) {
                            Text("None (PRG inject mode)").tag(UUID?.none)
                            ForEach(viewModel.disks) { disk in
                                Text("\(disk.label) — Drive \(disk.driveNumber)")
                                    .tag(Optional(disk.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: 320)

                        Text("When set, the compiled PRG is bundled onto this disk during every build.")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.gray.opacity(0.6))
                    }
                }

                Spacer()
            }
            .padding(20)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 15, weight: .bold, design: .monospaced))
            .foregroundColor(c.accent)
    }
}

