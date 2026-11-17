import Foundation

/// The typing side of Layout Fixer, apart from macOS: what was typed since the memory was last cleared, which layout
/// each key was on, and what to retype. The app feeds it key presses and carries out the edits it returns (erase,
/// type, switch the layout); the tests feed it the same presses from a simulated Mac and check the screen.
final class TypingSession {
    /// Erase `erase` characters before the cursor, type `text`, then switch the keyboard to `target`.
    struct Edit {
        let erase: Int
        let text: String
        let source: KeyLayout?
        let target: KeyLayout
        /// False when only words before the finished one changed: the keyboard stays on its layout.
        var switches = true
    }

    static let maxRemembered = 300
    /// Right after the app switches the layout itself, macOS can still report the old one for a moment.
    static let switchGraceSeconds: TimeInterval = 1
    static let spaceKey = KeyStroke(keyCode: 49, modifiers: 0)

    private(set) var layouts: LayoutSet
    private(set) var currentLayoutID: String?
    private(set) var buffer: [Typed] = []
    /// Fix the finished word on Space (the "Fix automatically while typing" setting).
    var autoFix = false
    /// What last cleared the memory, for the log when Space finds no word.
    private(set) var lastClear = "starting up"
    /// Called with a local layout (not English) whenever it becomes the one in use: English flips to it from then on.
    var onLocalLayoutUsed: ((String) -> Void)?

    private var switchedAt: Date?
    private var switchedFrom: String?
    private let speller: Speller
    private let now: () -> Date
    private let log: (String) -> Void

    init(layouts: LayoutSet, currentLayoutID: String?, speller: Speller = SystemSpeller(),
         now: @escaping () -> Date = Date.init, log: @escaping (String) -> Void = { _ in }) {
        self.layouts = layouts
        self.speller = speller
        self.now = now
        self.log = log
        layoutChanged(to: currentLayoutID)
    }

    func setLayouts(_ layouts: LayoutSet, current: String?) {
        self.layouts = layouts
        layoutChanged(to: current)
    }

    /// The layout changed (by the person, or by the app). A local layout becomes the one English flips to.
    func layoutChanged(to id: String?) {
        currentLayoutID = id
        guard let id, let layout = layouts.layout(id: id), layout.language != LayoutSet.englishLanguage else { return }
        layouts.preferredLocalID = id
        onLocalLayoutUsed?(id)
    }

    /// The app switched the layout itself (after converting a selection): later reports of the old one are late.
    func appSwitched(to id: String) {
        switchedFrom = currentLayoutID
        switchedAt = now()
        layoutChanged(to: id)
    }

    func reset(_ reason: String) {
        buffer.removeAll()
        lastClear = reason
    }

    func deleteBackward() {
        if !buffer.isEmpty { buffer.removeLast() }
    }

    var hasTypedWord: Bool { buffer.contains { !$0.isSpace } }

    /// A key that types (no ⌘ or ⌃; not Return, an arrow or ⌫). `reportedLayoutID` is the layout macOS says is on.
    /// `eventCharacters`, what macOS put in the key event, is only logged when it disagrees: on a real Mac it kept
    /// the old layout's character for whole words after the app's own switch ("key typed on Ukrainian-PC while the
    /// app had ABC"), so trusting it lost those words. Returns an edit when this Space finishes a word to fix: the
    /// app then swallows the Space, since the edit types it.
    func type(_ stroke: KeyStroke, eventCharacters: String?, reportedLayoutID: String?,
              screenBeforeCursor: ((Int) -> String?)? = nil) -> Edit? {
        guard let layout = typingLayout(reported: reportedLayoutID) else {
            reset("typing on a layout Layout Fixer doesn't use")
            return nil
        }
        guard let text = layout.character(for: stroke), text.count == 1 else {
            reset("a key that types no single character")
            return nil
        }
        if let eventText = eventCharacters, eventText != text, !loggedEventMismatch {
            loggedEventMismatch = true
            log("key event text is from another layout than \(layout.id) (ignored)")
        }
        if text == " " { loggedEventMismatch = false }
        if text == " " && autoFix {
            if settleLastWord(screenBeforeCursor) {
                if let edit = fixWordBeforeSpace() { return edit }
            } else {
                reset("the app changing the text")
            }
        }
        buffer.append(Typed(stroke: stroke, layoutID: layout.id, text: text))
        if buffer.count > TypingSession.maxRemembered { buffer.removeFirst(buffer.count - TypingSession.maxRemembered) }
        return nil
    }

    /// Right ⌥ with nothing selected: the last word typed, on the other layout (tap again to flip it back).
    func convertLastWord() -> Edit? {
        guard let range = Converter.lastWord(of: buffer),
              let typedOn = buffer[range].last(where: { !$0.isSpace })?.layoutID,
              let source = layouts.layout(id: typedOn), let target = layouts.other(than: typedOn)
        else { return nil }
        let fixed = Converter.retype(buffer[range], on: target)
        buffer.replaceSubrange(range, with: fixed)
        appSwitched(to: target.id)
        return Edit(erase: range.count, text: fixed.map(\.text).joined(), source: source, target: target)
    }

