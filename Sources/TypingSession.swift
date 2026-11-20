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

    /// What the session tells the app to count (statistics) and, for an undone fix, learn from.
    enum Event: Equatable {
        /// Words fixed while typing.
        case autoFixed(words: Int)
        /// Words converted with right ⌥ (the last word; the app counts selections itself).
        case converted(words: Int)
        /// An automatic fix undone right after it: `typed` is each undone word as it was typed, on `layoutID`.
        case undone(typed: [String], layoutID: String)
        /// That undo taken back at once (right ⌥ tapped again): the fix stays after all.
        case restored(typed: [String], layoutID: String)
    }

    static let maxRemembered = 300
    static let undoKeyCode: UInt16 = 6  // Z
    /// Right after the app switches the layout itself, macOS can still report the old one for a moment.
    static let switchGraceSeconds: TimeInterval = 1
    /// How far back keys are re-read when macOS reports a switch it didn't announce: about how late its report
    /// was seen to be after a person's own switch (a few keys).
    static let lateReportSeconds: TimeInterval = 0.6
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
    /// Called for each fix, conversion and undo.
    var onEvent: ((Event) -> Void)?
    /// Words fix-while-typing leaves as typed (the person's exclusions).
    var isExcluded: AutoFix.IsExcluded = AutoFix.noExclusions

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
        lastChange = nil
        erasedFix = nil
        keepBefore = 0
    }

    /// ⌫. Erasing the whole word just fixed starts an undo: typed again with the same keys as before, it stays.
    func deleteBackward() {
        if !buffer.isEmpty { buffer.removeLast() }
        keepBefore = min(keepBefore, buffer.count)
        noteErasedFix()
    }

    /// ⌥⌫ right after a fix: the fixed word (and the space after it) is erased; anything else clears the memory.
    func deleteWordBackward() {
        guard let change = lastChange, change.automatic, let word = change.words.last,
              buffer.count <= word.upperBound + 1, buffer.count > word.lowerBound
        else { return reset("⌥⌫") }
        buffer.removeSubrange(word.lowerBound...)
        keepBefore = min(keepBefore, buffer.count)
        noteErasedFix()
    }

    /// ⌘Z right after a fix undoes it in the app. Any other ⌘ or ⌃ shortcut only clears the memory.
    func shortcut(_ stroke: KeyStroke, command: Bool, control: Bool) {
        let plainCommandZ = command && !control && stroke.keyCode == TypingSession.undoKeyCode
            && stroke.modifiers & (KeyStroke.shift | KeyStroke.option) == 0
        if plainCommandZ, let change = lastChange, change.automatic {
            log("auto-fix undone with ⌘Z (\(change.words.count) words)")
            onEvent?(.undone(typed: change.typed, layoutID: change.sourceID))
        }
        reset("a ⌘ or ⌃ shortcut")
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
        lastChange = nil
        if text == " " && autoFix {
            if settleLastWord(screenBeforeCursor) {
                if retypedErasedFix() {
                    keepBefore = buffer.count + 1
                } else if let edit = fixWordBeforeSpace() {
                    erasedFix = nil
                    return edit
                }
            } else {
                reset("the app changing the text")
            }
        }
        if text == " " { erasedFix = nil }
        buffer.append(Typed(stroke: stroke, layoutID: layout.id, text: text, at: now()))
        if buffer.count > TypingSession.maxRemembered {
            let extra = buffer.count - TypingSession.maxRemembered
            buffer.removeFirst(extra)
            keepBefore = max(0, keepBefore - extra)
            erasedFix = nil
        }
        return nil
    }

    /// Right ⌥ with nothing selected: the last word typed, on the other layout (tap again to flip it back).
    /// Right after an automatic fix it undoes the last word fixed; right after a tap it flips the word back
    /// (counted once). Either way that word is the person's choice from then on: later fixes don't take it along.
    func convertLastWord() -> Edit? {
        guard let range = Converter.lastWord(of: buffer),
              let typedOn = buffer[range].last(where: { !$0.isSpace })?.layoutID,
              let source = layouts.layout(id: typedOn), let target = layouts.other(than: typedOn)
        else { return nil }
        let word = range.lowerBound..<(buffer[range].lastIndex(where: { !$0.isSpace }).map { $0 + 1 } ?? range.upperBound)
        let typed = buffer[word].map(\.text).joined()
        var undid: Undone?
        if let change = lastChange, change.words.last == word {
            if change.automatic {
                log("auto-fix undone with right ⌥")
                undid = Undone(typed: [change.typed.last ?? ""], layoutID: change.sourceID)
                onEvent?(.undone(typed: undid!.typed, layoutID: undid!.layoutID))
            } else if let undone = change.undid {
                log("auto-fix undo taken back with right ⌥")
                onEvent?(.restored(typed: undone.typed, layoutID: undone.layoutID))
            }
        } else {
            onEvent?(.converted(words: 1))
        }
        let fixed = Converter.retype(buffer[range], on: target)
        buffer.replaceSubrange(range, with: fixed)
        appSwitched(to: target.id)
        lastChange = Change(automatic: false, words: [word], typed: [typed], strokes: [], sourceID: source.id, undid: undid)
        keepBefore = max(keepBefore, buffer.count)
        return Edit(erase: range.count, text: fixed.map(\.text).joined(), source: source, target: target)
    }

    // MARK: Private

    /// The last fix or right ⌥ conversion, until the next key that types: what an undo would undo.
    private struct Change {
        let automatic: Bool
        /// The changed words, as ranges of `buffer`.
        let words: [Range<Int>]
        /// Each changed word as it was before the change.
        let typed: [String]
        /// The keys of the last changed word (automatic fixes only).
        let strokes: [KeyStroke]
        let sourceID: String
        /// A right ⌥ tap that undid an automatic fix: what it undid, so tapping again takes the undo back.
        var undid: Undone? = nil
    }
    private struct Undone { let typed: [String]; let layoutID: String }
    private var lastChange: Change?
    /// The last fixed word was erased with ⌫ or ⌥⌫: typed again with the same keys on its own layout, it's an undo.
    private var erasedFix: (strokes: [KeyStroke], typed: String, sourceID: String)?
    /// Fixes never reach back before this index: the words there were undone or converted by the person.
    private var keepBefore = 0

    private func noteErasedFix() {
        guard let change = lastChange, change.automatic, let word = change.words.last, buffer.count <= word.lowerBound
        else { return }
        erasedFix = (change.strokes, change.typed.last ?? "", change.sourceID)
        lastChange = nil
    }

    /// The word before this Space is the erased fixed word typed again as it was: an undo, and it stays.
    private func retypedErasedFix() -> Bool {
        guard let erased = erasedFix, let range = AutoFix.wordRanges(in: buffer).last, range.upperBound == buffer.count
        else { return false }
        let word = buffer[range]
        guard word.map(\.stroke) == erased.strokes, word.allSatisfy({ $0.layoutID == erased.sourceID }) else { return false }
        log("auto-fix undone: the fixed word was erased and typed again as before")
        onEvent?(.undone(typed: [erased.typed], layoutID: erased.sourceID))
        erasedFix = nil
        return true
    }

    /// The fix's range without the words before `keepBefore`; nil when nothing is left.
    private func keepingChoices(_ range: Range<Int>) -> Range<Int>? {
        guard range.lowerBound < keepBefore else { return range }
        guard let first = AutoFix.wordRanges(in: buffer).first(where: {
            $0.lowerBound >= keepBefore && $0.lowerBound >= range.lowerBound && $0.upperBound <= range.upperBound
        }) else { return nil }
        return first.lowerBound..<range.upperBound
    }

    private func recordFix(_ range: Range<Int>, source: KeyLayout?) {
        let words = AutoFix.wordRanges(in: Array(buffer[range])).map { ($0.lowerBound + range.lowerBound)..<($0.upperBound + range.lowerBound) }
        let typed = words.map { buffer[$0].map(\.text).joined() }
        lastChange = Change(automatic: true, words: words, typed: typed,
                            strokes: words.last.map { buffer[$0].map(\.stroke) } ?? [], sourceID: source?.id ?? "")
        onEvent?(.autoFixed(words: words.count))
    }

    /// Logged once per word, so a stale key event shows in the log without filling it.
    private var loggedEventMismatch = false

    /// The layout this key was really typed on: the app's own record (its switches, macOS's notices), corrected by
    /// macOS's report, except a late report of the layout the app just switched away from.
    private func typingLayout(reported: String?) -> KeyLayout? {
        let justSwitched = switchedAt.map { now().timeIntervalSince($0) < TypingSession.switchGraceSeconds } ?? false
        if reported != currentLayoutID && !(justSwitched && reported == switchedFrom) {
            log("layout changed without a notice: \(currentLayoutID ?? "none") → \(reported ?? "none")")
            rereadRecentKeys(on: reported)
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

    /// macOS reports a switch it didn't announce, late: the keys typed just before were most likely already on
    /// the new layout ("що" typed on English after switching shows as "oj"). They're re-read on it. A key that
    /// really was on the old layout, re-read, converts back to what's on screen, so nothing visible goes wrong.
    private func rereadRecentKeys(on reportedID: String?) {
        guard let reportedID, let layout = layouts.layout(id: reportedID) else { return }
        let since = now().addingTimeInterval(-TypingSession.lateReportSeconds)
        var index = buffer.count
        while index > 0, let at = buffer[index - 1].at, at >= since { index -= 1 }
        guard index < buffer.count else { return }
        let reread = Converter.retype(buffer[index...], on: layout)
        guard zip(reread, buffer[index...]).contains(where: { $0.layoutID != $1.layoutID }) else { return }
        buffer.replaceSubrange(index..., with: reread)
        log("re-read the last \(reread.count) keys on \(layout.id) (macOS reported the switch late)")
    }

    /// Fix-while-typing: on Space, the word just finished (and the words before it on the same wrong layout).
    private func fixWordBeforeSpace() -> Edit? {
        let decision = AutoFix.decide(buffer: buffer, layouts: layouts, speller: speller, isExcluded: isExcluded)
        if case .fixShortWords(let found, let target) = decision {
            guard let range = keepingChoices(found) else { return nil }
            return fixShortWords(range, on: target)
        }
        guard case .fix(let found, let target) = decision else {
            if case .skip(let reason) = decision { logSkip(reason) }
            return nil
        }
        guard let range = keepingChoices(found) else { return nil }
        let source = buffer.last.flatMap { layouts.layout(id: $0.layoutID) }
        recordFix(range, source: source)
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
        recordFix(range, source: source)
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
