import AppKit

/// The new layout's symbol in a small bubble under the text cursor for a moment after a fix, like macOS's own
/// indicator when you switch layouts, so a fix you didn't trigger (fix-while-typing) doesn't go unnoticed. Next to
/// the mouse pointer where an app doesn't tell where its cursor is.
final class Flash {
    static let shared = Flash()
    static let visibleSeconds = 0.8
    static let fadeSeconds = 0.25

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "flash") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "flash") }
    }

    private lazy var panel = makePanel()
    private let label = NSTextField(labelWithString: "")
    private let symbol = SymbolView()
    private var hideTimer: Timer?

    /// What the bubble holds: the layout's symbol, or a short message.
    private enum Content { case symbol(String), text(String) }

    /// From macOS 14, macOS shows its own indicator under the cursor whenever the layout switches, the app's
    /// switch included: then this one would be a second copy next to it.
    static var systemShowsIndicator: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0))
    }

    /// After a fix. `layoutSwitched`: the fix switched the keyboard too (only the short words before a word were
    /// fixed when it didn't); then, where macOS shows its own indicator, nothing more is shown.
    func show(from source: KeyLayout?, to target: KeyLayout, layoutSwitched: Bool) {
        guard enabled, !(layoutSwitched && Flash.systemShowsIndicator) else { return }
        present(.symbol(LayoutSymbol.name(forLanguage: target.language)))
    }

    /// A short message instead of the layout, `delay` seconds from now (after a layout flash has faded).
    func say(_ text: String, after delay: TimeInterval = 0) {
        guard enabled else { return }
        present(.text(text), after: delay)
    }

    /// Where the cursor is gets asked away from the main thread (the key tap runs there, and an app can be slow
    /// to say), after a moment so the cursor has moved to the end of the retyped text.
    static let caretWaitSeconds = 0.08

    private func present(_ content: Content, after delay: TimeInterval = 0) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay + Flash.caretWaitSeconds) {
            let caret = Selection.caretRect()
            DispatchQueue.main.async { self.present(content, caret: caret) }
        }
    }

    private func present(_ content: Content, caret: CGRect?) {
        let size: NSSize
        switch content {
        case .symbol(let name):
            label.isHidden = true
            symbol.isHidden = false
            symbol.name = name
            let inner = symbol.fittingSize
            let padding = Flash.symbolPadding
            symbol.frame = NSRect(origin: NSPoint(x: padding, y: padding), size: inner)
            size = NSSize(width: inner.width + 2 * padding, height: inner.height + 2 * padding)
        case .text(let text):
            symbol.isHidden = true
            label.isHidden = false
            label.stringValue = text
            let padding = NSSize(width: 10, height: 4)
            let textSize = label.fittingSize
            label.frame = NSRect(origin: NSPoint(x: padding.width, y: padding.height), size: textSize)
            size = NSSize(width: textSize.width + 2 * padding.width, height: textSize.height + 2 * padding.height)
        }
        panel.setFrame(NSRect(origin: position(for: size, caret: caret), size: size), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: Flash.visibleSeconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Flash.fadeSeconds
                self.panel.animator().alphaValue = 0
            }, completionHandler: { self.panel.orderOut(nil) })
        }
    }

    /// Just below the text cursor, or below-right of the mouse pointer.
    private func position(for size: NSSize, caret: CGRect?) -> NSPoint {
        let gap: CGFloat = 4
        if let caret, let screenHeight = NSScreen.screens.first?.frame.height {
            // Accessibility measures from the top of the main screen; windows from the bottom.
            return NSPoint(x: caret.minX, y: screenHeight - caret.maxY - size.height - gap)
        }
        let mouse = NSEvent.mouseLocation
        return NSPoint(x: mouse.x + 12, y: mouse.y - size.height - 12)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // A light bubble that follows light and dark mode, like macOS's indicator.
        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = Flash.bubbleCornerRadius
        background.layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .labelColor
        background.addSubview(label)
        background.addSubview(symbol)
        panel.contentView = background
        return panel
    }

    static let symbolPadding: CGFloat = 5
    static let bubbleCornerRadius: CGFloat = 8
}

/// A layout's symbol: a filled rounded square with its letters cut out, as in the menu bar.
final class SymbolView: NSView {
    static let height: CGFloat = 18
    static let font = NSFont.systemFont(ofSize: 11.5, weight: .bold)
    static let cornerRadius: CGFloat = 4
    static let sidePadding: CGFloat = 4

    var name = "" { didSet { needsDisplay = true } }

    override var fittingSize: NSSize {
        let text = (name as NSString).size(withAttributes: [.font: SymbolView.font])
        return NSSize(width: max(SymbolView.height, ceil(text.width) + 2 * SymbolView.sidePadding), height: SymbolView.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // The square in the text colour, then the letters punched out of it (they show the bubble behind).
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        NSColor.labelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: SymbolView.cornerRadius, yRadius: SymbolView.cornerRadius).fill()
        context.setBlendMode(.destinationOut)
        let attributes: [NSAttributedString.Key: Any] = [.font: SymbolView.font, .foregroundColor: NSColor.black]
        let size = (name as NSString).size(withAttributes: attributes)
        let origin = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        (name as NSString).draw(at: origin, withAttributes: attributes)
        context.endTransparencyLayer()
    }
}
