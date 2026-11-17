import AppKit
import Carbon
import ServiceManagement
import os

// Diagnostics only: counts and lengths, never what was typed.
// Read with: log stream --predicate 'subsystem == "io.github.m-ilchuk.layoutfixer"'
let log = Logger(subsystem: "io.github.m-ilchuk.layoutfixer", category: "fixer")

// Events this app posts carry this marker so its own tap lets them through untouched.
let syntheticMarker: Int64 = 0x4C46_4958  // "LFIX"
let maxBufferLength = 300
let keyDelayMicroseconds: useconds_t = 1500
let rightOptionTapSeconds: TimeInterval = 0.4
/// Longer selections are converted but not selected again (that takes one ⇧← per character).
let maxReselectByArrows = 500

enum KeyCode {
    static let space: UInt16 = 49
    static let delete: UInt16 = 51
    static let c: UInt16 = 8
    static let v: UInt16 = 9
    static let leftArrow: UInt16 = 123
    static let rightOption: UInt16 = 61
    // Keys that move the caret or end the line: the typed buffer no longer matches the screen.
    static let resetting: Set<UInt16> = [36, 76, 48, 53, 117, 115, 119, 116, 121, 123, 124, 125, 126]
}

final class Fixer {
    var layouts = LayoutSet(layouts: [])
    var currentLayoutID: String?
    var buffer: [Typed] = []
    /// Right ⌥ was tapped: convert the selection once the key is up.
    var pending = false
    private var lastConversion = LastConversion()
    /// A selection is being copied, converted and pasted (about half a second); taps meanwhile are ignored,
    /// or two pastes land on top of each other and the text doubles.
    private var convertingSelection = false
    var enabled = true
    var autoFix = UserDefaults.standard.bool(forKey: "autoFix") {
        didSet { UserDefaults.standard.set(autoFix, forKey: "autoFix") }
    }

    func reloadLayouts() {
        layouts = LayoutSet(layouts: KeyLayout.enabledLayouts(),
                            preferredLocalID: UserDefaults.standard.string(forKey: "preferredLocal"))
        layoutChanged()
    }

    /// The layout changed (by you or by a fix). A local layout becomes the one English flips to from now on.
    func layoutChanged(to id: String? = KeyLayout.currentLayoutID()) {
        currentLayoutID = id
        guard let id, let layout = layouts.layout(id: id), layout.language != LayoutSet.englishLanguage else { return }
        layouts.preferredLocalID = id
        UserDefaults.standard.set(id, forKey: "preferredLocal")
    }

    func reset() { buffer.removeAll() }

    // MARK: Event tap

