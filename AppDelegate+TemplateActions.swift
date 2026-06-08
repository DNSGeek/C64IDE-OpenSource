//  AppDelegate+TemplateActions.swift
//  C64 IDE
//
//  Provides the "New Project from Template…" workflow, including the template picker
//  sheet, project name/location prompts, and automatic project installation.

import Cocoa

extension AppDelegate {

    /// Static reference to retain the template picker across the sheet's dismissal lifecycle.
    /// Sheets are dismissed asynchronously; storing the picker prevents premature deallocation.
    private static var _templatePicker: TemplatePickerWindowController?

    @MainActor @objc func newProjectFromTemplate(_ sender: Any?) {
        guard let parentWindow = mainWindowController?.window else { return }

        let picker = TemplatePickerWindowController()
        AppDelegate._templatePicker = picker

        picker.onTemplateChosen = { [weak self] template in
            AppDelegate._templatePicker = nil
            self?.promptNameAndInstall(template: template, parentWindow: parentWindow)
        }

        picker.showAsSheet(attachedTo: parentWindow)
    }

    /// Guides the user through naming the project, choosing a save location,
    /// and installing the selected template.
    @MainActor private func promptNameAndInstall(template: ProjectTemplate, parentWindow: NSWindow) {

        // ── Step 1: Ask for a project name ──────────────────
        let nameAlert = NSAlert()
        nameAlert.messageText    = "New Project from Template"
        nameAlert.informativeText = "Enter a name for your \"\(template.name)\" project."
        nameAlert.addButton(withTitle: "Next…")
        nameAlert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        nameField.placeholderString = "MyGame"
        nameAlert.accessoryView = nameField
        nameAlert.window.initialFirstResponder = nameField

        guard nameAlert.runModal() == .alertFirstButtonReturn else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        // ── Step 2: Ask where to save ────────────────────────
        let panel = NSOpenPanel()
        panel.title               = "Choose Project Location"
        panel.message             = "Choose a folder for \"\(name)\""
        panel.prompt              = "Create Here"
        panel.canChooseFiles      = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let location = panel.url else { return }

        // ── Step 3: Copy template, patch project file ────────
        do {
            let projURL = try ProjectTemplateInstaller.install(
                template:    template,
                projectName: name,
                into:        location
            )

            // ── Step 4: Open the new project ─────────────────
            guard ProjectManager.shared.openProject(at: projURL) else { return }

            // ── Step 5: Show Project Settings ────────────────
            // Short delay ensures the project-open notification settles
            // before pushing another sheet onto the window stack.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.showProjectSettings(nil)
            }

        } catch {
            let alert = NSAlert()
            alert.messageText     = "Could not create project"
            alert.informativeText = error.localizedDescription
            alert.alertStyle      = .critical
            alert.runModal()
        }
    }
}
