import AppKit

/// The window's Exclusions page: the words fix-while-typing leaves as typed, learned from undos or added here.
final class ExclusionsPage: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    struct Model {
        let list: () -> [Exclusions.Entry]
        /// What the entry would have been changed to, nil when no layout on now types its language.
        let otherReading: (Exclusions.Entry) -> String?
        let remove: ([Exclusions.Entry]) -> Void
        /// Returns why the word can't be added, or nil when it was.
        let add: (String) -> String?
    }

    static let tableHeight: CGFloat = 190
    /// Shown by `--settings-snapshot … --page exclusions`, never the person's own list.
    static let sample: [Exclusions.Entry] = [
        Exclusions.Entry(word: "csv", language: "en", origin: .learned, undos: 3, since: Date()),
        Exclusions.Entry(word: "ltd", language: "en", origin: .learned, undos: 3, since: Date()),
        Exclusions.Entry(word: "jira", language: "en", origin: .added, undos: 0, since: Date()),
    ]

    let view = NSStackView()
    private let model: Model
    private let width: CGFloat
    private var sampleOnly = false
    private var shown: [Exclusions.Entry] = []
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No exclusions yet.")
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)

    private enum Column: String, CaseIterable {
        case typed = "You type", other = "Not changed to", how = "How", since = "Since"
        var width: CGFloat {
            switch self {
            case .typed: return 80
            case .other: return 95
            case .how: return 95
            case .since: return 90
            }
        }
    }

    init(model: Model, width: CGFloat) {
        self.model = model
        self.width = width
        super.init()
        build()
    }

    func showSample() {
        sampleOnly = true
        refresh()
    }

    /// Reloads the table only when the list changed, so a selection survives the window's timer.
    func refresh() {
        let list = sampleOnly ? ExclusionsPage.sample : model.list()
        guard list != shown || table.numberOfRows != list.count else { return }
        shown = list
        table.reloadData()
        emptyLabel.isHidden = !list.isEmpty
        removeButton.isEnabled = !table.selectedRowIndexes.isEmpty
    }

    private func build() {
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 10

        let about = NSTextField(wrappingLabelWithString:
            "Fix while typing leaves these words as you typed them. A word whose fix you undo 3 times (right ⌥, ⌘Z, "
            + "or erasing it and typing it again) is added here. Right ⌥ still converts them.")
        about.textColor = .secondaryLabelColor
        about.preferredMaxLayoutWidth = width

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.rawValue
            tableColumn.width = column.width
            table.addTableColumn(tableColumn)
        }
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.style = .fullWidth
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: width).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: ExclusionsPage.tableHeight).isActive = true

        emptyLabel.textColor = .secondaryLabelColor
        let add = NSButton(title: "Add…", target: self, action: #selector(addWord))
        add.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        removeButton.bezelStyle = .rounded
        removeButton.isEnabled = false
        let buttons = NSStackView(views: [add, removeButton, emptyLabel])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let privacy = NSTextField(wrappingLabelWithString:
            "These words stay on this Mac, in Layout Fixer's settings. A word undone fewer than 3 times is only "
            + "remembered while Layout Fixer runs (at most 30 days), never written down.")
        privacy.textColor = .secondaryLabelColor
        privacy.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        privacy.preferredMaxLayoutWidth = width
        for subview in [about, scroll, buttons, privacy] { view.addArrangedSubview(subview) }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, let column = Column(rawValue: id.rawValue), row < shown.count
        else { return nil }
        let entry = shown[row]
        let text: String
        switch column {
        case .typed: text = entry.word
        case .other: text = (sampleOnly ? nil : model.otherReading(entry)) ?? sampleReading(entry)
        case .how: text = entry.origin == .added ? "added by you" : "learned"
        case .since: text = entry.since?.formatted(date: .numeric, time: .omitted) ?? ""
        }
        let cell = NSTextField(labelWithString: text)
        cell.lineBreakMode = .byTruncatingTail
        if column == .other || column == .how || column == .since { cell.textColor = .secondaryLabelColor }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = !table.selectedRowIndexes.isEmpty
    }

    private func sampleReading(_ entry: Exclusions.Entry) -> String {
        sampleOnly ? ["csv": "сім", "ltd": "дев", "jira": "оштф"][entry.word] ?? "—" : "—"
    }

    // MARK: Actions

    @objc private func removeSelected() {
        guard !sampleOnly else { return }
        let entries = table.selectedRowIndexes.compactMap { $0 < shown.count ? shown[$0] : nil }
        guard !entries.isEmpty else { return }
        model.remove(entries)
        table.deselectAll(nil)
        refresh()
    }

    @objc private func addWord() {
        guard !sampleOnly else { return }
        let alert = NSAlert()
        alert.messageText = "Add a word to leave as typed"
        alert.informativeText = "Type it the way you type it, for example csv. Fix while typing won't change it."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "csv"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let problem = model.add(field.stringValue) {
            let refusal = NSAlert()
            refusal.messageText = "Couldn't add it"
            refusal.informativeText = problem
            refusal.runModal()
            return
        }
        refresh()
    }
}
