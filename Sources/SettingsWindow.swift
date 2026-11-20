import AppKit

/// One on/off setting, shown in both the menu bar menu and the settings window.
struct Setting {
    let title: String
    let isOn: () -> Bool
    let set: (Bool) -> Void
}

/// What the window shows about the app right now.
struct SettingsStatus {
    let accessAllowed: Bool
    let pair: String
    let version: String
    /// "Check for Updates…", "Install version 0.2.0…" or "Updating…" (then disabled).
    let updateTitle: String
    let updateEnabled: Bool
    /// While an update installs: how far it is.
    let progress: UpdateProgress.State?
}

/// The Layout Fixer window: opens when the app is opened again (Spotlight, Finder) and on a first launch, so
/// everything works even when the menu bar icon is hidden, by the setting or behind a MacBook's notch.
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let width: CGFloat = 460
    static let refreshSeconds: TimeInterval = 1.5
    static let snapshotSettleSeconds: TimeInterval = 0.3

    private let settings: [Setting]
    private let status: () -> SettingsStatus
    private let updateAction: () -> Void
    private let window: NSWindow
    private let accessLabel = NSTextField(labelWithString: "")
    private let accessHelp = NSTextField(wrappingLabelWithString: "")
    private let accessButton = NSButton(title: "Open Accessibility Settings…", target: nil, action: nil)
    private let pairLabel = NSTextField(labelWithString: "")
    private let versionLabel = NSTextField(labelWithString: "")
    private let updateButton = NSButton(title: "", target: nil, action: nil)
    private let progressBar = NSProgressIndicator()
    private let progressLabel = NSTextField(labelWithString: "")
    private lazy var progressRow = NSStackView(views: [progressBar, progressLabel])
    private var checkboxes: [NSButton] = []
    private var refreshTimer: Timer?

    private let exportAction: () -> Void
    private let statistics: () -> Statistics.Summary
    private let resetStatisticsAction: () -> Void

    /// The pages, picked at the top: General (settings, the README picture) and Statistics.
    private let pagePicker = NSSegmentedControl(labels: ["General", "Statistics", "Exclusions"], trackingMode: .selectOne,
                                                target: nil, action: nil)
    private let generalPage = NSStackView()
    private let statisticsPage = NSStackView()
    private let exclusionsPage: ExclusionsPage
    /// Rows: fixed while typing, converted with right ⌥, undone; columns: today, 7 days, all time.
    private var statisticsCells: [[NSTextField]] = []
    private let keptLabel = NSTextField(labelWithString: "")
    private let sinceLabel = NSTextField(labelWithString: "")

    init(settings: [Setting], status: @escaping () -> SettingsStatus, update: @escaping () -> Void,
         exportLog: @escaping () -> Void, statistics: @escaping () -> Statistics.Summary,
         resetStatistics: @escaping () -> Void, exclusions: ExclusionsPage.Model) {
        self.settings = settings
        self.status = status
        self.updateAction = update
        self.exportAction = exportLog
        self.statistics = statistics
        self.resetStatisticsAction = resetStatistics
        self.exclusionsPage = ExclusionsPage(model: exclusions, width: SettingsWindow.width - 40)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsWindow.width, height: 100),
                          styleMask: [.titled, .closable], backing: .buffered, defer: true)
        super.init()
        window.title = "Layout Fixer"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = makeContent()
    }

    func show() {
        refresh()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Keep the Accessibility line current while the window is open (it changes in System Settings).
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: SettingsWindow.refreshSeconds, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        let now = status()
        accessLabel.stringValue = now.accessAllowed ? "✓  Allowed in Accessibility" : "⚠  Not allowed in Accessibility yet"
        accessLabel.textColor = now.accessAllowed ? .systemGreen : .systemOrange
        accessHelp.isHidden = now.accessAllowed
        accessButton.isHidden = now.accessAllowed
        pairLabel.stringValue = now.pair
        versionLabel.stringValue = now.version
        updateButton.title = now.updateTitle
        updateButton.isEnabled = now.updateEnabled
        progressRow.isHidden = now.progress == nil
        if let progress = now.progress {
            progressBar.doubleValue = progress.fraction
            progressLabel.stringValue = "\(progress.step) \(progress.percent)%"
        }
        for (checkbox, setting) in zip(checkboxes, settings) { checkbox.state = setting.isOn() ? .on : .off }
        if !statisticsPage.isHidden { refreshStatistics() }
        if !exclusionsPage.view.isHidden { exclusionsPage.refresh() }
    }

    private func refreshStatistics() {
        let summary = statistics()
        let periods = [summary.today, summary.lastSevenDays, summary.allTime]
        let rows: [(Statistics.Counts) -> Int] = [{ $0.autoFixed }, { $0.converted }, { $0.undone }]
        for (cells, value) in zip(statisticsCells, rows) {
            for (cell, counts) in zip(cells, periods) { cell.stringValue = value(counts).formatted() }
        }
        if let kept = summary.lastSevenDays.keptRate {
            keptLabel.stringValue = "You kept \(Int((kept * 100).rounded()))% of the words fixed while typing in the last 7 days."
        } else {
            keptLabel.stringValue = "No words fixed while typing in the last 7 days."
        }
        sinceLabel.stringValue = "Counts words, not fixes: zr cghfdb → як справи is one fix of 2 words. "
            + "Counting since \(summary.since.formatted(date: .long, time: .omitted)). "
            + "Statistics keep only counts, never what you type."
    }

    /// Render the window's content to a PNG without showing it (`LayoutFixer --settings-snapshot file.png`).
    func snapshot(to url: URL, appearance: NSAppearance.Name = .aqua) throws {
        refresh()
        window.appearance = NSAppearance(named: appearance)
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        window.setContentSize(view.fittingSize)
        // On screen (out of sight) for a moment: a table draws its rows only once its window has been shown.
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(SettingsWindow.snapshotSettleSeconds))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        defer { window.orderOut(nil) }
        guard let content = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: content)
        // The view itself is transparent: put it on the window's own background (with its rounded corners and a
        // hairline), so the image reads on any page, GitHub's dark theme included.
        guard let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: content.pixelsWide,
                                           pixelsHigh: content.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
                                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                           bytesPerRow: 0, bitsPerPixel: 0)
        else { return }
        image.size = content.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
        let frame = NSRect(origin: .zero, size: content.size).insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12)
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            shape.fill()
            NSColor.separatorColor.setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }
        // Over the background, not in place of it (a bare draw(in:) copies the transparent pixels too).
        content.draw(in: NSRect(origin: .zero, size: content.size), from: .zero, operation: .sourceOver,
                     fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        try image.representation(using: .png, properties: [:])?.write(to: url)
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: Layout

    private func makeContent() -> NSView {
        let title = NSTextField(labelWithString: "Layout Fixer")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        versionLabel.textColor = .secondaryLabelColor
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 40).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let heading = row([icon, title, versionLabel])
        heading.alignment = .centerY

        accessLabel.font = .systemFont(ofSize: 13, weight: .medium)
        accessHelp.stringValue = "Turn on Layout Fixer in the list. Already on? That entry is from an older build: "
            + "select it, click –, then open Layout Fixer again and allow it. Not there? Click +, press ⌘⇧G, "
            + "type ~/Applications/Layout Fixer.app, click Open and turn it on."
        accessHelp.textColor = .secondaryLabelColor
        accessButton.target = self
        accessButton.action = #selector(openAccessibility)
        accessButton.bezelStyle = .rounded

        let usage = NSTextField(wrappingLabelWithString:
            "Tap the right ⌥ key on its own: it converts the selected text, or the last word you typed, "
            + "to the other layout and switches the keyboard. Tap again to convert it back.")
        pairLabel.textColor = .secondaryLabelColor

        checkboxes = settings.enumerated().map { index, setting in
            let checkbox = NSButton(checkboxWithTitle: setting.title, target: self, action: #selector(toggle(_:)))
            checkbox.tag = index
            return checkbox
        }

        let notch = NSTextField(wrappingLabelWithString:
            "Click the keyboard icon in the menu bar to get back here (right-click it for a short menu). Can't "
            + "see it? On MacBooks with a notch, macOS hides icons that don't fit: open Layout Fixer again "
            + "(Spotlight) instead.")
        notch.textColor = .secondaryLabelColor
        notch.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        updateButton.target = self
        updateButton.action = #selector(update)
        updateButton.bezelStyle = .rounded
        let quit = NSButton(title: "Quit", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .rounded
        let export = NSButton(title: "Export Debug Log…", target: self, action: #selector(exportLog))
        export.bezelStyle = .rounded
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.widthAnchor.constraint(equalToConstant: 200).isActive = true
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        progressRow.orientation = .horizontal
        progressRow.spacing = 10
        progressRow.isHidden = true

        for view in [accessLabel, accessHelp, accessButton, separator(), usage, pairLabel, separator()]
            + checkboxes + [separator(), notch, row([updateButton, export, quit]), progressRow] {
            generalPage.addArrangedSubview(view)
        }
        for page in [generalPage, statisticsPage] {
            page.orientation = .vertical
            page.alignment = .leading
            page.spacing = 10
        }
        for view in [accessHelp, usage, notch] {
            view.preferredMaxLayoutWidth = SettingsWindow.width - 40
        }
        generalPage.setCustomSpacing(4, after: accessLabel)
        generalPage.setCustomSpacing(4, after: usage)
        makeStatisticsPage()
        statisticsPage.isHidden = true
        exclusionsPage.view.isHidden = true

        pagePicker.selectedSegment = 0
        pagePicker.target = self
        pagePicker.action = #selector(pickPage)
        let stack = NSStackView(views: [heading, pagePicker, generalPage, statisticsPage, exclusionsPage.view])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: SettingsWindow.width).isActive = true
        return stack
    }

    private func makeStatisticsPage() {
        let headers = ["Words", "Today", "7 days", "All time"].map { title -> NSTextField in
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            label.textColor = .secondaryLabelColor
            return label
        }
        let titles = ["Fixed while typing", "Converted with right ⌥", "Fixed, then undone by you"]
        statisticsCells = titles.map { _ in
            (0..<3).map { _ in
                let cell = NSTextField(labelWithString: "0")
                cell.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
                return cell
            }
        }
        let grid = NSGridView(views: [headers] + zip(titles, statisticsCells).map { [NSTextField(labelWithString: $0)] + $1 })
        grid.rowSpacing = 8
        grid.columnSpacing = 22
        for column in 1..<4 { grid.column(at: column).xPlacement = .trailing }
        keptLabel.font = .systemFont(ofSize: 13, weight: .medium)
        sinceLabel.textColor = .secondaryLabelColor
        sinceLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        sinceLabel.lineBreakMode = .byWordWrapping
        sinceLabel.maximumNumberOfLines = 0
        sinceLabel.preferredMaxLayoutWidth = SettingsWindow.width - 40
        let reset = NSButton(title: "Reset Statistics…", target: self, action: #selector(resetStatistics))
        reset.bezelStyle = .rounded
        for view in [grid, separator(), keptLabel, sinceLabel, reset] { statisticsPage.addArrangedSubview(view) }
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: SettingsWindow.width - 40).isActive = true
        return line
    }

    // MARK: Actions

    @objc private func toggle(_ sender: NSButton) {
        settings[sender.tag].set(sender.state == .on)
        refresh()
    }

    /// The Exclusions page shows made-up words (for a picture), never the person's own.
    func showSampleExclusions() { exclusionsPage.showSample() }

    /// 0 General, 1 Statistics, 2 Exclusions.
    func select(page: Int) {
        pagePicker.selectedSegment = page
        pickPage()
    }

    @objc private func pickPage() {
        generalPage.isHidden = pagePicker.selectedSegment != 0
        statisticsPage.isHidden = pagePicker.selectedSegment != 1
        exclusionsPage.view.isHidden = pagePicker.selectedSegment != 2
        refresh()
    }

    @objc private func resetStatistics() {
        let alert = NSAlert()
        alert.messageText = "Reset statistics?"
        alert.informativeText = "All counts go back to 0 and counting starts again from now. This can't be undone."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        resetStatisticsAction()
        refresh()
    }

    @objc private func update() { updateAction() }
    @objc private func exportLog() { exportAction() }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
