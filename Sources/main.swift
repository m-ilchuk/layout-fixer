import AppKit
import Carbon
import ServiceManagement
import os

// Diagnostics only: counts and lengths, never what was typed. At "notice" level, which macOS keeps on disk, so
// Export Debug Log… has the whole day (info-level messages are kept only briefly, in memory).
// Read with: log stream --predicate 'subsystem == "io.github.m-ilchuk.layoutfixer"'
let log = Logger(subsystem: "io.github.m-ilchuk.layoutfixer", category: "fixer")

// Events this app posts carry this marker so its own tap lets them through untouched.
let syntheticMarker: Int64 = 0x4C46_4958  // "LFIX"
/// After each synthetic key (down and up). usleep runs over: 2500 asked is about 3.7 ms. At about 2.3 ms a key an
/// app (TextEdit, in the end-to-end test) dropped some backspaces; 4000 (6 ms really) after each of down and up
/// made a word vanish for over 150 ms while it was retyped in apps that take keystrokes only (the "blink").
let keyDelayMicroseconds: useconds_t = 2500
/// After the backspaces and before typing the replacement.
let pauseAfterEraseMicroseconds: useconds_t = 10_000
/// `defaults write io.github.m-ilchuk.layoutfixer testKeystrokesOnly -bool true`: every fix goes as keystrokes,
/// even where Accessibility could replace it in one step, so the end-to-end test (`./e2e.sh keystrokes`) checks
/// the keystroke path in TextEdit.
let keystrokesOnlyKey = "testKeystrokesOnly"
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
    /// The typing itself (memory, layouts, fix-while-typing), apart from macOS so tests can drive it.
    let session = TypingSession(layouts: LayoutSet(layouts: []), currentLayoutID: nil,
                                log: { message in log.notice("\(message, privacy: .public)") })
    /// Right ⌥ was tapped: convert the selection once the key is up.
    var pending = false
    private var lastConversion = LastConversion()
    /// A selection is being copied, converted and pasted (about half a second); taps meanwhile are ignored,
    /// or two pastes land on top of each other and the text doubles.
    private var convertingSelection = false
    var enabled = true
    var autoFix: Bool {
        get { session.autoFix }
        set { session.autoFix = newValue; UserDefaults.standard.set(newValue, forKey: "autoFix") }
    }
    var layouts: LayoutSet { session.layouts }
    var currentLayoutID: String? { session.currentLayoutID }
    /// Words changed per day (the window's Statistics): counts only, never text.
    private(set) var statistics = Statistics.load(from: .standard, now: Date())
    /// Words fix-while-typing leaves as typed (the window's Exclusions): the person's words, kept only in the
    /// app's preferences.
    private(set) var exclusions = Exclusions.load(from: .standard, now: Date(),
                                                  log: { message in log.notice("\(message, privacy: .public)") })

    init() {
        session.autoFix = UserDefaults.standard.bool(forKey: "autoFix")
        session.onLocalLayoutUsed = { UserDefaults.standard.set($0, forKey: "preferredLocal") }
        session.logDetail = { message in log.info("\(message, privacy: .public)") }
        session.onEvent = { [unowned self] event in
            switch event {
            case .autoFixed(let words): self.count(.autoFixed, words: words)
            case .converted(let words): self.count(.converted, words: words)
            case .undone(let typed, _): self.count(.undone, words: typed.count)
            case .restored(let typed, _): self.count(.undone, words: -typed.count)
            }
            self.learn(from: event)
        }
        session.isExcluded = { [unowned self] word, language in self.exclusions.contains(word, language: language) }
        // Saved again at once: what 0.3.0 wrote also held words still being counted, and a copy it kept aside.
        exclusions.save(to: .standard)
        UserDefaults.standard.removeObject(forKey: Exclusions.defaultsKey + ".unreadable")
        // Counting starts at the first launch of a version that counts, not at each launch.
        if UserDefaults.standard.data(forKey: Statistics.defaultsKey) == nil { statistics.save(to: .standard) }
    }

    func resetStatistics() {
        statistics.reset(now: Date())
        saveStatistics()
    }

    /// An undone fix teaches: the 3rd undo of the same word puts it on the list.
    private func learn(from event: TypingSession.Event) {
        switch event {
        case .undone, .restored: break
        case .autoFixed, .converted: return
        }
        let before = exclusions.excluded
        let learned = exclusions.learn(from: event, layouts: layouts, at: Date())
        if exclusions.excluded != before { exclusions.save(to: .standard) }  // counted words are never saved
        guard let word = learned else { return }
        log.notice("a word whose fix was undone 3 times is now on the exclusions list")
        Flash.shared.say("\(word): won't fix again", after: Flash.visibleSeconds)
    }

    /// Words still being counted, turned on now from the window.
    func turnOnExclusions(_ entries: [Exclusions.Entry]) {
        for entry in entries { exclusions.turnOn(entry.word, language: entry.language, at: Date()) }
        exclusions.save(to: .standard)
    }

    func removeExclusions(_ entries: [Exclusions.Entry]) {
        for entry in entries { exclusions.remove(entry.word, language: entry.language) }
        exclusions.save(to: .standard)
    }

    /// Adds a word the person typed in the window. Returns why it can't be added, or nil.
    func addExclusion(_ text: String) -> String? {
        let word = text.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return "Type the word as you type it, for example csv." }
        guard !word.contains(where: \.isWhitespace) else { return "Add one word at a time." }
        guard let language = Converter.typedLayout(of: word, layouts: layouts, currentID: currentLayoutID)?.language
        else { return "None of your keyboard layouts types \(word)." }
        exclusions.add(word, language: language, at: Date())
        exclusions.save(to: .standard)
        return nil
    }

    /// Counts are saved a moment after the last change, not inside the key tap at every fix.
    static let statisticsSaveDelay: TimeInterval = 2
    private var statisticsSave: DispatchWorkItem?

    private func count(_ kind: Statistics.Kind, words: Int) {
        statistics.record(kind, words: words, at: Date())
        guard statisticsSave == nil else { return }
        let save = DispatchWorkItem { [unowned self] in self.saveStatistics() }
        statisticsSave = save
        DispatchQueue.main.asyncAfter(deadline: .now() + Fixer.statisticsSaveDelay, execute: save)
    }

    /// Now (on quit), or when the delay is up.
    func saveStatistics() {
        statisticsSave?.cancel()
        statisticsSave = nil
        statistics.save(to: .standard)
    }

    func reloadLayouts() {
        SystemSpeller.forget()
        session.setLayouts(LayoutSet(layouts: KeyLayout.enabledLayouts(),
                                     preferredLocalID: UserDefaults.standard.string(forKey: "preferredLocal")),
                           current: KeyLayout.currentLayoutID())
    }

    /// macOS says the layout changed.
    func layoutChanged() { session.layoutChanged(to: KeyLayout.currentLayoutID()) }

    func reset(_ reason: String) {
        session.reset(reason)
        passwordField = nil  // a click, Tab or another app: the field may be another one
    }

    /// Whether the focused field takes a password, asked once per field (until a click, Tab, Return or another
    /// app), not at every Space.
    private var passwordField: Bool?

    private func inPasswordField() -> Bool {
        if let known = passwordField, !IsSecureEventInputEnabled() { return known }
        let now = Selection.inPasswordField()
        if !Selection.leftAlone { passwordField = now }  // "can't ask" isn't an answer to keep
        return now
    }

    // MARK: Event tap

    /// Returns false when the event must be swallowed.
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        guard enabled, event.getIntegerValueField(.eventSourceUserData) != syntheticMarker else { return true }
        // A fix is being typed: keys wait until it's done (handled then, in order), or they'd land inside it.
        // Modifier keys go through at once: held back, a VM or remote desktop would see them stuck.
        if held.replaying, type == .keyDown, let copy = event.copy(), held.hold(HeldKey(event: copy)) {
            return false
        }
        return handleNow(type: type, event: event)
    }

    /// `held`: a key pressed while a fix was being typed, handled after it. The app hasn't received the keys
    /// handed over just before it yet, so the screen can't be read to check the word.
    private func handleNow(type: CGEventType, event: CGEvent, held: Bool = false) -> Bool {
        switch type {
        case .keyDown:
            return handleKeyDown(event, held: held)
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
            cancelFix("a click")  // the rest of a fix must not go where the click put the cursor
            reset("a click")  // a click moves the caret
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
            log.notice("hotkey: right option tap")
            pending = true
        } else {
            rightOptionDownAt = nil
        }
    }

    private var loggedFirstKey = false

    private func handleKeyDown(_ event: CGEvent, held: Bool = false) -> Bool {
        if !loggedFirstKey { loggedFirstKey = true; log.notice("receiving key presses") }
        rightOptionDownAt = nil
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let command = flags.contains(.maskCommand) || flags.contains(.maskControl)
        if command {
            session.shortcut(KeyStroke(keyCode: keyCode, modifiers: carbonModifiers(flags)),
                             command: flags.contains(.maskCommand), control: flags.contains(.maskControl))
            return true
        }
        if KeyCode.resetting.contains(keyCode) {
            reset("Return, Tab, Esc or an arrow key")
            return true
        }
        // A password: nothing typed there is kept or fixed (most password fields hide their keys from every app,
        // but not all do).
        if keyCode == KeyCode.space && session.autoFix && inPasswordField() {
            reset("a password field")
            return true
        }
        if keyCode == KeyCode.delete {
            if flags.contains(.maskAlternate) { session.deleteWordBackward() } else { session.deleteBackward() }
            return true
        }
        let stroke = KeyStroke(keyCode: keyCode, modifiers: carbonModifiers(flags))
        guard let edit = session.type(stroke, eventCharacters: Self.characters(of: event),
                                      reportedLayoutID: KeyLayout.currentLayoutID(),
                                      screenBeforeCursor: held ? nil : Selection.textBeforeCursor)
        else { return true }
        apply(edit)
        return false  // the edit types the Space
    }

    // MARK: Typing a fix, away from the key tap

    /// A key pressed while a fix was being typed.
    private struct HeldKey {
        let event: CGEvent
    }
    private let held = HeldKeys<HeldKey>()
    /// Fixes are typed here, not in the key tap: a long one (keystrokes, about 8 ms a character) would hold up
    /// every key on the Mac and could get the tap turned off.
    private let replayQueue = DispatchQueue(label: "io.github.m-ilchuk.layoutfixer.replay", qos: .userInteractive)
    private var replayNumber = 0
    /// The fix being typed: set to stop it (a click, another app, too long), checked before every key and
    /// Accessibility write.
    private var replayCancel: Flag?
    /// A fix may take this long, plus `replaySecondsPerKey` for each key it types; past that it's stopped and the
    /// held keys go: typing must never stay blocked. Keystrokes take about 16 ms a key with the app's pauses.
    static let replayBaseSeconds: TimeInterval = 2
    static let replaySecondsPerKey: TimeInterval = 0.02

    /// Runs `work` (typing `keys` keys into the app) away from the tap while keys are held, then `done` on the main
    /// thread, then the held keys.
    private func replay(keys: Int, _ work: @escaping (Flag) -> Void, then done: @escaping () -> Void = {}) {
        replayNumber += 1
        let number = replayNumber
        let cancel = Flag()
        replayCancel = cancel
        let limit = Fixer.replayBaseSeconds + Double(keys) * Fixer.replaySecondsPerKey
        held.begin()
        replayQueue.async {
            if !cancel.isSet { work(cancel) }
            DispatchQueue.main.async {
                // A stopped fix doesn't switch the layout or flash: what it typed is unknown.
                if !cancel.isSet { done() }
                self.endReplay(number)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + limit) {
            guard number == self.replayNumber, self.held.replaying else { return }
            log.notice("a fix of \(keys) keys took over \(limit, privacy: .public) s")
            self.cancelFix("a fix taking too long")
        }
    }

    /// Stops the fix being typed, if any, and lets the held keys go: its remaining keys and Accessibility writes
    /// are dropped, so nothing lands where the cursor went next.
    func cancelFix(_ reason: String) {
        guard held.replaying, let cancel = replayCancel else { return }
        cancel.set(true)
        log.notice("stopped the fix being typed: \(reason, privacy: .public)")
        reset(reason)
        endReplay(replayNumber)
    }

    private func endReplay(_ number: Int) {
        guard number == replayNumber, held.replaying else { return }
        if held.count > 0 { log.notice("\(self.held.count) keys pressed during a fix, handled now") }
        held.end { key in
            guard handleNow(type: .keyDown, event: key.event, held: true) else { return }
            Typist.repost(key.event)
        }
    }

    /// Carry out a session edit: erase, type, switch the keyboard, flash.
    /// Through Accessibility when the app allows it (one step, nothing to drop), else as keystrokes.
    private func apply(_ edit: TypingSession.Edit) {
        replay(keys: edit.erase + edit.text.count, { cancel in Fixer.replace(edit, cancel: cancel) }, then: {
            if edit.switches { edit.target.select() }
            Flash.shared.show(from: edit.source, to: edit.target, layoutSwitched: edit.switches)
        })
    }

    private static func replace(_ edit: TypingSession.Edit, cancel: Flag) {
        switch Selection.replaceBeforeCursor(edit.erase, with: edit.text, cancel: cancel) {
        case .replaced:
            log.notice("replaced \(edit.erase) characters through accessibility")
        case .unverified:
            log.notice("replaced \(edit.erase) characters through accessibility, but couldn't read the result back")
        case .notPossible:
            Typist.erase(count: edit.erase, cancel: cancel)
            usleep(pauseAfterEraseMicroseconds)
            Typist.type(edit.text, cancel: cancel)
            log.notice("replaced \(edit.erase) characters with keystrokes")
        }
    }

    /// The text macOS put in a key event, when it put any.
    private static func characters(of event: CGEvent) -> String? {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }

    private func carbonModifiers(_ flags: CGEventFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.maskShift) { modifiers |= KeyStroke.shift }
        if flags.contains(.maskAlphaShift) { modifiers |= KeyStroke.capsLock }
        if flags.contains(.maskAlternate) { modifiers |= KeyStroke.option }
        return modifiers
    }

    // MARK: Right ⌥

    /// Right ⌥: the selected text, or with nothing selected the last word typed, goes to the other layout.
    /// Another tap converts it back.
    private func convertSelection() {
        guard !convertingSelection else {
            log.notice("tap ignored: the last conversion is still pasting")
            return
        }
        let selection = Selection.current()
        if let selection, !selection.text.isEmpty {
            log.notice("selection via accessibility: \(selection.text.count) chars")
            return fixSelection(selection)
        }
        if session.hasTypedWord {
            guard !inPasswordField() else {
                reset("a password field")
                return NSSound.beep()
            }
            log.notice("no selection; converting the last word")
            guard let edit = session.convertLastWord() else { return NSSound.beep() }
            return apply(edit)
        }
        guard selection == nil else {
            log.notice("nothing selected, nothing typed")
            return NSSound.beep()
        }
        log.notice("the app doesn't share its selection; copying it")
        fixSelection(nil)
    }

    /// Convert the selected text, paste it over the selection, select it again, switch the layout and restore
    /// the clipboard. Apps that don't share the selection through Accessibility (some browsers) get it copied with ⌘C.
    private func fixSelection(_ selection: Selection.Current?) {
        convertingSelection = true
        let pasteboard = NSPasteboard.general
        let saved = Clipboard.save(pasteboard)
        let replace: (String?) -> Void = { [weak self] text in
            guard let self else { return }
            guard let text, let (converted, target, restores) = self.conversion(of: text) else {
                log.notice("nothing to convert (copied: \(text?.count ?? -1) chars)")
                Clipboard.restore(saved, to: pasteboard)
                self.convertingSelection = false
                NSSound.beep()
                return
            }
            let source = self.layouts.other(than: target.id)
            if !restores { self.count(.converted, words: converted.split(whereSeparator: \.isWhitespace).count) }
            self.lastConversion.remember(original: text, output: converted, originalLayoutID: source?.id)
            Clipboard.putTransient(converted, on: pasteboard)
            let ours = pasteboard.changeCount
            Typist.shortcut(KeyCode.v)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.replay(keys: converted.count) { cancel in Selection.reselect(converted, after: selection, cancel: cancel) }
            }
            self.reset("converting a selection")
            target.select()
            self.session.appSwitched(to: target.id)
            Flash.shared.show(from: source, to: target, layoutSwitched: true)
            log.notice("selection converted: \(converted.count) chars → \(target.id, privacy: .public)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                // Something copied meanwhile (by you, or another app) stays: only our own text is taken back.
                if pasteboard.changeCount == ours {
                    Clipboard.restore(saved, to: pasteboard)
                } else {
                    log.notice("the clipboard changed during a conversion; left as it is")
                }
                self.convertingSelection = false
            }
        }
        if let selection { return replace(selection.text) }
        let before = pasteboard.changeCount
        Typist.shortcut(KeyCode.c)
        Clipboard.waitForChange(pasteboard, from: before, then: replace)
    }

    /// The text on the other layout. Tapping again on what the last tap produced puts back exactly what was there
    /// (`restores`: not counted as a conversion).
    private func conversion(of text: String) -> (text: String, target: KeyLayout, restores: Bool)? {
        if let back = lastConversion.undo(of: text), let id = back.layoutID, let layout = layouts.layout(id: id) {
            return (back.text, layout, true)
        }
        return Converter.convert(text: text, layouts: layouts, currentID: currentLayoutID).map { ($0.text, $0.target, false) }
    }
}

