//  BuildPreferencesView.swift
//  C64 IDE
//
//  SwiftUI preferences panel for configuring toolchain paths, emulator settings,
//  build options, ROM locations, and validation states.

import Cocoa
import SwiftUI
import Combine

// MARK: - Build Preferences View

/// SwiftUI panel for configuring build toolchain, emulator, and project settings.
struct BuildPreferencesView: View {
    @Environment(\.colorScheme) private var colorScheme

    @State private var showExampleOnLaunch: Bool = {
        UserDefaults.standard.object(forKey: "showExampleOnLaunch") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "showExampleOnLaunch")
    }()

    private var accentColor: Color { colorScheme == .dark ? .cyan : Color(red: 0.05, green: 0.40, blue: 0.80) }
    private var dimText:     Color { colorScheme == .dark ? .gray : Color(white: 0.45) }
    private var panelBg:     Color { colorScheme == .dark ? Color(red: 0.10, green: 0.10, blue: 0.13) : Color(NSColor.windowBackgroundColor) }

    @ObservedObject var viewModel: BuildPreferencesViewModel
    var onDismiss: () -> Void
    var onSave: (() -> Void)? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {

                    // ── Project context banner ────────────────────
                    if let projectName = ProjectManager.shared.activeProject?.name {
                        HStack(spacing: 6) {
                            Image(systemName: "folder.fill")
                                .foregroundColor(accentColor)
                                .font(.caption)
                            Text("Project: \(projectName)")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(accentColor)
                            Spacer()
                            Text("Build options saved to project · Tool paths saved globally")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.gray.opacity(0.7))
                        }
                        .padding(8)
                        .background(accentColor.opacity(0.08))
                        .cornerRadius(6)
                    }

                    // ── Tool Paths ───────────────────────────────
                    sectionHeader("Tool Paths")
                    pathField(label: "ca65 (assembler)", path: $viewModel.ca65Path)
                    pathField(label: "ld65 (linker)", path: $viewModel.ld65Path)
                    pathField(label: "VICE (x64sc)", path: $viewModel.vicePath)
                    pathField(label: "VICE (x128)", path: $viewModel.x128Path)
                    pathField(label: "VICE (xpet)", path: $viewModel.xpetPath)
                    pathField(label: "VICE (xvic)", path: $viewModel.xvicPath)
                    pathField(label: "xemu (xmega65)", path: $viewModel.xemuPath)
                    Text("The active dialect picks the Run target: x128 for C128 (e.g. BASIC V7), xpet for PET (BASIC 4), xvic for VIC-20 (Super Expander), xemu for MEGA65 (BASIC 65). Everything else uses your C64 emulator below.")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.7))

                    Divider().padding(.vertical, 4)

                    // ── C64 Emulator ─────────────────────────────
                    sectionHeader("C64 Emulator")

                    HStack {
                        Text("Run C64 targets with:")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(dimText)
                            .frame(width: 160, alignment: .trailing)
                        Picker("", selection: $viewModel.preferredC64Emulator) {
                            Text("VirtualC64 (embedded)").tag(RunTarget.vc64)
                            Text("VICE x64sc (external)").tag(RunTarget.viceX64sc)
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }

                    Text("VirtualC64 is embedded — no binary path needed, but it requires "
                       + "the C64 ROMs configured below. VICE x64sc uses the binary path above and "
                       + "can use the same ROMs or its own bundled set.")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)

                    // ── Build Options ────────────────────────────
                    sectionHeader("Build Options")
                    Toggle("Generate debug info (.dbg)", isOn: $viewModel.generateDebugInfo)
                        .font(.system(.body, design: .monospaced))
                    Toggle("Generate listing file (.lst)", isOn: $viewModel.generateListing)
                        .font(.system(.body, design: .monospaced))
                    Toggle("Auto-run in VICE after build", isOn: $viewModel.viceAutoRun)
                        .font(.system(.body, design: .monospaced))
                    Toggle("Strip whitespace when tokenizing BASIC", isOn: $viewModel.basicStripWhitespace)
                        .font(.system(.body, design: .monospaced))
                    Text("Removes unnecessary spaces to save bytes on the C64")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.7))

                    Divider().padding(.vertical, 2)
                    Toggle("Show example file on launch", isOn: $showExampleOnLaunch)
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: showExampleOnLaunch) { newValue in
                            UserDefaults.standard.set(newValue, forKey: "showExampleOnLaunch")
                        }
                    Text("Opens an example BASIC file when the IDE launches with no project")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.7))

                    Divider().padding(.vertical, 4)

                    // ── VICE Configuration ───────────────────────
                    sectionHeader("VICE Emulator")

                    HStack {
                        Text("C64 Model:")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(dimText)
                            .frame(width: 120, alignment: .trailing)
                        Picker("", selection: $viewModel.c64Model) {
                            Text("Default").tag("")
                            Text("C64 (PAL)").tag("c64")
                            Text("C64C (PAL)").tag("c64c")
                            Text("C64 Old (PAL)").tag("c64old")
                            Text("C64 (NTSC)").tag("ntsc")
                            Text("C64 (NTSC New)").tag("newntsc")
                            Text("C64 (NTSC Old)").tag("oldntsc")
                            Text("C64 (Drean)").tag("drean")
                            Text("C64 Japanese").tag("jap")
                            Text("C64 GS").tag("c64gs")
                        }
                        .labelsHidden()
                        .frame(width: 200)
                    }

                    HStack {
                        Text("SID Model:")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(dimText)
                            .frame(width: 120, alignment: .trailing)
                        Picker("", selection: $viewModel.sidModel) {
                            Text("6581 (original)").tag(0)
                            Text("8580 (C64C)").tag(1)
                            Text("8580 + digiboost").tag(2)
                        }
                        .labelsHidden()
                        .frame(width: 200)
                    }

                    HStack {
                        Text("Video:")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(dimText)
                            .frame(width: 120, alignment: .trailing)
                        Picker("", selection: $viewModel.videoStandard) {
                            Text("PAL (50Hz)").tag("pal")
                            Text("NTSC (60Hz)").tag("ntsc")
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 200)
                    }

                    Divider().padding(.vertical, 4)

                    // ── C64 ROMs ─────────────────────────────────
                    sectionHeader("C64 ROMs")
                    Text("Required for VirtualC64; optional for VICE (VICE has its own defaults). "
                       + "Point at your own copies of the original Commodore ROM dumps. "
                       + "Leave blank to use VirtualC64's built-in MEGA65 OpenROMs (less accurate).")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)

                    pathField(label: "KERNAL ROM", path: $viewModel.kernalROM)
                    pathField(label: "BASIC ROM", path: $viewModel.basicROM)
                    pathField(label: "Character ROM", path: $viewModel.chargenROM)

                    Divider().padding(.vertical, 4)

                    // ── VIC-20 ───────────────────────────────────
                    sectionHeader("VIC-20")
                    Text("The Super Expander is a cartridge: xvic needs its ROM image to "
                       + "understand SE keywords. Leave blank and SE programs will load but "
                       + "fail with ?SYNTAX ERROR. Expansion RAM is configured automatically "
                       + "from the program's load address.")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)

                    pathField(label: "Super Expander cartridge ROM", path: $viewModel.xvicSuperExpanderROM)

                    Divider().padding(.vertical, 4)

                    // ── Validation ───────────────────────────────
                    if !viewModel.validationMessages.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(viewModel.validationMessages, id: \.self) { msg in
                                HStack(alignment: .top, spacing: 4) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.yellow)
                                        .font(.caption)
                                    Text(msg)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.yellow)
                                }
                            }
                        }
                    }

                    // ── Buttons ──────────────────────────────────
                    HStack {
                        Button("Auto-Detect Paths") {
                            viewModel.autoDetect()
                        }
                        .font(.system(.body, design: .monospaced))

                        Spacer()

                        Button("Cancel") {
                            onDismiss()
                        }
                        .font(.system(.body, design: .monospaced))
                        .keyboardShortcut(.cancelAction)

                        Button("Save") {
                            viewModel.save()
                            onSave?()
                            onDismiss()
                        }
                        .font(.system(.body, design: .monospaced))
                        .keyboardShortcut(.defaultAction)
                    }
                    .padding(.top, 8)
                }
                .padding(20)
            }
            .frame(width: 580, height: 700)

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(10)
        }
        .background(panelBg)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 15, weight: .bold, design: .monospaced))
            .foregroundColor(accentColor)
    }

    private func pathField(label: String, path: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(dimText)
            HStack(spacing: 4) {
                TextField("", text: path)
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                Button("Browse…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    panel.title = "Select \(label)"
                    if panel.runModal() == .OK, let url = panel.url {
                        path.wrappedValue = url.path
                    }
                }
                .font(.system(size: 10, design: .monospaced))

                if !path.wrappedValue.isEmpty {
                    Button("Clear") {
                        path.wrappedValue = ""
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.red)
                }
            }
        }
    }
}

