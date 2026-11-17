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
}

/// The Layout Fixer window: opens when the app is opened again (Spotlight, Finder) and on a first launch, so
/// everything works even when the menu bar icon is hidden, by the setting or behind a MacBook's notch.
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let width: CGFloat = 460
    static let refreshSeconds: TimeInterval = 1.5

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
    private var checkboxes: [NSButton] = []
    private var refreshTimer: Timer?

    init(settings: [Setting], status: @escaping () -> SettingsStatus, update: @escaping () -> Void) {
        self.settings = settings
        self.status = status
        self.updateAction = update
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
        for (checkbox, setting) in zip(checkboxes, settings) { checkbox.state = setting.isOn() ? .on : .off }
    }

    /// Render the window's content to a PNG without showing it (`LayoutFixer --settings-snapshot file.png`).
    func snapshot(to url: URL, appearance: NSAppearance.Name = .aqua) throws {
        refresh()
        window.appearance = NSAppearance(named: appearance)
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.frame.size = view.fittingSize
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: url)
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
        let heading = row([title, versionLabel])
        heading.alignment = .firstBaseline

        accessLabel.font = .systemFont(ofSize: 13, weight: .medium)
        accessHelp.stringValue = "Turn on LayoutFixer in the list. Not there? Click +, press ⌘⇧G, type "
            + "~/Applications/LayoutFixer.app, click Open and turn it on."
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
            "Can't see the keyboard icon in the menu bar? On MacBooks with a notch, macOS hides icons that don't "
            + "fit. Open LayoutFixer again (Spotlight) to get back to this window.")
        notch.textColor = .secondaryLabelColor
        notch.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        updateButton.target = self
        updateButton.action = #selector(update)
        updateButton.bezelStyle = .rounded
        let quit = NSButton(title: "Quit Layout Fixer", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .rounded

        let stack = NSStackView(views: [heading,
                                        accessLabel, accessHelp, accessButton,
                                        separator(),
                                        usage, pairLabel,
                                        separator()]
                                       + checkboxes
                                       + [separator(), notch, row([updateButton, quit])])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for view in [accessHelp, usage, notch] {
            view.preferredMaxLayoutWidth = SettingsWindow.width - 40
        }
        stack.setCustomSpacing(4, after: accessLabel)
        stack.setCustomSpacing(4, after: usage)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: SettingsWindow.width).isActive = true
        return stack
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

    @objc private func update() { updateAction() }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