    // MARK: Private

    /// Logged once per word, so a stale key event shows in the log without filling it.
    private var loggedEventMismatch = false

    /// The layout this key was really typed on: the app's own record (its switches, macOS's notices), corrected by
    /// macOS's report, except a late report of the layout the app just switched away from.
    private func typingLayout(reported: String?) -> KeyLayout? {
        let justSwitched = switchedAt.map { now().timeIntervalSince($0) < TypingSession.switchGraceSeconds } ?? false
        if reported != currentLayoutID && !(justSwitched && reported == switchedFrom) {
            log("layout changed without a notice: \(currentLayoutID ?? "none") → \(reported ?? "none")")
            layoutChanged(to: reported)
        }
        return currentLayoutID.flatMap { layouts.layout(id: $0) }
    }

    /// Before deciding on the finished word, make the memory say what was really typed. The layout macOS reports
    /// (and the text in key events) can lag behind a switch, so a word may be recorded half on each layout. The
    /// screen settles it when the app shares the text before the cursor: the layout whose reading of the keys
    /// is what's shown. When neither is (an app closed a bracket, made a quote curly, autocorrected), the word is
    /// left alone: false. Without the screen, a word on two layouts goes by its last key, as a late report only
    /// gets the first keys wrong.
    private func settleLastWord(_ screenBeforeCursor: ((Int) -> String?)?) -> Bool {
        guard let range = AutoFix.wordRanges(in: buffer).last, range.upperBound == buffer.count else { return true }
        let word = buffer[range]
        if let shown = screenBeforeCursor?(word.count) {
            guard let layout = layouts.layouts.first(where: { Converter.retype(word, on: $0).map(\.text).joined() == shown })
            else {
                log("auto-fix skipped: the screen doesn't show the typed keys, the app changed the text (\(word.count) keys)")
                return false
            }
            settle(range, on: layout, by: "the screen")
            return true
        }
        if Set(word.map(\.layoutID)).count > 1, let id = word.last?.layoutID, let layout = layouts.layout(id: id) {
            settle(range, on: layout, by: "its last key")
        }
        return true
    }

    private func settle(_ range: Range<Int>, on layout: KeyLayout, by reason: String) {
        guard buffer[range].contains(where: { $0.layoutID != layout.id }) else { return }
        buffer.replaceSubrange(range, with: Converter.retype(buffer[range], on: layout))
        log("word of \(range.count) keys was really typed on \(layout.id) (by \(reason))")
        if currentLayoutID != layout.id { layoutChanged(to: layout.id) }
    }

    /// Fix-while-typing: on Space, the word just finished (and the words before it on the same wrong layout).
    private func fixWordBeforeSpace() -> Edit? {
        let decision = AutoFix.decide(buffer: buffer, layouts: layouts, speller: speller)
        if case .fixShortWords(let range, let target) = decision { return fixShortWords(range, on: target) }
        guard case .fix(let range, let target) = decision else {
            if case .skip(let reason) = decision { logSkip(reason) }
            return nil
        }
        let source = buffer.last.flatMap { layouts.layout(id: $0.layoutID) }
        let fixed = Converter.retype(buffer[range], on: target)
        log("auto-fix: \(AutoFix.wordRanges(in: Array(buffer[range])).count) words")
        buffer.replaceSubrange(range, with: fixed)
        buffer.append(Typed(stroke: TypingSession.spaceKey, layoutID: target.id, text: " "))
        appSwitched(to: target.id)
        return Edit(erase: range.count, text: fixed.map(\.text).joined() + " ", source: source, target: target)
    }

    /// The short words before the finished word go to `target`; the finished word and the layout stay.
    private func fixShortWords(_ range: Range<Int>, on target: KeyLayout) -> Edit? {
        guard let current = currentLayoutID.flatMap({ layouts.layout(id: $0) }) else { return nil }
        let source = buffer[range].first.flatMap { layouts.layout(id: $0.layoutID) }
        let fixed = Converter.retype(buffer[range], on: target)
        let tail = buffer[range.upperBound...]
        let erase = buffer.count - range.lowerBound
        log("auto-fix: \(AutoFix.wordRanges(in: Array(buffer[range])).count) short words before the last one")
        buffer.replaceSubrange(range, with: fixed)
        buffer.append(Typed(stroke: TypingSession.spaceKey, layoutID: current.id, text: " "))
        let text = fixed.map(\.text).joined() + tail.map(\.text).joined() + " "
        return Edit(erase: erase, text: text, source: source, target: target, switches: false)
    }

    /// Why the word before this Space stays as typed: lengths and layouts only, never the text.
    private func logSkip(_ reason: AutoFix.Skip) {
        let detail: String
        if reason == .noWord {
            detail = "memory last cleared by \(lastClear)"
        } else {
            let word = AutoFix.wordRanges(in: buffer).last.map { buffer[$0] }
            detail = "\(word?.count ?? 0) keys on \(word?.first?.layoutID ?? "?")"
        }
        log("auto-fix skipped: \(reason.rawValue) (\(detail))")
    }
}