    /// Returns false when the event must be swallowed.
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        guard enabled, event.getIntegerValueField(.eventSourceUserData) != syntheticMarker else { return true }
        switch type {
        case .keyDown:
            return handleKeyDown(event)
        case .flagsChanged:
            let held = event.flags.intersection([.maskAlternate, .maskShift, .maskCommand, .maskControl])
            trackRightOptionTap(keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)), held: held)
            // Act once ⌥/⇧ are released, so the text we type is not mixed with held modifiers.
            if held.isEmpty && pending {
                pending = false
                convertSelection()
            }
            return true
        default:
            rightOptionDownAt = nil
            reset()  // a click moves the caret
            return true
        }
    }

    // Right ⌥ pressed and released on its own, quickly, with nothing else in between.
    private var rightOptionDownAt: Date?

    private func trackRightOptionTap(keyCode: UInt16, held: CGEventFlags) {
        guard keyCode == KeyCode.rightOption else { rightOptionDownAt = nil; return }
        if held == .maskAlternate {
            rightOptionDownAt = Date()
        } else if held.isEmpty, let downAt = rightOptionDownAt {
            rightOptionDownAt = nil
            guard Date().timeIntervalSince(downAt) < rightOptionTapSeconds else { return }
            log.info("hotkey: right option tap")
            pending = true
        } else {
            rightOptionDownAt = nil
        }
    }

    private var loggedFirstKey = false

    private func handleKeyDown(_ event: CGEvent) -> Bool {
        if !loggedFirstKey { loggedFirstKey = true; log.info("receiving key presses") }
        rightOptionDownAt = nil
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let command = flags.contains(.maskCommand) || flags.contains(.maskControl)
        if command || KeyCode.resetting.contains(keyCode) {
            reset()
            return true
        }
        if keyCode == KeyCode.delete {
            if flags.contains(.maskAlternate) { reset() } else if !buffer.isEmpty { buffer.removeLast() }
            return true
        }
        guard let layoutID = currentLayoutID, let layout = layouts.layout(id: layoutID) else {
            reset()
            return true
        }
        let stroke = KeyStroke(keyCode: keyCode, modifiers: carbonModifiers(flags))
        guard let text = layout.character(for: stroke), text.count == 1 else {
            reset()
            return true
        }
        if text == " " && autoFix && fixWordBeforeSpace() { return false }
        buffer.append(Typed(stroke: stroke, layoutID: layoutID, text: text))
        if buffer.count > maxBufferLength { buffer.removeFirst(buffer.count - maxBufferLength) }
        return true
    }

    private func carbonModifiers(_ flags: CGEventFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.maskShift) { modifiers |= KeyStroke.shift }
        if flags.contains(.maskAlphaShift) { modifiers |= KeyStroke.capsLock }
        if flags.contains(.maskAlternate) { modifiers |= KeyStroke.option }
        return modifiers
    }

    // MARK: Fixing

    /// Right ⌥: the selected text, or with nothing selected the last word typed, goes to the other layout.
    /// Another tap converts it back.
    private func convertSelection() {
        guard !convertingSelection else {
            log.info("tap ignored: the last conversion is still pasting")
            return
        }
        let selection = Selection.current()
        if let selection, !selection.text.isEmpty {
            log.info("selection via accessibility: \(selection.text.count) chars")
            return fixSelection(selection)
        }
        if buffer.contains(where: { !$0.isSpace }) {
            log.info("no selection; converting the last word")
            return fixLastWord()
        }
        guard selection == nil else {
            log.info("nothing selected, nothing typed")
            return NSSound.beep()
        }
        log.info("the app doesn't share its selection; copying it")
        fixSelection(nil)
    }

    /// Erase the last word typed and type the same keys on the other layout.
    private func fixLastWord() {
        guard let range = Converter.lastWord(of: buffer),
              let typedOn = buffer[range].last(where: { !$0.isSpace })?.layoutID,
              let source = layouts.layout(id: typedOn), let target = layouts.other(than: typedOn)
        else { return NSSound.beep() }
        let fixed = Converter.retype(buffer[range], on: target)
        Typist.erase(count: range.count)
        Typist.type(fixed.map(\.text).joined())
        buffer.replaceSubrange(range, with: fixed)
        switchLayout(to: target, from: source)
    }

    /// Auto mode: on space, fix the word just finished if only the other layout makes it a word.
    private func fixWordBeforeSpace() -> Bool {
        guard let (range, target) = AutoFix.fix(buffer: buffer, layouts: layouts) else { return false }
        let source = buffer.last.flatMap { layouts.layout(id: $0.layoutID) }
        let fixed = Converter.retype(buffer[range], on: target)
        log.info("auto-fix: \(AutoFix.wordRanges(in: Array(self.buffer[range])).count) words")
        Typist.erase(count: range.count)
        Typist.type(fixed.map(\.text).joined() + " ")
        buffer.replaceSubrange(range, with: fixed)
        buffer.append(Typed(stroke: KeyStroke(keyCode: KeyCode.space, modifiers: 0), layoutID: target.id, text: " "))
        switchLayout(to: target, from: source)
        return true
    }

    /// Convert the selected text, paste it over the selection, select it again, switch the layout and restore
    /// the clipboard. Apps that don't share the selection through Accessibility (some browsers) get it copied with ⌘C.
    private func fixSelection(_ selection: Selection.Current?) {
        convertingSelection = true
        let pasteboard = NSPasteboard.general
        let saved = Clipboard.save(pasteboard)
        let replace: (String?) -> Void = { [weak self] text in
            guard let self else { return }
            guard let text, let (converted, target) = self.conversion(of: text) else {
                log.info("nothing to convert (copied: \(text?.count ?? -1) chars)")
                Clipboard.restore(saved, to: pasteboard)
                self.convertingSelection = false
                NSSound.beep()
                return
            }
            self.lastConversion.remember(original: text, output: converted,
                                         originalLayoutID: self.layouts.other(than: target.id)?.id)
            pasteboard.clearContents()
            pasteboard.setString(converted, forType: .string)
            Typist.shortcut(KeyCode.v)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { Selection.reselect(converted, after: selection) }
            self.reset()
            self.switchLayout(to: target, from: self.layouts.other(than: target.id))
            log.info("selection converted: \(converted.count) chars → \(target.id, privacy: .public)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                Clipboard.restore(saved, to: pasteboard)
                self.convertingSelection = false
            }
        }
        if let selection { return replace(selection.text) }
        let before = pasteboard.changeCount
        Typist.shortcut(KeyCode.c)
        Clipboard.waitForChange(pasteboard, from: before, then: replace)
    }

    /// The text on the other layout. Tapping again on what the last tap produced puts back exactly what was there.
    private func conversion(of text: String) -> (text: String, target: KeyLayout)? {
        if let back = lastConversion.undo(of: text), let id = back.layoutID, let layout = layouts.layout(id: id) {
            return (back.text, layout)
        }
        return Converter.convert(text: text, layouts: layouts, currentID: currentLayoutID)
    }

    private func switchLayout(to layout: KeyLayout, from source: KeyLayout?) {
        layout.select()
        layoutChanged(to: layout.id)
        Flash.shared.show(from: source, to: layout)
    }
}