// MARK: - View Model

/// ViewModel for `BuildPreferencesView`. Manages configuration state, validation, and persistence.
class BuildPreferencesViewModel: ObservableObject {
    @Published var ca65Path: String
    @Published var ld65Path: String
    @Published var vicePath: String
    @Published var x128Path: String
    @Published var xpetPath: String
    @Published var xvicPath: String
    @Published var xvicSuperExpanderROM: String
    @Published var xemuPath: String
    @Published var generateDebugInfo: Bool
    @Published var generateListing: Bool
    @Published var viceAutoRun: Bool
    @Published var basicStripWhitespace: Bool
    @Published var kernalROM: String
    @Published var basicROM: String
    @Published var chargenROM: String
    @Published var c64Model: String
    @Published var sidModel: Int
    @Published var videoStandard: String
    @Published var validationMessages: [String] = []
    @Published var preferredC64Emulator: RunTarget = .vc64

    private let config: BuildConfiguration
    private var cancellables = Set<AnyCancellable>()

    init(config: BuildConfiguration) {
        self.config = config
        self.ca65Path = config.ca65Path
        self.ld65Path = config.ld65Path
        self.vicePath = config.vicePath
        self.x128Path = config.x128Path
        self.xpetPath = config.xpetPath
        self.xvicPath = config.xvicPath
        self.xvicSuperExpanderROM = config.xvicSuperExpanderROM
        self.xemuPath = config.xemuPath
        self.generateDebugInfo = config.generateDebugInfo
        self.generateListing = config.generateListing
        self.viceAutoRun = config.viceAutoRun
        self.basicStripWhitespace = config.basicStripWhitespace
        self.kernalROM = config.viceKernalROM
        self.basicROM = config.viceBasicROM
        self.chargenROM = config.viceChargenROM
        self.c64Model = config.viceC64Model
        self.sidModel = config.viceSIDModel
        self.videoStandard = config.viceVideoStandard
        self.preferredC64Emulator = config.preferredC64Emulator
        validate()

        // Live revalidation: re-check whenever any path or ROM field changes,
        // whether typed or set via Browse (both go through the @Published
        // bindings). Debounced so we don't stat() on every keystroke while
        // the user is mid-path. Each publisher replays its current value on
        // subscription; the debounce collapses those into one redundant
        // validate() shortly after init, which is harmless.
        let pathPublishers: [AnyPublisher<Void, Never>] = [
            $ca65Path, $ld65Path, $vicePath, $x128Path, $xpetPath, $xvicPath, $xemuPath,
            $kernalROM, $basicROM, $chargenROM, $xvicSuperExpanderROM,
        ].map { $0.map { _ in () }.eraseToAnyPublisher() }

        Publishers.MergeMany(pathPublishers)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.validate() }
            .store(in: &cancellables)
    }

    /// Auto-detects toolchain paths from common locations and Homebrew.
    ///
    /// Detects into a scratch configuration seeded with the current field
    /// values, so paths that aren't found keep what the user entered.
    /// Previously this mutated the live shared `BuildConfiguration` directly,
    /// which meant Cancel still left the in-memory config changed (unsaved
    /// but active) until relaunch. Now nothing touches the shared config
    /// until `save()`.
    func autoDetect() {
        let scratch = BuildConfiguration()
        scratch.ca65Path = ca65Path
        scratch.ld65Path = ld65Path
        scratch.vicePath = vicePath
        scratch.x128Path = x128Path
        scratch.xpetPath = xpetPath
        scratch.xvicPath = xvicPath
        scratch.xemuPath = xemuPath
        scratch.autoDetect()
        ca65Path = scratch.ca65Path
        ld65Path = scratch.ld65Path
        vicePath = scratch.vicePath
        x128Path = scratch.x128Path
        xpetPath = scratch.xpetPath
        xvicPath = scratch.xvicPath
        xemuPath = scratch.xemuPath
        validate()
    }

    /// Persists current view model state to the shared `BuildConfiguration`.
    func save() {
        config.ca65Path = ca65Path
        config.ld65Path = ld65Path
        config.vicePath = vicePath
        config.x128Path = x128Path
        config.xpetPath = xpetPath
        config.xvicPath = xvicPath
        config.xvicSuperExpanderROM = xvicSuperExpanderROM
        config.xemuPath = xemuPath
        config.generateDebugInfo = generateDebugInfo
        config.generateListing = generateListing
        config.viceAutoRun = viceAutoRun
        config.basicStripWhitespace = basicStripWhitespace
        config.viceKernalROM = kernalROM
        config.viceBasicROM = basicROM
        config.viceChargenROM = chargenROM
        config.viceC64Model = c64Model
        config.viceSIDModel = sidModel
        config.viceVideoStandard = videoStandard
        // Capture before overwriting: the Monitor reference tab shows the command
        // set of whichever emulator is selected, so it has to be told when the
        // selection moves between VirtualC64 and VICE.
        let emulatorDidChange = config.preferredC64Emulator != preferredC64Emulator
        config.preferredC64Emulator = preferredC64Emulator
        config.save()

        if emulatorDidChange {
            NotificationCenter.default.post(name: .preferredEmulatorDidChange, object: nil)
        }
    }

    /// Validates current paths and ROM locations, updating `validationMessages`.
    func validate() {
        validationMessages = []
        if !FileManager.default.isExecutableFile(atPath: ca65Path) {
            validationMessages.append("ca65 not found at \(ca65Path)")
        }
        if !FileManager.default.isExecutableFile(atPath: ld65Path) {
            validationMessages.append("ld65 not found at \(ld65Path)")
        }
        if !FileManager.default.isExecutableFile(atPath: vicePath) {
            validationMessages.append("VICE not found at \(vicePath)")
        }
        if !x128Path.isEmpty && !FileManager.default.isExecutableFile(atPath: x128Path) {
            validationMessages.append("VICE x128 not found at \(x128Path)")
        }
        if !xpetPath.isEmpty && !FileManager.default.isExecutableFile(atPath: xpetPath) {
            validationMessages.append("VICE xpet not found at \(xpetPath)")
        }
        if !xvicPath.isEmpty && !FileManager.default.isExecutableFile(atPath: xvicPath) {
            validationMessages.append("VICE xvic not found at \(xvicPath)")
        }
        if !xvicSuperExpanderROM.isEmpty && !FileManager.default.fileExists(atPath: xvicSuperExpanderROM) {
            validationMessages.append("Super Expander ROM not found at \(xvicSuperExpanderROM)")
        }
        if !xemuPath.isEmpty && !FileManager.default.isExecutableFile(atPath: xemuPath) {
            validationMessages.append("xemu not found at \(xemuPath)")
        }
        if !kernalROM.isEmpty && !FileManager.default.fileExists(atPath: kernalROM) {
            validationMessages.append("KERNAL ROM not found at \(kernalROM)")
        }
        if !basicROM.isEmpty && !FileManager.default.fileExists(atPath: basicROM) {
            validationMessages.append("BASIC ROM not found at \(basicROM)")
        }
        if !chargenROM.isEmpty && !FileManager.default.fileExists(atPath: chargenROM) {
            validationMessages.append("Character ROM not found at \(chargenROM)")
        }
    }
}

