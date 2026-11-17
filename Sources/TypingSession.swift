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

    /// A key that types (no ⌘ or ⌃; not Return, an arrow or ⌫). `eventCharacters` is what macOS put in the key
    /// event, `reportedLayoutID` the layout macOS says is on. Returns an edit when this Space finishes a word to fix:
    /// the app then swallows the Space, since the edit types it.
    func type(_ stroke: KeyStroke, eventCharacters: String?, reportedLayoutID: String?) -> Edit? {
        guard let layout = typingLayout(stroke, eventCharacters: eventCharacters, reported: reportedLayoutID) else {
            reset("typing on a layout Layout Fixer doesn't use")
            return nil
        }
        guard let text = layout.character(for: stroke), text.count == 1 else {
            reset("a key that types no single character")
            return nil
        }
        if text == " " && autoFix, let edit = fixWordBeforeSpace() { return edit }
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

    /// The layout this key was really typed on. The character macOS put in the event settles it; without one,
    /// macOS's report, except a late report of the layout the app just switched away from.
    private func typingLayout(_ stroke: KeyStroke, eventCharacters: String?, reported: String?) -> KeyLayout? {
        if let typed = eventCharacters {
            let matching = layouts.layouts.filter { $0.character(for: stroke) == typed }
            if let current = matching.first(where: { $0.id == currentLayoutID }) { return current }
            if let actual = matching.first {
                log("key typed on \(actual.id) while the app had \(currentLayoutID ?? "none")")
                layoutChanged(to: actual.id)
                return actual
            }
        }
        let justSwitched = switchedAt.map { now().timeIntervalSince($0) < TypingSession.switchGraceSeconds } ?? false
        if reported != currentLayoutID && !(justSwitched && reported == switchedFrom) {
            log("layout changed without a notice: \(currentLayoutID ?? "none") → \(reported ?? "none")")
            layoutChanged(to: reported)
        }
        return currentLayoutID.flatMap { layouts.layout(id: $0) }
    }

    /// Fix-while-typing: on Space, the word just finished (and the words before it on the same wrong layout).
    private func fixWordBeforeSpace() -> Edit? {
        let decision = AutoFix.decide(buffer: buffer, layouts: layouts, speller: speller)
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