/// Posts keystrokes marked as ours.
enum Typist {
    private static let source: CGEventSource? = {
        let source = CGEventSource(stateID: .privateState)
        source?.userData = syntheticMarker
        return source
    }()

    static func erase(count: Int) {
        for _ in 0..<count { press(KeyCode.delete, flags: []) }
    }

    static func type(_ text: String) {
        for char in text {
            let units = Array(String(char).utf16)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                post(event)
            }
        }
    }

    static func shortcut(_ keyCode: UInt16) {
        press(keyCode, flags: .maskCommand)
    }

    /// ⇧← `count` times: selects that many characters before the cursor.
    static func selectBackward(count: Int) {
        for _ in 0..<count { press(KeyCode.leftArrow, flags: .maskShift) }
    }

    private static func press(_ keyCode: UInt16, flags: CGEventFlags) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            event.flags = flags
            post(event)
        }
    }

    private static func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        event.post(tap: .cghidEventTap)
        usleep(keyDelayMicroseconds)
    }
}

enum Selection {
    /// The selection in the focused field, read through Accessibility (Mail, Notes, Slack, most native apps).
    struct Current {
        let element: AXUIElement
        let text: String  // empty: nothing is selected
        let range: CFRange?
    }

    /// nil when the app doesn't share its selection.
    static func current() -> Current? {
        guard let element = focusedElement() else { return nil }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String
        else { return nil }
        return Current(element: element, text: text, range: selectedRange(in: element))
    }

    /// Select the text just pasted over `selection`, so the next tap converts it back:
    /// through Accessibility where the app allows it, otherwise with ⇧←.
    static func reselect(_ pasted: String, after selection: Current?) {
        if let selection, let start = selection.range {
            var range = CFRange(location: start.location, length: (pasted as NSString).length)
            if let value = AXValueCreate(.cfRange, &range),
               AXUIElementSetAttributeValue(selection.element, kAXSelectedTextRangeAttribute as CFString, value) == .success {
                return
            }
        }
        guard pasted.count <= maxReselectByArrows else { return }
        Typist.selectBackward(count: pasted.count)
    }

    private static func selectedRange(in element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    /// Where the text cursor is on screen (top-left origin), for apps that say so.
    static func caretRect() -> CGRect? {
        guard let element = focusedElement() else { return nil }
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
              let range
        else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds) == .success,
              let bounds, CFGetTypeID(bounds) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect), rect.height > 0 else { return nil }
        return rect
    }

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return nil }
        return (element as! AXUIElement)
    }
}

enum Clipboard {
    typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

