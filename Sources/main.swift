import AppKit
import Carbon
import ServiceManagement
import os

// Diagnostics only: counts and lengths, never what was typed.
// Read with: log stream --predicate 'subsystem == "io.local.layoutfixer"'
let log = Logger(subsystem: "io.local.layoutfixer", category: "fixer")

// Events this app posts carry this marker so its own tap lets them through untouched.
let syntheticMarker: Int64 = 0x4C46_4958  // "LFIX"
let maxBufferLength = 300
let keyDelayMicroseconds: useconds_t = 1500
let rightOptionTapSeconds: TimeInterval = 0.4

enum KeyCode {
    static let space: UInt16 = 49
    static let delete: UInt16 = 51
    static let c: UInt16 = 8
    static let v: UInt16 = 9
    static let rightOption: UInt16 = 61
    // Keys that move the caret or end the line: the typed buffer no longer matches the screen.
    static let resetting: Set<UInt16> = [36, 76, 48, 53, 117, 115, 119, 116, 121, 123, 124, 125, 126]
}

enum Action { case lastWord, phraseOrSelection, selectionOrLastWord }

final class Fixer {
    var layouts = LayoutSet(layouts: [])
    var currentLayoutID: String?
    var buffer: [Typed] = []
    var pending: Action?
    var enabled = true
    var autoFix = UserDefaults.standard.bool(forKey: "autoFix") {
        didSet { UserDefaults.standard.set(autoFix, forKey: "autoFix") }
    }

