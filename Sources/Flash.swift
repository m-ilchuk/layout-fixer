import AppKit

/// A small "EN → UK" badge under the text cursor for a moment after a fix, so a fix you didn't trigger
/// (fix-while-typing) doesn't go unnoticed. Next to the mouse pointer where an app doesn't tell where its cursor is.
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
    private var hideTimer: Timer?

    func show(from source: KeyLayout?, to target: KeyLayout) {
        guard enabled else { return }
        let from = source.map { $0.language.uppercased() + " → " } ?? ""
        // Wait a moment so the cursor has moved to the end of the retyped text.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self.present(from + target.language.uppercased()) }
    }

    /// A short message instead of the layouts, `delay` seconds from now (after a layout flash has faded).
    func say(_ text: String, after delay: TimeInterval = 0) {
        guard enabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.present(text) }
    }

    private func present(_ text: String) {
        label.stringValue = text
        let padding = NSSize(width: 10, height: 4)
        let textSize = label.fittingSize
        let size = NSSize(width: textSize.width + 2 * padding.width, height: textSize.height + 2 * padding.height)
        label.frame = NSRect(origin: NSPoint(x: padding.width, y: padding.height), size: textSize)
        panel.setFrame(NSRect(origin: position(for: size), size: size), display: true)
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
    private func position(for size: NSSize) -> NSPoint {
        let gap: CGFloat = 4
        if let caret = Selection.caretRect(), let screenHeight = NSScreen.screens.first?.frame.height {
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
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 7
        background.layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .labelColor
        background.addSubview(label)
        panel.contentView = background
        return panel
    }
}