    static func save(_ pasteboard: NSPasteboard) -> Snapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { copy[type] = item.data(forType: type) }
            return copy
        }
    }

    static func restore(_ snapshot: Snapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = snapshot.map { saved -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in saved { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    static func waitForChange(_ pasteboard: NSPasteboard, from count: Int, attempt: Int = 0,
                              then done: @escaping (String?) -> Void) {
        if pasteboard.changeCount != count { return done(pasteboard.string(forType: .string)) }
        if attempt >= 10 { return done(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            waitForChange(pasteboard, from: count, attempt: attempt + 1, then: done)
        }
    }
}

// MARK: App

let fixer = Fixer()
var eventTap: CFMachPort?

func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    return fixer.handle(type: type, event: event) ? Unmanaged.passUnretained(event) : nil
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var tapRetry: Timer?
    private var waitingForAccess = false
    /// macOS already shows the layout (its "A" / "УК" menu); this icon is only for settings, so it can go.
    private var hideIcon = UserDefaults.standard.bool(forKey: "hideIcon") {
        didSet { UserDefaults.standard.set(hideIcon, forKey: "hideIcon"); refreshIcon() }
    }
    private let updater = Updater()
    private lazy var settingsWindow = SettingsWindow(settings: settings, status: { [unowned self] in self.status() },
                                                     update: { [unowned self] in self.updateFromWindow() })

    /// Every on/off setting, in the order the window shows them (the quick menu has only Enabled).
    private lazy var settings: [Setting] = [
        Setting(title: AppDelegate.enabledSettingTitle, isOn: { fixer.enabled }, set: { [unowned self] on in
            fixer.enabled = on
            fixer.reset()
            self.refreshIcon()
        }),
        Setting(title: "Fix automatically while typing (beta)", isOn: { fixer.autoFix }, set: { fixer.autoFix = $0 }),
        Setting(title: "Show a flash when fixing", isOn: { Flash.shared.enabled }, set: { Flash.shared.enabled = $0 }),
        Setting(title: "Open at login", isOn: { SMAppService.mainApp.status == .enabled },
                set: { [unowned self] on in self.setOpenAtLogin(on) }),
        Setting(title: "Show icon in menu bar", isOn: { [unowned self] in !self.hideIcon },
                set: { [unowned self] on in self.hideIcon = !on }),
        Setting(title: "Check for updates automatically", isOn: { [unowned self] in self.updater.automatic },
                set: { [unowned self] on in self.updater.automatic = on }),
    ]
    private static let enabledSettingTitle = "Enabled"

    func applicationDidFinishLaunching(_ notification: Notification) {
        fixer.reloadLayouts()
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                           object: nil, queue: .main) { _ in
            fixer.layoutChanged()
            self.changed()
        }
        center.addObserver(forName: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
                           object: nil, queue: .main) { _ in fixer.reloadLayouts(); self.changed() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in fixer.reset() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Click: the settings window. Right-click or ⌥-click: a short menu.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        refreshIcon()
        startTap()
        updater.onChange = { [weak self] in self?.changed(); self?.refreshIcon() }
        updater.start()

        // Open at login belongs to the app's place on disk: after a move or rename, turn it back on.
        if UserDefaults.standard.bool(forKey: "openAtLogin") && SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }

        // First launch, or not allowed yet: show the window, which says what to do (the icon may be hidden).
        let firstLaunch = !UserDefaults.standard.bool(forKey: "launchedBefore")
        UserDefaults.standard.set(true, forKey: "launchedBefore")
        if firstLaunch || !AXIsProcessTrusted() { settingsWindow.show() }
    }

    func settingsSnapshot(to url: URL) throws {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        try settingsWindow.snapshot(to: url)
    }

    /// Opening the app again (Spotlight, Finder) while it runs shows its window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        settingsWindow.show()
        return false
    }

    /// Something the window shows changed (the quick menu is built each time it opens).
    private func changed() {
        settingsWindow.refresh()
    }

    private func status() -> SettingsStatus {
        let commit = Updater.currentCommit.map { " (\($0.prefix(7)))" } ?? ""
        let update: (String, Bool)
        if updater.installing {
            update = ("Updating…", false)
        } else if case .available(let release) = updater.status {
            update = ("Install version \(release.version)…", true)
        } else {
            update = ("Check for Updates…", true)
        }
        return SettingsStatus(accessAllowed: AXIsProcessTrusted(), pair: Setup.pairLine(fixer.layouts),
                              version: "\(Updater.currentVersion?.description ?? "?")\(commit)",
                              updateTitle: update.0, updateEnabled: update.1)
    }

    private func updateFromWindow() {
        if case .available = updater.status { installUpdate() } else { checkForUpdates() }
    }

    private var askedForAccess = false

    private func startTap() {
        // Ask macOS once per launch; the retries below only check, so the dialog doesn't keep coming back.
        if !askedForAccess {
            askedForAccess = true
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }

        let trusted = AXIsProcessTrusted()
        let listen = CGPreflightListenEventAccess()
        log.info("access: accessibility=\(trusted) inputMonitoring=\(listen)")
        // A tap made before Accessibility is granted gets no key presses even after it is granted, so wait for it.
        // A tap that can change keys needs only Accessibility; Input Monitoring is for listen-only taps.
        waitingForAccess = !trusted
        guard trusted else {
            refreshIcon()
            retryTap()
            return
        }
        let mask: CGEventMask = [CGEventType.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            .reduce(0) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: tapCallback, userInfo: nil)
        else {
            log.error("tapCreate failed although access is granted")
            waitingForAccess = true
            refreshIcon()
            retryTap()
            return
        }
        eventTap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log.info("listening for keys")
        refreshIcon()
        settingsWindow.refresh()
    }

    private func retryTap() {
        tapRetry?.invalidate()
        tapRetry = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in self.startTap() }
    }

    /// A small keyboard icon; a warning sign (shown even when hidden) while Accessibility is not allowed.
    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        let symbol = waitingForAccess ? "exclamationmark.triangle"
            : updater.installing ? "arrow.triangle.2.circlepath" : "keyboard"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Layout Fixer")
        button.image?.isTemplate = true
        button.title = ""
        button.appearsDisabled = !fixer.enabled && !waitingForAccess
        button.toolTip = waitingForAccess
            ? "Layout Fixer: allow it in System Settings › Privacy & Security › Accessibility"
            : (fixer.enabled ? "Layout Fixer" : "Layout Fixer (off)")
        statusItem.isVisible = waitingForAccess || updater.installing || !hideIcon
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.option) == true {
            showQuickMenu()
        } else {
            settingsWindow.show()
        }
    }

    /// Right-click on the icon: pause it, install an update, open the window or quit, without the window.
    private func showQuickMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if updater.installing {
            menu.addItem(info("Updating… (about a minute; restarts by itself)"))
            menu.addItem(.separator())
        } else if case .available(let release) = updater.status {
            menu.addItem(item("Install version \(release.version)…", action: #selector(installUpdate)))
            menu.addItem(.separator())
        }
        if let enabled = settings.firstIndex(where: { $0.title == AppDelegate.enabledSettingTitle }) {
            let entry = toggle(settings[enabled].title, on: settings[enabled].isOn(), action: #selector(toggleSetting(_:)))
            entry.tag = enabled
            menu.addItem(entry)
        }
        menu.addItem(item("Settings…", action: #selector(showSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit Layout Fixer", action: #selector(quit), key: "q"))
        // Attach the menu just for this click, so a plain click keeps opening the window.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func toggle(_ title: String, on: Bool, action: Selector) -> NSMenuItem {
        let item = item(title, action: action)
        item.state = on ? .on : .off
        return item
    }

    @objc private func toggleSetting(_ sender: NSMenuItem) {
        let setting = settings[sender.tag]
        setting.set(!setting.isOn())
        changed()
    }

    @objc private func showSettings() { settingsWindow.show() }

    @objc private func checkForUpdates() {
        updater.check { [weak self] status in
            switch status {
            case .available: self?.installUpdate()
            case .upToDate: self?.tell("Layout Fixer is up to date.", "")
            case .failed(let reason): self?.tell("Couldn't check for updates", reason)
            case .unknown: break
            }
        }
    }

    @objc private func installUpdate() {
        guard !updater.installing, case .available(let release) = updater.status else { return }
        let alert = NSAlert()
        alert.messageText = "Install Layout Fixer \(release.version)?"
        alert.informativeText = "It builds on this Mac (about a minute) and restarts by itself, "
            + "keeping its Accessibility permission."
        if !release.notes.isEmpty { alert.accessoryView = ReleaseNotesView.make(release.notes) }
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        updater.install()
    }

    private func tell(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func setOpenAtLogin(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "openAtLogin")
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            tell("Could not change Open at login",
                 "\(error.localizedDescription)\nAdd Layout Fixer in System Settings › General › Login Items instead.")
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// `LayoutFixer --layouts`: print what it will switch between (the installer shows this) and exit.
if CommandLine.arguments.contains("--layouts") {
    let layouts = LayoutSet(layouts: KeyLayout.enabledLayouts(),
                            preferredLocalID: UserDefaults.standard.string(forKey: "preferredLocal"))
    Setup.summary(layouts, speller: SystemSpeller()).forEach { print($0) }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()

// `LayoutFixer --settings-snapshot file.png`: render the settings window to an image (README) and exit.
if let flag = CommandLine.arguments.firstIndex(of: "--settings-snapshot"), flag + 1 < CommandLine.arguments.count {
    fixer.reloadLayouts()
    do { try delegate.settingsSnapshot(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1])) } catch {
        print("could not write the snapshot: \(error.localizedDescription)")
        exit(1)
    }
    exit(0)
}
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
