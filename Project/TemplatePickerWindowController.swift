import Cocoa

// MARK: - TemplatePickerWindowController

/// Modal sheet that lets the user pick a bundled project template.
///
/// Usage:
///     let picker = TemplatePickerWindowController()
///     picker.onTemplateChosen = { template in ... }
///     picker.showAsSheet(attachedTo: parentWindow)
@MainActor
final class TemplatePickerWindowController: NSWindowController {

    // MARK: - Callback

    /// Called on the main thread when the user clicks "Choose".
    /// Not called if the user cancels.
    var onTemplateChosen: ((ProjectTemplate) -> Void)?

    // MARK: - Data

    private let templates: [ProjectTemplate] = ProjectTemplateLoader.loadAll()
    private var selectedTemplate: ProjectTemplate?

    // MARK: - Views

    private let categorySidebar  = NSTableView()
    private let templateTable    = NSTableView()
    private let nameField        = NSTextField()
    private let summaryLabel     = NSTextField()
    private let chooseButton     = NSButton()
    private let cancelButton     = NSButton()
    private let detailBox = NSBox()

    /// Category names derived from templates, preserving display order
    private lazy var categories: [ProjectTemplate.TemplateCategory] = {
        var seen: [ProjectTemplate.TemplateCategory] = []
        for t in templates where !seen.contains(t.category) {
            seen.append(t.category)
        }
        return seen
    }()

    private var selectedCategory: ProjectTemplate.TemplateCategory? {
        didSet {
            templateTable.reloadData()
            selectFirstTemplate()
        }
    }

    private var filteredTemplates: [ProjectTemplate] {
        guard let cat = selectedCategory else { return templates }
        return templates.filter { $0.category == cat }
    }