/// An app being left alone for a while, shared between the main thread and the replay queue.
final class Backoff {
    private let lock = NSLock()
    private var app: pid_t?
    private var until = Date.distantPast
    func isOn(for pid: pid_t?) -> Bool { lock.withLock { pid != nil && pid == app && until > Date() } }
    func start(_ pid: pid_t, for seconds: TimeInterval) {
        lock.withLock { (app, until) = (pid, Date().addingTimeInterval(seconds)) }
    }
    func end() { lock.withLock { app = nil } }
}

/// A yes/no shared between the main thread and the replay queue.
final class Flag {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set(_ on: Bool) { lock.withLock { value = on } }
}

/// Posts keystrokes marked as ours.
enum Typist {

    private static let source: CGEventSource? = {
        let source = CGEventSource(stateID: .privateState)
        source?.userData = syntheticMarker
        return source
    }()

    /// `cancel`, once set, drops the keys not yet sent.
    static func erase(count: Int, cancel: Flag) {
        for _ in 0..<count where !cancel.isSet { press(KeyCode.delete, flags: []) }
    }

    static func type(_ text: String, cancel: Flag) {
        for char in text where !cancel.isSet {
            let units = Array(String(char).utf16)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                post(event, pause: !down)  // one pause a key, after it's released
            }
        }
    }

    /// Between keys handed over after a fix (they go from the main thread, so kept short).
    static let repostDelayMicroseconds: useconds_t = 1000

    /// A key pressed while a fix was typed, sent now. From the keyboard: rebuilt from the key and its modifiers,
    /// so the app reads it on the layout that's on now (the person typed on after the fix, in its language).
    /// From another program (a text expander, auto-type: its own text, often on key 0): sent as it was.
    static func repost(_ event: CGEvent) {
        let fromKeyboard = event.getIntegerValueField(.eventSourceStateID) == Int64(CGEventSourceStateID.hidSystemState.rawValue)
        guard fromKeyboard else {
            event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            event.post(tap: .cghidEventTap)
            usleep(repostDelayMicroseconds)
            return
        }
        let flags = event.flags.intersection([.maskShift, .maskAlphaShift, .maskAlternate, .maskCommand, .maskControl])
        press(UInt16(event.getIntegerValueField(.keyboardEventKeycode)), flags: flags, pause: false)
        usleep(repostDelayMicroseconds)
    }

    static func shortcut(_ keyCode: UInt16) {
        press(keyCode, flags: .maskCommand)
    }

    /// ⇧← `count` times: selects that many characters before the cursor.
    static func selectBackward(count: Int, cancel: Flag) {
        for _ in 0..<count where !cancel.isSet { press(KeyCode.leftArrow, flags: .maskShift) }
    }

    private static func press(_ keyCode: UInt16, flags: CGEventFlags, pause: Bool = true) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            event.flags = flags
            post(event, pause: pause && !down)
        }
    }

    private static func post(_ event: CGEvent, pause: Bool = true) {
        event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        event.post(tap: .cghidEventTap)
        if pause { usleep(keyDelayMicroseconds) }
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
    static func reselect(_ pasted: String, after selection: Current?, cancel: Flag) {
        if let selection, let start = selection.range {
            var range = CFRange(location: start.location, length: (pasted as NSString).length)
            if let value = AXValueCreate(.cfRange, &range),
               AXUIElementSetAttributeValue(selection.element, kAXSelectedTextRangeAttribute as CFString, value) == .success {
                return
            }
        }
        guard pasted.count <= maxReselectByArrows else { return }
        Typist.selectBackward(count: pasted.count, cancel: cancel)
    }

    enum Replacement { case replaced, unverified, notPossible }

    /// Deep enough for a field inside a web page (a browser nests dozens of groups).
    static let maximumAncestors = 60
    static let cursorBackChecks = 10
    static let cursorBackPauseMicroseconds: useconds_t = 10_000

    /// Replace the `count` characters before the cursor with `text` through Accessibility, in one step: no
    /// keystrokes an app can drop. `.notPossible` when the app doesn't allow it and nothing changed (send
    /// keystrokes instead); `.unverified` when it took the text but it can't be read back (don't type it again).
    static func replaceBeforeCursor(_ count: Int, with text: String, cancel: Flag) -> Replacement {
        guard count > 0, let element = focusedElement(), let cursor = selectedRange(in: element),
              cursor.length == 0, cursor.location >= count
        else { return .notPossible }
        if UserDefaults.standard.bool(forKey: keystrokesOnlyKey) {
            log.notice("keystrokes for this field: the keystrokes-only test setting is on")
            return .notPossible
        }
        let roles = rolesUpToWindow(from: element)
        guard ReplaceMethod.forField(roles: roles) == .accessibility else {
            log.notice("keystrokes for this field: \(roles.isEmpty ? "no roles" : "inside a web page", privacy: .public)")
            return .notPossible
        }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue
        else { return .notPossible }
        var word = CFRange(location: cursor.location - count, length: count)
        guard !cancel.isSet, let range = AXValueCreate(.cfRange, &word),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, range) == .success
        else { return .notPossible }
        guard !cancel.isSet,
              AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
        else {
            // Put the cursor back where it was, so the keystrokes that follow go to the right place.
            var back = cursor
            if let value = AXValueCreate(.cfRange, &back) {
                AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
            }
            // Backspaces on a selection would erase it and more: wait until the app shows the cursor back.
            for _ in 0..<cursorBackChecks {
                if let now = selectedRange(in: element), now.location == cursor.location, now.length == 0 { break }
                usleep(cursorBackPauseMicroseconds)
            }
            return .notPossible
        }
        return textBeforeCursor((text as NSString).length) == text ? .replaced : .unverified
    }

    /// The `length` characters before the cursor in the focused field, when the app shares its text (most native
    /// apps do; some browsers and Electron apps don't). Nil when it can't tell, or when text is selected.
    static func textBeforeCursor(_ length: Int) -> String? {
        guard length > 0, let element = focusedElement(), let range = selectedRange(in: element),
              range.length == 0, range.location >= length
        else { return nil }
        var before = CFRange(location: range.location - length, length: length)
        guard let value = AXValueCreate(.cfRange, &before) else { return nil }
        var text: CFTypeRef?
        guard asking({ AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString, value, &text) }) == .success
        else { return nil }
        return text as? String
    }

    private static func selectedRange(in element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard asking({ AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) }) == .success,
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

    /// The Accessibility roles from `element` up to its window ("AXTextArea", …, "AXWebArea", …, "AXWindow").
    private static func rolesUpToWindow(from element: AXUIElement) -> [String] {
        var roles: [String] = []
        var current: AXUIElement? = element
        while let node = current, roles.count < maximumAncestors {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &role)
            guard let name = role as? String else { break }
            roles.append(name)
            // A web page's field is decided by the page itself: nothing above it can change the answer.
            if name == kAXWindowRole as String || name == ReplaceMethod.webAreaRole { break }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID()
            else { break }
            current = (parent as! AXUIElement)
        }
        return roles
    }

    /// The focused field is a password field, or macOS is in secure input (a password is being typed somewhere).
    /// While the front app is left alone it can't be asked: then it counts as one, so nothing is kept or fixed.
    static func inPasswordField() -> Bool {
        if IsSecureEventInputEnabled() || leftAlone { return true }
        guard let element = focusedElement() else { return false }
        var subrole: CFTypeRef?
        _ = asking { AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) }
        return (subrole as? String) == kAXSecureTextFieldSubrole as String
    }

    /// How long an Accessibility call may wait for an app (macOS's default is 6 s). The calls run while a key
    /// waits, so an app that doesn't answer must not hold up typing everywhere.
    static let messagingTimeoutSeconds: Float = 0.25

    /// Set once at launch: on the system-wide element it applies to every app.
    static func limitWaiting() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeoutSeconds)
    }

    /// After an app doesn't answer in time, that app is left alone for a few seconds (fixes go as keystrokes, the
    /// screen isn't read): asking again at every key would stall each one by the timeout. Other apps, and the
    /// same app once you switch back to it, are asked as usual.
    static let unresponsiveBackoffSeconds: TimeInterval = 5
    /// A call that failed this fast was refused, not left waiting: no reason to leave the app alone.
    static let waitedSeconds: TimeInterval = 0.2
    private static let unresponsive = Backoff()

    /// The front app, which is the one Accessibility asks about the focused field.
    private static var frontApp: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    /// The front app is being left alone (it didn't answer Accessibility in time a moment ago).
    static var leftAlone: Bool { unresponsive.isOn(for: frontApp) }

    /// Another app is in front: whatever made the last one slow doesn't apply.
    static func appSwitched() { unresponsive.end() }

    /// An Accessibility call, timed: one that waited out the timeout leaves the front app alone for a while.
    private static func asking(_ call: () -> AXError) -> AXError {
        let started = Date()
        let result = call()
        if result == .cannotComplete, Date().timeIntervalSince(started) >= waitedSeconds, let app = frontApp {
            log.notice("the front app didn't answer Accessibility in time; leaving it alone for a few seconds")
            unresponsive.start(app, for: unresponsiveBackoffSeconds)
        }
        return result
    }

    private static func focusedElement() -> AXUIElement? {
        guard !leftAlone else { return nil }
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let result = asking { AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) }
        guard result == .success, let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return nil }
        return (element as! AXUIElement)
    }
}

