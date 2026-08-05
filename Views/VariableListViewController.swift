//  VariableListViewController.swift
//  C64 IDE
//

import AppKit

class VariableListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    var onJumpToLine: ((Int) -> Void)?

    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var summaryLabel: NSTextField!

    private var allVars: [BasicVariableInfo] = []
    private var filteredVars: [BasicVariableInfo] = []
    private var currentSearchQuery = ""

    private var bgColor: NSColor { AppTheme.current.panelBackground }

    private enum ColumnID: String, CaseIterable {
        case name = "name"
        case type = "type"
        case line = "line"
        case initVal = "init"
        case usage = "usage"

        var title: String {
            switch self {
            case .name:    return "Name"
            case .type:    return "Type"
            case .line:    return "Line"
            case .initVal: return "Init"
            case .usage:   return "R/W"
            }
        }

        var width: CGFloat {
            switch self {
            case .name:    return 90
            case .type:    return 80
            case .line:    return 45
            case .initVal: return 60
            case .usage:   return 45
            }
        }
    }

    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 500))
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        for col in ColumnID.allCases {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.rawValue))
            column.title = col.title
            column.width = col.width
            tableViewLazyInit().addTableColumn(column)
        }

        tableView.headerView = NSTableHeaderView()
        tableView.rowHeight = 22
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = bgColor
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.doubleAction = #selector(rowDoubleClicked(_:))
        tableView.target = self

        scrollView = NSScrollView(frame: .zero)
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = bgColor
        view.addSubview(scrollView)

        summaryLabel = NSTextField(labelWithString: "")
        summaryLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        summaryLabel.textColor = AppTheme.current.refDescription
        summaryLabel.lineBreakMode = .byTruncatingTail
        view.addSubview(summaryLabel)
    }

    private func tableViewLazyInit() -> NSTableView {
        if tableView == nil { tableView = NSTableView() }
        return tableView
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let bounds = view.bounds
        let summaryHeight: CGFloat = 20
        scrollView.frame = NSRect(x: 0, y: summaryHeight,
                                  width: bounds.width,
                                  height: bounds.height - summaryHeight)
        summaryLabel.frame = NSRect(x: 8, y: 2,
                                    width: bounds.width - 16,
                                    height: summaryHeight - 4)
    }

    // MARK: - Public

    /// Push fresh scan results. Preserves the current selection by name
    /// so the panel doesn't jump around under the user while typing.
    func update(_ vars: [BasicVariableInfo]) {
        let selectedName: String?
        if let tableView, tableView.selectedRow >= 0,
           tableView.selectedRow < filteredVars.count {
            selectedName = filteredVars[tableView.selectedRow].name
        } else {
            selectedName = nil
        }

        allVars = vars
        applyFilter()

        if let selectedName,
           let idx = filteredVars.firstIndex(where: { $0.name == selectedName }) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
        updateSummary()
    }

    func filter(by query: String) {
        currentSearchQuery = query
        applyFilter()
        updateSummary()
    }

    func applyTheme() {
        tableView?.backgroundColor = bgColor
        scrollView?.backgroundColor = bgColor
        summaryLabel?.textColor = AppTheme.current.refDescription
        tableView?.reloadData()
    }

    // MARK: - Filtering / summary

    private func applyFilter() {
        if currentSearchQuery.isEmpty {
            filteredVars = allVars
        } else {
            let q = currentSearchQuery.uppercased()
            filteredVars = allVars.filter {
                $0.name.contains(q) || $0.typeDescription.uppercased().contains(q)
            }
        }
        tableView?.reloadData()
    }

    private func updateSummary() {
        let collisions = allVars.filter { !$0.collidesWith.isEmpty }.count
        let unused = allVars.filter { $0.readCount == 0 && $0.kind != .function }.count
        var parts = ["\(allVars.count) variables"]
        if collisions > 0 { parts.append("\(collisions) name collisions") }
        if unused > 0 { parts.append("\(unused) never read") }
        summaryLabel?.stringValue = parts.joined(separator: "  |  ")
    }

    // MARK: - Data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { filteredVars.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredVars.count,
              let colID = tableColumn.flatMap({ ColumnID(rawValue: $0.identifier.rawValue) })
        else { return nil }

        let v = filteredVars[row]
        let cellID = NSUserInterfaceItemIdentifier("VarCell_\(colID.rawValue)")
        var cell = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView

        if cell == nil {
            let c = NSTableCellView()
            c.identifier = cellID
            let tf = NSTextField(labelWithString: "")
            tf.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            tf.lineBreakMode = .byTruncatingTail
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(tf)
            c.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            cell = c
        }

        let hasCollision = !v.collidesWith.isEmpty

        switch colID {
        case .name:
            var display = v.name
            if v.kind == .array { display += "(\(v.dims ?? "?"))" }
            cell?.textField?.stringValue = display
            cell?.textField?.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
            cell?.textField?.textColor = hasCollision
                ? NSColor.systemRed
                : AppTheme.current.refAccentBasic
            cell?.toolTip = hasCollision
                ? "BASIC V2 sees only the first 2 characters: collides with \(v.collidesWith.joined(separator: ", "))"
                : nil
        case .type:
            cell?.textField?.stringValue = v.typeDescription
            cell?.textField?.textColor = AppTheme.current.refCategory
        case .line:
            cell?.textField?.stringValue = String(v.firstLine)
            cell?.textField?.textColor = AppTheme.current.panelText
        case .initVal:
            cell?.textField?.stringValue = v.initialValue ?? "-"
            cell?.textField?.textColor = AppTheme.current.panelText
        case .usage:
            cell?.textField?.stringValue = "\(v.readCount)/\(v.writeCount)"
            // Written but never read: probable dead weight, worth a nudge.
            cell?.textField?.textColor = (v.readCount == 0 && v.kind != .function)
                ? NSColor.systemOrange
                : AppTheme.current.refDescription
        }

        return cell
    }

    @objc private func rowDoubleClicked(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard row >= 0, row < filteredVars.count else { return }
        onJumpToLine?(filteredVars[row].firstLine)
    }
}