    // MARK: - Init

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 380),
            styleMask:   [.titled, .closable],
            backing:     .buffered,
            defer:       false
        )
        window.title = "New Project from Template"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("use init()") }

    // MARK: - Present

    /// Presents the window as a sheet attached to the specified parent window.
    func showAsSheet(attachedTo parent: NSWindow) {
        guard let sheet = self.window else { return }
        parent.beginSheet(sheet) { _ in }
    }

    // MARK: - UI Construction

    private func buildUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true

        // ── Sidebar scroll (categories) ──────────────────────
        let sidebarScroll = scrollView(for: categorySidebar, width: 140)
        categorySidebar.delegate   = self
        categorySidebar.dataSource = self
        categorySidebar.tag        = 1 // Identifies category table
        categorySidebar.headerView = nil
        categorySidebar.rowHeight  = 28
        addColumn(to: categorySidebar, id: "category", title: "")

        // ── Template list scroll ─────────────────────────────
        let templateScroll = scrollView(for: templateTable, width: 180)
        templateTable.delegate   = self
        templateTable.dataSource = self
        templateTable.tag        = 2 // Identifies template table
        templateTable.headerView = nil
        templateTable.rowHeight  = 28
        addColumn(to: templateTable, id: "template", title: "")

        // ── Detail area ──────────────────────────────────────
        detailBox.boxType    = .custom
        detailBox.fillColor  = NSColor.windowBackgroundColor
        detailBox.borderColor = NSColor.separatorColor
        detailBox.borderWidth = 1
        detailBox.cornerRadius = 6
        detailBox.translatesAutoresizingMaskIntoConstraints = false

        let templateNameLabel = makeLabel("Template Name:", bold: true, size: 11)
        nameField.isEditable  = false
        nameField.isBordered  = false
        nameField.drawsBackground = false
        nameField.font        = NSFont.systemFont(ofSize: 13, weight: .semibold)
        nameField.textColor   = NSColor.labelColor
        nameField.translatesAutoresizingMaskIntoConstraints = false

        let descLabel = makeLabel("Description:", bold: true, size: 11)
        summaryLabel.isEditable  = false
        summaryLabel.isBordered  = false
        summaryLabel.drawsBackground = false
        summaryLabel.font        = NSFont.systemFont(ofSize: 12)
        summaryLabel.textColor   = NSColor.secondaryLabelColor
        summaryLabel.lineBreakMode = .byWordWrapping
        summaryLabel.maximumNumberOfLines = 4
        summaryLabel.preferredMaxLayoutWidth = 220 // Set once for consistent layout
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        detailBox.addSubview(templateNameLabel)
        detailBox.addSubview(nameField)
        detailBox.addSubview(descLabel)
        detailBox.addSubview(summaryLabel)

        NSLayoutConstraint.activate([
            templateNameLabel.topAnchor.constraint(equalTo: detailBox.topAnchor, constant: 16),
            templateNameLabel.leadingAnchor.constraint(equalTo: detailBox.leadingAnchor, constant: 16),
            templateNameLabel.trailingAnchor.constraint(equalTo: detailBox.trailingAnchor, constant: -16),

            nameField.topAnchor.constraint(equalTo: templateNameLabel.bottomAnchor, constant: 4),
            nameField.leadingAnchor.constraint(equalTo: detailBox.leadingAnchor, constant: 16),
            nameField.trailingAnchor.constraint(equalTo: detailBox.trailingAnchor, constant: -16),

            descLabel.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 16),
            descLabel.leadingAnchor.constraint(equalTo: detailBox.leadingAnchor, constant: 16),
            descLabel.trailingAnchor.constraint(equalTo: detailBox.trailingAnchor, constant: -16),

            summaryLabel.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 4),
            summaryLabel.leadingAnchor.constraint(equalTo: detailBox.leadingAnchor, constant: 16),
            summaryLabel.trailingAnchor.constraint(equalTo: detailBox.trailingAnchor, constant: -16),
        ])

        // ── Buttons ──────────────────────────────────────────
        cancelButton.title  = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1B}" // Escape key
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        chooseButton.title  = "Choose"
        chooseButton.bezelStyle = .rounded
        chooseButton.keyEquivalent = "\r"
        chooseButton.target = self
        chooseButton.action = #selector(chooseTapped)
        chooseButton.isEnabled = false
        chooseButton.translatesAutoresizingMaskIntoConstraints = false

        // ── Layout ───────────────────────────────────────────
        contentView.addSubview(sidebarScroll)
        contentView.addSubview(templateScroll)
        contentView.addSubview(detailBox)
        contentView.addSubview(cancelButton)
        contentView.addSubview(chooseButton)

        NSLayoutConstraint.activate([
            // Sidebar
            sidebarScroll.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            sidebarScroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            sidebarScroll.widthAnchor.constraint(equalToConstant: 140),
            sidebarScroll.bottomAnchor.constraint(equalTo: cancelButton.topAnchor, constant: -12),

            // Template list
            templateScroll.topAnchor.constraint(equalTo: sidebarScroll.topAnchor),
            templateScroll.leadingAnchor.constraint(equalTo: sidebarScroll.trailingAnchor, constant: 8),
            templateScroll.widthAnchor.constraint(equalToConstant: 180),
            templateScroll.bottomAnchor.constraint(equalTo: sidebarScroll.bottomAnchor),

            // Detail box
            detailBox.topAnchor.constraint(equalTo: sidebarScroll.topAnchor),
            detailBox.leadingAnchor.constraint(equalTo: templateScroll.trailingAnchor, constant: 8),
            detailBox.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            detailBox.bottomAnchor.constraint(equalTo: sidebarScroll.bottomAnchor),

            // Buttons
            cancelButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            cancelButton.trailingAnchor.constraint(equalTo: chooseButton.leadingAnchor, constant: -8),

            chooseButton.bottomAnchor.constraint(equalTo: cancelButton.bottomAnchor),
            chooseButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            chooseButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])

        // Pre-select the first category
        if !categories.isEmpty {
            selectedCategory = categories[0]
            categorySidebar.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        window?.sheetParent?.endSheet(window!)
    }

    @objc private func chooseTapped() {
        guard let template = selectedTemplate else { return }
        window?.sheetParent?.endSheet(window!)
        onTemplateChosen?(template)
    }

    // MARK: - Helpers

    private func selectFirstTemplate() {
        if !filteredTemplates.isEmpty {
            templateTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            selectedTemplate = filteredTemplates[0]
            updateDetail()
        } else {
            selectedTemplate = nil
            updateDetail()
        }
        chooseButton.isEnabled = selectedTemplate != nil
    }

    private func updateDetail() {
        nameField.stringValue    = selectedTemplate?.name    ?? ""
        summaryLabel.stringValue = selectedTemplate?.summary ?? ""
        // Invalidate intrinsic size to ensure layout engine recalculates wrapping
        summaryLabel.invalidateIntrinsicContentSize()
    }

    private func scrollView(for tableView: NSTableView, width: CGFloat) -> NSScrollView {
        let sv = NSScrollView()
        sv.documentView           = tableView
        sv.hasVerticalScroller    = true
        sv.autohidesScrollers     = true
        sv.borderType             = .bezelBorder
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }

    private func addColumn(to tableView: NSTableView, id: String, title: String) {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        col.title = title
        tableView.addTableColumn(col)
    }

    private func makeLabel(_ text: String, bold: Bool, size: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = bold
            ? NSFont.boldSystemFont(ofSize: size)
            : NSFont.systemFont(ofSize: size)
        label.textColor = NSColor.secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}

// MARK: - NSTableViewDataSource

extension TemplatePickerWindowController: NSTableViewDataSource {

    /// Returns the row count for the requested table.
    /// Uses `tag` to differentiate between the category sidebar and template list.
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView.tag == 1 ? categories.count : filteredTemplates.count
    }
}

// MARK: - NSTableViewDelegate

extension TemplatePickerWindowController: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text: String
        if tableView.tag == 1 {
            text = categories[row].displayName
        } else {
            text = filteredTemplates[row].name
        }

        // Use distinct reuse identifiers to prevent cross-table cell conflicts
        let cellID = tableView.tag == 1
            ? NSUserInterfaceItemIdentifier("categoryCell")
            : NSUserInterfaceItemIdentifier("templateCell")
        
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = cellID
            let tf = NSTextField()
            tf.isBordered       = false
            tf.drawsBackground  = false
            tf.isEditable       = false
            tf.font             = NSFont.systemFont(ofSize: 13)
            tf.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(tf)
            cell.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = text
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView else { return }

        if tableView.tag == 1 {
            // Category sidebar selection changed
            let row = tableView.selectedRow
            selectedCategory = row >= 0 ? categories[row] : nil
        } else {
            // Template list selection changed
            let row = tableView.selectedRow
            selectedTemplate = row >= 0 ? filteredTemplates[row] : nil
            updateDetail()
            chooseButton.isEnabled = selectedTemplate != nil
        }
    }
}