enum Clipboard {
    typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]
    /// Markers clipboard managers honour (nspasteboard.org): don't keep this in the history, it may be private.
    static let transientTypes = [NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
                                 NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")]

    /// The converted text, for the moment it takes to paste it: marked so clipboard managers don't record it.
    static func putTransient(_ text: String, on pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        for type in transientTypes { item.setData(Data(), forType: type) }
        pasteboard.writeObjects([item])
    }

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
            // What was already there, put back: not a new copy for a clipboard manager's history.
            item.setData(Data(), forType: transientTypes[0])
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
        // Keys typed while the tap was off were never seen: what's remembered no longer matches the screen.
        log.notice("key tap was turned off by macOS (\(type == .tapDisabledByTimeout ? "too slow" : "user input", privacy: .public)); turning it back on")
        fixer.reset("macOS turning the key tap off")
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    return fixer.handle(type: type, event: event) ? Unmanaged.passUnretained(event) : nil
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let layoutReloadDelay: TimeInterval = 0.3
    private var layoutReload: DispatchWorkItem?
    private var statusItem: NSStatusItem!
    private var tapRetry: Timer?
    private var waitingForAccess = false
    /// macOS already shows the layout (its "A" / "УК" menu); this icon is only for settings, so it can go.
    private var hideIcon = UserDefaults.standard.bool(forKey: "hideIcon") {
        didSet { UserDefaults.standard.set(hideIcon, forKey: "hideIcon"); refreshIcon() }
    }
    private let updater = Updater()
    private lazy var settingsWindow = SettingsWindow(settings: settings, status: { [unowned self] in self.status() },
                                                     update: { [unowned self] in self.updateFromWindow() },
                                                     exportLog: { [unowned self] in self.exportDebugLog() },
                                                     statistics: { fixer.statistics.summary(now: Date()) },
                                                     resetStatistics: { fixer.resetStatistics() },
                                                     exclusions: ExclusionsPage.Model(
                                                        list: { fixer.exclusions.listed },
                                                        otherReading: { Exclusions.otherReading(of: $0, layouts: fixer.layouts) },
                                                        remove: { fixer.removeExclusions($0) },
                                                        turnOn: { fixer.turnOnExclusions($0) },
                                                        add: { fixer.addExclusion($0) }))

    /// Every on/off setting, in the order the window shows them (the quick menu has only Enabled).
    private lazy var settings: [Setting] = [
        Setting(title: AppDelegate.enabledSettingTitle, isOn: { fixer.enabled }, set: { [unowned self] on in
            fixer.enabled = on
            fixer.reset("turning Enabled \(on ? "on" : "off")")
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
        Selection.limitWaiting()
        fixer.reloadLayouts()
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                           object: nil, queue: .main) { _ in
            fixer.layoutChanged()
            self.changed()
        }
        // Any app can post this notice: a burst of them rebuilds the layouts once, not each time.
        center.addObserver(forName: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
                           object: nil, queue: .main) { _ in
            self.layoutReload?.cancel()
            let reload = DispatchWorkItem { fixer.reloadLayouts(); self.changed() }
            self.layoutReload = reload
            DispatchQueue.main.asyncAfter(deadline: .now() + AppDelegate.layoutReloadDelay, execute: reload)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            fixer.cancelFix("switching apps")
            Selection.appSwitched()
            SystemSpeller.forget()  // the words asked about stay in memory no longer than what was typed
            fixer.reset("switching apps")
        }

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

    /// `--settings-snapshot file.png --progress 0.42`: draw the window as it looks while an update installs.
    var snapshotProgress: UpdateProgress.State?

    /// `--page statistics`: draw that page instead of General.
    var snapshotPage = 0

    func settingsSnapshot(to url: URL) throws {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        settingsWindow.showSampleExclusions()
        settingsWindow.select(page: snapshotPage)
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
                              updateTitle: update.0, updateEnabled: update.1,
                              progress: snapshotProgress ?? updater.progress)
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
        // Checked every 3 s while not allowed: logged when it changes, not each time.
        if loggedAccess?.trusted != trusted || loggedAccess?.listen != listen {
            loggedAccess = (trusted, listen)
            log.notice("access: accessibility=\(trusted) inputMonitoring=\(listen)")
        }
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
        log.notice("listening for keys")
        refreshIcon()
        settingsWindow.refresh()
    }

    private var loggedAccess: (trusted: Bool, listen: Bool)?

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
        menu.addItem(item("Export Debug Log…", action: #selector(exportDebugLog)))
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

    /// What the debug log file starts with: version, Mac, layouts and settings (no typed text).
    @objc private func exportDebugLog() {
        let now = status()
        let settingsLine = settings.map { "\($0.title): \($0.isOn() ? "on" : "off")" }.joined(separator: ", ")
        let summary = """
            Version: \(now.version)
            macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
            Accessibility: \(now.accessAllowed ? "allowed" : "not allowed")
            \(Setup.summary(fixer.layouts, speller: SystemSpeller()).joined(separator: "\n"))
            Settings: \(settingsLine)
            """
        DebugLog.export(summary: summary)
    }

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
        alert.informativeText = "It builds on this Mac and restarts by itself, keeping its Accessibility permission. "
            + "The Layout Fixer window shows how far it is."
        if !release.notes.isEmpty { alert.accessoryView = ReleaseNotesView.make(release.notes) }
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        updater.install()
        settingsWindow.show()
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

    func applicationWillTerminate(_ notification: Notification) { fixer.saveStatistics() }
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
    if let index = CommandLine.arguments.firstIndex(of: "--progress"), index + 1 < CommandLine.arguments.count,
       let fraction = Double(CommandLine.arguments[index + 1]) {
        delegate.snapshotProgress = UpdateProgress.State(fraction: fraction, step: "Compiling for Apple silicon and Intel…")
    }
    if let index = CommandLine.arguments.firstIndex(of: "--page"), index + 1 < CommandLine.arguments.count,
       let page = ["general", "statistics", "exclusions"].firstIndex(of: CommandLine.arguments[index + 1]) {
        delegate.snapshotPage = page
    }
    do { try delegate.settingsSnapshot(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1])) } catch {
        print("could not write the snapshot: \(error.localizedDescription)")
        exit(1)
    }
    exit(0)
}
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