    func reloadLayouts() {
        layouts = LayoutSet(layouts: KeyLayout.enabledLayouts())
        currentLayoutID = KeyLayout.currentLayoutID()
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
            if held.isEmpty, let action = pending {
                pending = nil
                run(action)
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
            if Date().timeIntervalSince(downAt) < rightOptionTapSeconds {
                log.info("hotkey: right option tap")
                pending = .selectionOrLastWord
            }
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

        if keyCode == KeyCode.space && flags.contains(.maskAlternate) && !command {
            pending = flags.contains(.maskShift) ? .phraseOrSelection : .lastWord
            log.info("hotkey: option space, shift=\(flags.contains(.maskShift))")
            return false
        }
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

    private func run(_ action: Action) {
        switch action {
        case .lastWord:
            fixTyped(wholePhrase: false)
        case .selectionOrLastWord:
            if let selected = Selection.textViaAccessibility(), !selected.isEmpty {
                log.info("selection via accessibility: \(selected.count) chars")
                fixSelection(knownText: selected)
            } else if buffer.contains(where: { !$0.isSpace }) {
                fixTyped(wholePhrase: false)
            } else {
                fixSelection(knownText: nil)
            }
        case .phraseOrSelection:
            // Selection first: whatever is selected is what you want converted.
            if let selected = Selection.textViaAccessibility(), !selected.isEmpty {
                log.info("selection via accessibility: \(selected.count) chars")
                fixSelection(knownText: selected)
            } else if buffer.contains(where: { !$0.isSpace }) {
                log.info("no selection; fixing typed phrase of \(self.buffer.count) keys")
                fixTyped(wholePhrase: true)
            } else {
                log.info("no selection via accessibility; trying copy")
                fixSelection(knownText: nil)
            }
        }
    }

    /// Erase the segment and type it again as the other layout. Pressing the hotkey again flips it back.
    private func fixTyped(wholePhrase: Bool) {
        guard let range = Converter.segment(of: buffer, wholePhrase: wholePhrase),
              let target = Converter.target(for: buffer[range], in: layouts)
        else { NSSound.beep(); return }
        let fixed = Converter.retype(buffer[range], on: target)
        Typist.erase(count: range.count)
        Typist.type(fixed.map(\.text).joined())
        buffer.replaceSubrange(range, with: fixed)
        switchLayout(to: target)
    }

    /// Auto mode: on space, fix the word just finished if only the other layout makes it a word.
    private func fixWordBeforeSpace() -> Bool {
        guard let (range, target) = AutoFix.fix(buffer: buffer, layouts: layouts) else { return false }
        let fixed = Converter.retype(buffer[range], on: target)
        log.info("auto-fix: \(AutoFix.wordRanges(in: Array(self.buffer[range])).count) words")
        Typist.erase(count: range.count)
        Typist.type(fixed.map(\.text).joined() + " ")
        buffer.replaceSubrange(range, with: fixed)
        buffer.append(Typed(stroke: KeyStroke(keyCode: KeyCode.space, modifiers: 0), layoutID: target.id, text: " "))
        switchLayout(to: target)
        return true
    }

    /// Convert the selected text, paste it over the selection, switch the layout and restore the clipboard.
    /// Apps that don't expose the selection to Accessibility (some browsers) get it copied with ⌘C.
    private func fixSelection(knownText: String?) {
        let pasteboard = NSPasteboard.general
        let saved = Clipboard.save(pasteboard)
        let replace: (String?) -> Void = { [weak self] text in
            guard let self else { return }
            guard let text, let (converted, target) = Converter.convert(text: text, layouts: self.layouts) else {
                log.info("nothing to convert (copied: \(text?.count ?? -1) chars)")
                Clipboard.restore(saved, to: pasteboard)
                NSSound.beep()
                return
            }
            pasteboard.clearContents()
            pasteboard.setString(converted, forType: .string)
            Typist.shortcut(KeyCode.v)
            self.reset()
            self.switchLayout(to: target)
            log.info("selection converted: \(converted.count) chars → \(target.id, privacy: .public)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Clipboard.restore(saved, to: pasteboard) }
        }
        if let knownText { return replace(knownText) }
        let before = pasteboard.changeCount
        Typist.shortcut(KeyCode.c)
        Clipboard.waitForChange(pasteboard, from: before, then: replace)
    }

    private func switchLayout(to layout: KeyLayout) {
        layout.select()
        currentLayoutID = layout.id
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
    /// The selected text in the focused field, read through Accessibility (Mail, Notes, Slack, most native apps).
    static func textViaAccessibility() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return nil }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success
        else { return nil }
        return selected as? String
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        fixer.reloadLayouts()
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                           object: nil, queue: .main) { _ in
            fixer.currentLayoutID = KeyLayout.currentLayoutID()
            self.refreshTitle()
        }
        center.addObserver(forName: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
                           object: nil, queue: .main) { _ in fixer.reloadLayouts() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in fixer.reset() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        rebuildMenu()
        startTap()
    }

    private var askedForAccess = false

    private func startTap() {
        // Ask macOS once per launch; the retries below only check, so the dialog doesn't keep coming back.
        if !askedForAccess {
            askedForAccess = true
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            if !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
            if !CGPreflightPostEventAccess() { CGRequestPostEventAccess() }
        }

        let trusted = AXIsProcessTrusted()
        let listen = CGPreflightListenEventAccess()
        log.info("access: accessibility=\(trusted) inputMonitoring=\(listen)")
        // A tap made before Accessibility is granted gets no key presses even after it is granted, so wait for it.
        // A tap that can change keys needs only Accessibility; Input Monitoring is for listen-only taps.
        guard trusted else {
            refreshTitle(warning: true)
            retryTap()
            return
        }
        let mask: CGEventMask = [CGEventType.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            .reduce(0) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: tapCallback, userInfo: nil)
        else {
            log.error("tapCreate failed although access is granted")
            refreshTitle(warning: true)
            retryTap()
            return
        }
        eventTap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log.info("listening for keys")
        refreshTitle()
    }

    private func retryTap() {
        tapRetry?.invalidate()
        tapRetry = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in self.startTap() }
    }

    private func refreshTitle(warning: Bool = false) {
        let short = fixer.currentLayoutID.flatMap { fixer.layouts.layout(id: $0) }?.language.uppercased() ?? "?"
        statusItem.button?.title = warning ? "⚠︎ \(short)" : (fixer.enabled ? short : "(\(short))")
        statusItem.button?.toolTip = warning ? "Layout Fixer needs Accessibility and Input Monitoring" : "Layout Fixer"
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(info("Tap right ⌥  fix the selection, or the last word"))
        menu.addItem(info("⌥Space   fix the last word"))
        menu.addItem(info("⌥⇧Space  fix the whole phrase, or the selection"))
        menu.addItem(info("Press again to flip it back"))
        menu.addItem(.separator())
        menu.addItem(toggle("Enabled", on: fixer.enabled, action: #selector(toggleEnabled)))
        menu.addItem(toggle("Fix automatically while typing (beta)", on: fixer.autoFix, action: #selector(toggleAuto)))
        menu.addItem(toggle("Open at login", on: SMAppService.mainApp.status == .enabled, action: #selector(toggleLogin)))
        menu.addItem(.separator())
        menu.addItem(item("Privacy settings…", action: #selector(openPrivacy)))
        menu.addItem(item("Quit Layout Fixer", action: #selector(quit), key: "q"))
        statusItem.menu = menu
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

    @objc private func toggleEnabled() { fixer.enabled.toggle(); fixer.reset(); rebuildMenu(); refreshTitle() }
    @objc private func toggleAuto() { fixer.autoFix.toggle(); rebuildMenu() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change Open at login"
            alert.informativeText = "\(error.localizedDescription)\nAdd Layout Fixer in System Settings > General > Login Items instead."
            alert.runModal()
        }
        rebuildMenu()
    }

    @objc private func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
