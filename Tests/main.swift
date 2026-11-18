import Foundation

// Uses layouts macOS ships (enabled or not), so it runs on any Mac whatever keyboards are turned on.
var failures = 0
func check(_ name: String, _ got: String?, _ want: String) {
    let got = got ?? "nil"
    if got == want { print("ok    \(name)") } else { failures += 1; print("FAIL  \(name): got \(got), want \(want)") }
}

func layoutSet(_ ids: [String], preferred: String? = nil) -> LayoutSet {
    let layouts = KeyLayout.installed(ids: ids.map { "com.apple.keylayout.\($0)" })
    guard layouts.count == ids.count else { print("FAIL  missing layouts: \(ids)"); exit(1) }
    return LayoutSet(layouts: layouts, preferredLocalID: preferred.map { "com.apple.keylayout.\($0)" })
}
let ukrainianSet = layoutSet(["ABC", "Ukrainian-PC"])
let russianSet = layoutSet(["US", "RussianWin"])
let greekSet = layoutSet(["ABC", "Greek"])
let germanSet = layoutSet(["ABC", "German"])
let english = ukrainianSet.english!
let ukrainian = ukrainianSet.local!

/// Simulate typing `text` as the keys that produce it on `layout`.
func typed(_ text: String, on layout: KeyLayout) -> [Typed] {
    text.map { char in
        guard let stroke = layout.strokeForCharacter[char] else { fatalError("\(layout.id) can't type \(char)") }
        return Typed(stroke: stroke, layoutID: layout.id, text: String(char))
    }
}
/// The same keys on the other layout (what fix-while-typing does to a word).
func retype(_ buffer: [Typed], in layouts: LayoutSet = ukrainianSet) -> String? {
    guard let typedOn = buffer.last?.layoutID, let target = layouts.other(than: typedOn) else { return nil }
    return Converter.retype(buffer[...], on: target).map(\.text).joined()
}
func select(_ text: String, in layouts: LayoutSet = ukrainianSet, current: String? = nil) -> String? {
    Converter.convert(text: text, layouts: layouts, currentID: current.map { "com.apple.keylayout.\($0)" })?.text
}

// Selection: text only, layout guessed from the characters.
check("selection uk→en", select("руддщ шеєі ьу"), "hello it's me")
check("selection en→uk", select("ghbdsn wt z"), "привіт це я")
check("selection keeps case", select("Ghbdsn"), "Привіт")
check("selection target", Converter.convert(text: "ghbdsn", layouts: ukrainianSet)?.target.language, "uk")
check("selection of digits only is left alone", select("123"), "nil")
check("selection from the email", select("рун умукнщту, рщц фку нщг вщштп , "), "hey everyone? how are you doing ? ")
check("punctuation by key: , → ?", select("руддщ,"), "hello?")
check("punctuation by key: ? → ,", select("hello?"), "руддщ,")
check("punctuation by key: . → /", select("руддщ."), "hello/")
check("punctuation by key: @ → \"", select("ghbdsn@"), "привіт\"")
check("last word: , → ?", retype(typed("руддщ,", on: ukrainian)), "hello?")

// Typed keys replayed on the other layout.
check("keys en→uk", retype(typed("ghbdsn wt z", on: english)), "привіт це я")
check("keys uk→en", retype(typed("руддщ шеєі ьу", on: ukrainian)), "hello it's me")
check("punctuation keys are letters", retype(typed("lj,hjuj", on: english)), "доброго")
check("flip twice returns", retype(typed(retype(typed("ghbdsn", on: english))!, on: ukrainian)), "ghbdsn")
let optionSpace = Typed(stroke: KeyStroke(keyCode: 49, modifiers: KeyStroke.option), layoutID: english.id, text: "\u{00A0}")
check("⌥Space (non-breaking space) stays", retype(typed("ghbdsn", on: english) + [optionSpace] + typed("wt", on: english)), "привіт\u{00A0}це")

// Nothing selected: the last word typed (with the spaces after it) goes to the other layout.
func lastWord(_ buffer: [Typed]) -> String? {
    guard let range = Converter.lastWord(of: buffer),
          let typedOn = buffer[range].last(where: { !$0.isSpace })?.layoutID,
          let target = ukrainianSet.other(than: typedOn) else { return nil }
    var out = buffer
    out.replaceSubrange(range, with: Converter.retype(buffer[range], on: target))
    return out.map(\.text).joined()
}
check("last word only", lastWord(typed("я люблю ізщешан", on: ukrainian)), "я люблю spotify")
check("last word with trailing space", lastWord(typed("ghbdsn ", on: english)), "привіт ")
check("last word flips back", lastWord(typed("привіт", on: ukrainian)), "ghbdsn")
check("nothing typed", lastWord(typed("   ", on: english)), "nil")

// Selection back and forth, the way the app does it: the second tap undoes the first exactly.
func backAndForth(_ text: String) -> String? {
    var memory = LastConversion()
    guard let first = Converter.convert(text: text, layouts: ukrainianSet) else { return nil }
    memory.remember(original: text, output: first.text, originalLayoutID: ukrainianSet.other(than: first.target.id)?.id)
    return memory.undo(of: first.text)?.text
}
for text in ["рун умукнщту, рщц фку нщг вщштп", "ghbdsn wt z", "Hello it's me"] {
    check("selection round trip: \(text)", backAndForth(text), text)
}
var memory = LastConversion()
memory.remember(original: "ghbdsn", output: "привіт", originalLayoutID: nil)
check("other text is converted, not undone", memory.undo(of: "привіт це я")?.text, "nil")

// Other languages ↔ English.
check("russian: en→ru", retype(typed("ghbdtn vbh", on: russianSet.english!), in: russianSet), "привет мир")
check("russian: ru→en", select("руддщ цщкдв", in: russianSet), "hello world")
check("greek: en→el", retype(typed("geia", on: greekSet.english!), in: greekSet), "γεια")
check("greek: el→en", select("ηελλο", in: greekSet), "hello")
check("german: en→de swaps y/z", retype(typed("yu Hause", on: germanSet.english!), in: germanSet), "zu Hause")
check("german: selection uses the layout that is on", select("yu", in: germanSet, current: "ABC"), "zu")

// Several local layouts: English flips to the one you used last; Cyrillic goes back to English.
let threeUA = layoutSet(["ABC", "Ukrainian-PC", "RussianWin"], preferred: "Ukrainian-PC")
let threeRU = layoutSet(["ABC", "Ukrainian-PC", "RussianWin"], preferred: "RussianWin")
check("three layouts: en→last used (uk)", retype(typed("ghbdsn", on: threeUA.english!), in: threeUA), "привіт")
check("three layouts: en→last used (ru)", retype(typed("ghbdtn", on: threeRU.english!), in: threeRU), "привет")
check("three layouts: ru→en", retype(typed("руддщ", on: threeUA.layout(id: "com.apple.keylayout.RussianWin")!), in: threeUA), "hello")
check("three layouts: Cyrillic selection→en", select("руддщ", in: threeRU, current: "ABC"), "hello")
check("three layouts: ї means Ukrainian", Converter.typedLayout(of: "їжак", layouts: threeRU)?.language, "uk")
let noEnglish = layoutSet(["Ukrainian-PC", "RussianWin"])
check("no English layout: uk→ru", noEnglish.other(than: "com.apple.keylayout.Ukrainian-PC")?.language, "ru")

// Auto mode with the system spell checker: `text` is typed on `layout` (as if you forgot to switch),
// then Space is pressed. Returns the whole text after the fix, or "nil" when nothing is fixed.
func auto(_ text: String, on layout: KeyLayout, in layouts: LayoutSet = ukrainianSet) -> String? {
    let buffer = typed(text, on: layout)
    guard let (range, target) = AutoFix.fix(buffer: buffer, layouts: layouts) else { return nil }
    var out = buffer
    out.replaceSubrange(range, with: Converter.retype(buffer[range], on: target))
    return out.map(\.text).joined()
}
check("auto fixes en→uk", auto("ghbdsn", on: english), "привіт")
check("auto fixes uk→en", auto("руддщ", on: ukrainian), "hello")
check("auto keeps a real English word", auto("hello", on: english), "nil")
check("auto keeps a real Ukrainian word", auto("привіт", on: ukrainian), "nil")
check("auto skips short words", auto("wt", on: english), "nil")
check("auto fixes the earlier words of the phrase", auto("рун умукщту рщц", on: ukrainian), "hey everone how")
check("auto fixes a typo of an English word", auto("умукщту", on: ukrainian), "everone")
check("auto fixes a typo of a Ukrainian word", auto("ghbdsy", on: english), "привін")
check("auto fixes code typed in Ukrainian", auto("сщву", on: ukrainian), "code")
check("auto stops at a word that belongs", auto("я люблю сщвштп", on: ukrainian), "я люблю coding")
check("auto leaves an earlier switch alone", auto("hello ghbdsn", on: english), "hello привіт")
check("auto fixes en→ru", auto("ghbdtn", on: russianSet.english!, in: russianSet), "привет")
check("auto keeps a real Russian word", auto("привет", on: russianSet.local!, in: russianSet), "nil")
check("auto fixes en→el", auto("kalhmera", on: greekSet.english!, in: greekSet), "καλημερα")
// Keys that are punctuation in English but letters in Ukrainian, at the start or end of a word.
check("auto: ];fr → їжак (leading ] and ;)", auto("];fr", on: english), "їжак")
check("auto: }];fr → Їжак", auto("};fr", on: english), "Їжак")
check("auto: `fyre → ґанку", auto("`fyre", on: english), "ґанку")
check("auto: cdj' → своє", auto("cdj'", on: english), "своє")
check("auto: ,helyt → брудне", auto(",helyt", on: english), "брудне")
check("auto: the whole phrase", auto("];fr yf `fyre phj,bd cdj' ,helyt lskj", on: english), "їжак на ґанку зробив своє брудне діло")
check("auto: English it's stays", auto("it's", on: english), "nil")
check("auto: English (hello) stays", auto("(hello)", on: english), "nil")
// Ukrainian letters that are brackets or slashes on English: what's left between them isn't a word ("vv").
check("auto: Хмм... stays (not {vv///)", auto("Хмм...", on: ukrainian), "nil")
check("auto: Хмм stays (not {vv)", auto("Хмм", on: ukrainian), "nil")
check("auto: Хмм, stays", auto("Хмм,", on: ukrainian), "nil")
check("auto: Ммм... stays (not Vvv///)", auto("Ммм...", on: ukrainian), "nil")
check("auto: Руддщю → Hello.", auto("Руддщю", on: ukrainian), "Hello.")
check("auto: Руддщ! → Hello!", auto("Руддщ!", on: ukrainian), "Hello!")
check("auto: шеєі → it's", auto("шеєі", on: ukrainian), "it's")

// Why a word was left alone (the log shows the reason).
func skip(_ text: String, on layout: KeyLayout) -> String {
    if case .skip(let reason) = AutoFix.decide(buffer: typed(text, on: layout), layouts: ukrainianSet) { return "\(reason)" }
    return "fixed"
}
check("skip: too short", skip("wt", on: english), "tooShort")
check("skip: a real English word", skip("hello", on: english), "realWordHere")
check("skip: not a word on Ukrainian either", skip("qxzv", on: english), "notAWordOnOtherLayout")
check("skip: nothing typed before the space", skip("ghbdsn ", on: english), "noWord")
check("skip: converts", skip("ghbdsn", on: english), "fixed")

// The typo rule with fixed spell-checker answers: macOS's own dictionaries change with updates and what the Mac
// learns (in November 2026 its English checker started taking "nsrtf" as a word and offering it for "nsrtn").
struct StubSpeller: Speller {
    var corrections: [String: String] = [:]
    var guessLists: [String: [String]] = [:]
    func supports(_ language: String) -> Bool { true }
    func isValid(_ word: String, language: String) -> Bool { false }
    func correction(for word: String, language: String) -> String? { corrections[word] }
    func guesses(for word: String, language: String) -> [String] { guessLists[word] ?? [] }
}
func stubSkip(_ text: String, on layout: KeyLayout, _ speller: StubSpeller) -> String {
    let decision = AutoFix.decide(buffer: typed(text, on: layout), layouts: ukrainianSet, speller: speller)
    if case .skip(let reason) = decision { return "\(reason)" }
    return "fixed"
}
check("typo: close only on the other side converts",
      stubSkip("тікет", on: ukrainian, StubSpeller(corrections: ["nsrtn": "nsrtf"])), "fixed")
check("typo: close on both sides stays (тікет ~ пікет, nsrtn ~ nsrtf)",
      stubSkip("тікет", on: ukrainian, StubSpeller(corrections: ["nsrtn": "nsrtf"], guessLists: ["тікет": ["пікет"]])),
      "notAWordOnOtherLayout")
// A word the English dictionary only knows split in two ("webhook" → "web hook"): it converts, whatever the Mac
// has learned. A guess that differs by more than the split doesn't count.
check("compound: цуирщщл → webhook (guess: web hook)",
      stubSkip("цуирщщл", on: ukrainian, StubSpeller(guessLists: ["webhook": ["web hook"]])), "fixed")
check("compound: цуирщщв stays (guess: web hook is not it)",
      stubSkip("цуирщщв", on: ukrainian, StubSpeller(guessLists: ["webhood": ["web hook"]])), "notAWordOnOtherLayout")
// How a fixed word is put in: in one step through Accessibility only in native fields; web pages get keystrokes.
check("replace: a native text view", "\(ReplaceMethod.forField(roles: ["AXTextArea", "AXScrollArea", "AXWindow"]))",
      "accessibility")
check("replace: Gmail in a browser",
      "\(ReplaceMethod.forField(roles: ["AXTextArea", "AXGroup", "AXWebArea", "AXScrollArea", "AXGroup", "AXWindow"]))",
      "keystrokes")
check("replace: nothing known about the field", "\(ReplaceMethod.forField(roles: []))", "keystrokes")
check("typo: a far guess on this side doesn't hold it back",
      stubSkip("тікет", on: ukrainian, StubSpeller(corrections: ["nsrtn": "nsrtf"], guessLists: ["тікет": ["квиток"]])),
      "fixed")

// A phrase that switches layouts word by word: "Інтеграція з Stripe" right, then "ghjqikf ecgsiyj" on English.
let stripeStart = typed("Інтеграція з ", on: ukrainian) + typed("Stripe ", on: english)
func autoFrom(_ prefix: [Typed], _ word: String, on layout: KeyLayout) -> String? {
    let buffer = prefix + typed(word, on: layout)
    guard let (range, target) = AutoFix.fix(buffer: buffer, layouts: ukrainianSet) else { return nil }
    var out = buffer
    out.replaceSubrange(range, with: Converter.retype(buffer[range], on: target))
    return out.map(\.text).joined()
}
check("auto: after Stripe, ghjqikf → пройшла", autoFrom(stripeStart, "ghjqikf", on: english), "Інтеграція з Stripe пройшла")
check("auto: then ecgsiyj → успішно",
      autoFrom(stripeStart + typed("пройшла ", on: ukrainian), "ecgsiyj", on: english), "Інтеграція з Stripe пройшла успішно")

// Short words before an auto-fixed word: "з" is a word in Ukrainian and "p" in English, so on its own it stays.
check("auto: a short word before the fixed one stays", auto("синхронізацію з Сщтіефте", on: ukrainian), "синхронізацію з Constant")
check("auto: a short word at the start stays", auto("з Сщтіефте", on: ukrainian), "з Constant")
check("auto: a short word between converted words converts", auto("руддщ ш цфте ерші", on: ukrainian), "hello i want this")

// Fix-while-typing converts punctuation by key too.
check("auto: , typed for ? (uk→en)", auto("руддщ,", on: ukrainian), "hello?")
check("auto: phrase ending in ? (uk→en)", auto("рщц фку нщг,", on: ukrainian), "how are you?")
check("auto: / typed for . (en→uk)", auto("ghbdsn/", on: english), "привіт.")
check("auto: ? typed for , (en→uk)", auto("ghbdsn?", on: english), "привіт,")
check("auto: punctuation keys that are letters (en→uk)", auto("k.,k.", on: english), "люблю")
check("auto: б and ю keys inside a word (en→uk)", auto("lj,hjuj", on: english), "доброго")
check("auto: a real English word with a comma stays", auto("hello,", on: english), "nil")
check("auto: a real Ukrainian word with a comma stays", auto("привіт,", on: ukrainian), "nil")
check("edit distance", String(AutoFix.editDistance("everone", "everyone")), "1")

// Every key, plain, ⇧, ⌥ and ⇧⌥, both ways: selected text converts to what the same key types on the other
// layout. A character more than one key types ("!" is ⇧1 and ⌥1 on Ukrainian-PC) goes by its plain or ⇧ key.
func everyKey(_ set: LayoutSet) -> String {
    var misses: [String] = []
    for (from, to) in [(set.local!, set.english!), (set.english!, set.local!)] {
        for modifiers in KeyLayout.reverseMapModifiers {
            for keyCode in KeyLayout.mainBlockKeyCodes {
                let stroke = KeyStroke(keyCode: keyCode, modifiers: modifiers)
                guard let char = from.character(for: stroke), char.count == 1, char != " ",
                      let want = to.character(for: stroke),
                      from.strokeForCharacter[Character(char)] == stroke  // the key this character means
                else { continue }
                let got = to.character(for: from.strokeForCharacter[Character(char)]!)
                if got != want { misses.append("\(char)→\(got ?? "nil")") }
            }
        }
    }
    return misses.isEmpty ? "all keys" : misses.joined(separator: " ")
}
check("every key: ABC ↔ Ukrainian-PC", everyKey(ukrainianSet), "all keys")
check("every key: U.S. ↔ Russian - PC", everyKey(russianSet), "all keys")
check("every key: ABC ↔ Greek", everyKey(greekSet), "all keys")
check("every key: ABC ↔ German", everyKey(germanSet), "all keys")
check("⌥ layer: ы (⌥S on Ukrainian) → ß", select("руддщ ы", current: "Ukrainian-PC"), "hello ß")

// MARK: Chains: whole sentences typed on a simulated Mac with fix-while-typing on.

/// A Mac as Layout Fixer sees it: the layout really on (it decides what each key types), the layout macOS reports
/// (it can lag a few keys behind a switch), whether key events carry their character, and the text on screen.
/// Keys go through a TypingSession the way the app sends them, and its edits are applied the way the app does.
final class SimulatedMac {
    let session: TypingSession
    private(set) var screen = ""
    private var actual: KeyLayout
    private var reported: KeyLayout
    private var lagLeft = 0
    var actualLayout: KeyLayout { actual }
    private let reportLag: Int
    private let eventCharacters: Bool
    /// Key events carry the character of the layout that was on before the app's own switch (seen on a real
    /// Mac: "key typed on Ukrainian-PC while the app had ABC", for whole words after a fix).
    private let staleEventText: Bool
    private var beforeAppSwitch: KeyLayout?

    /// macOS's report and notice lag behind the person's own switches too (seen on a real Mac: a word recorded
    /// half on Ukrainian, half on ABC, after switching to ABC).
    private let lateAfterOwnSwitch: Bool
    /// The app shares the text before the cursor (Accessibility), as most native apps do.
    private let screenReadable: Bool

    init(_ layouts: LayoutSet, startOn: KeyLayout, reportLag: Int = 0, eventCharacters: Bool = true,
         staleEventText: Bool = false, lateAfterOwnSwitch: Bool = false, screenReadable: Bool = false) {
        actual = startOn
        reported = startOn
        self.reportLag = reportLag
        self.eventCharacters = eventCharacters
        self.staleEventText = staleEventText
        self.lateAfterOwnSwitch = lateAfterOwnSwitch
        self.screenReadable = screenReadable
        let clock = clock
        session = TypingSession(layouts: layouts, currentLayoutID: startOn.id, now: { clock.now })
        session.autoFix = true
    }

    /// The person switches the layout (⌃Space); `notice` is whether the app hears macOS announce it.
    func personSwitches(to layout: KeyLayout, notice: Bool) {
        beforeAppSwitch = nil
        if lateAfterOwnSwitch && reportLag > 0 {
            reported = actual   // still the old one for `reportLag` keys, and no notice
            actual = layout
            lagLeft = reportLag
            return
        }
        actual = layout
        reported = layout
        lagLeft = 0
        if notice { session.layoutChanged(to: layout.id) }
    }

    /// Words, each with the layout the person means it in, each followed by Space: the keys that type the word
    /// on that layout are pressed on whatever layout is really on.
    func type(_ words: [(String, KeyLayout)]) {
        for (word, meant) in words {
            for char in word + " " { press(meant.strokeForCharacter[char]!) }
        }
    }

    /// A person types about ten keys a second.
    final class Clock { var now = Date(timeIntervalSince1970: 0) }
    let clock = Clock()
    static let secondsPerKey: TimeInterval = 0.1

    private func press(_ stroke: KeyStroke) {
        clock.now = clock.now.addingTimeInterval(SimulatedMac.secondsPerKey)
        let char = actual.character(for: stroke)!
        let reportedID: String
        if lagLeft > 0 { reportedID = reported.id; lagLeft -= 1 } else { reported = actual; reportedID = actual.id }
        let eventText = staleEventText ? (beforeAppSwitch ?? actual).character(for: stroke) : char
        let shown = screen
        let readScreen: ((Int) -> String?)? = screenReadable ? { count in String(shown.suffix(count)) } : nil
        guard let edit = session.type(stroke, eventCharacters: eventCharacters ? eventText : nil,
                                      reportedLayoutID: reportedID, screenBeforeCursor: readScreen)
        else { screen += char; return }
        screen.removeLast(edit.erase)
        screen += edit.text
        guard edit.switches else { return }
        reported = actual      // macOS keeps reporting the old layout for `reportLag` keys
        beforeAppSwitch = actual
        actual = edit.target
        lagLeft = reportLag
    }
}

/// Every chain runs five ways: no lag; macOS reporting the old layout for 3 keys after a switch; that lag with no
/// character in the key events; key events carrying the old layout's character after the app's switch (as on a
/// real Mac); and both. Only the app's own record of its switch, and macOS's report after that, may be trusted.
struct MacCondition {
    let name: String
    var lag = 0
    var eventCharacters = true
    var stale = false
    var lateAfterOwnSwitch = false
    var screenReadable = false

    func mac(_ layouts: LayoutSet, startOn: KeyLayout) -> SimulatedMac {
        SimulatedMac(layouts, startOn: startOn, reportLag: lag, eventCharacters: eventCharacters, staleEventText: stale,
                     lateAfterOwnSwitch: lateAfterOwnSwitch, screenReadable: screenReadable)
    }
}
let chainConditions: [MacCondition] = [
    MacCondition(name: "no lag"),
    MacCondition(name: "late report", lag: 3),
    MacCondition(name: "late report, no event text", lag: 3, eventCharacters: false),
    MacCondition(name: "stale event text", stale: true),
    MacCondition(name: "stale event text, late report", lag: 3, stale: true),
    MacCondition(name: "late report after your own switch", lag: 3, lateAfterOwnSwitch: true),
    MacCondition(name: "late report after your own switch, screen readable", lag: 3, lateAfterOwnSwitch: true,
                 screenReadable: true),
    MacCondition(name: "stale event text, late report, screen readable", lag: 3, stale: true, screenReadable: true),
]
func chain(_ name: String, startOn: KeyLayout, _ words: [(String, KeyLayout)], expect: String,
           in layouts: LayoutSet = ukrainianSet) {
    for condition in chainConditions {
        let mac = condition.mac(layouts, startOn: startOn)
        mac.type(words)
        check("chain, \(condition.name): \(name)", mac.screen, expect + " ")
    }
}
chain("Інтеграція з Stripe пройшла успішно (starts on English)", startOn: english,
      [("Інтеграція", ukrainian), ("з", ukrainian), ("Stripe", english), ("пройшла", ukrainian), ("успішно", ukrainian)],
      expect: "Інтеграція з Stripe пройшла успішно")
chain("Їжак на ґанку зробив своє брудне діло (starts on English)", startOn: english,
      [("Їжак", ukrainian), ("на", ukrainian), ("ґанку", ukrainian), ("зробив", ukrainian), ("своє", ukrainian),
       ("брудне", ukrainian), ("діло", ukrainian)],
      expect: "Їжак на ґанку зробив своє брудне діло")
chain("hey everyone how are you (starts on Ukrainian)", startOn: ukrainian,
      [("hey", english), ("everyone", english), ("how", english), ("are", english), ("you?", english)],
      expect: "hey everyone how are you?")
chain("синхронізацію з Constant Contact (short word stays)", startOn: ukrainian,
      [("синхронізацію", ukrainian), ("з", ukrainian), ("Constant", english), ("Contact", english)],
      expect: "синхронізацію з Constant Contact")
chain("Привіт, як справи? then English (switches twice)", startOn: english,
      [("Привіт,", ukrainian), ("як", ukrainian), ("справи?", ukrainian), ("Let's", english), ("meet", english)],
      expect: "Привіт, як справи? Let's meet")
// Rows typed on a real Mac (0.2.5), all started on ABC; each missed something there.
chain("row: Інтеграція з Stripe пройшла успішно", startOn: english,
      [("Інтеграція", ukrainian), ("з", ukrainian), ("Stripe", english), ("пройшла", ukrainian), ("успішно", ukrainian)],
      expect: "Інтеграція з Stripe пройшла успішно")
chain("row: Інтеграція з Stripe була успішною", startOn: english,
      [("Інтеграція", ukrainian), ("з", ukrainian), ("Stripe", english), ("була", ukrainian), ("успішною", ukrainian)],
      expect: "Інтеграція з Stripe була успішною")
chain("row: Їжак на (two-letter word after a fix stays right)", startOn: english,
      [("Їжак", ukrainian), ("на", ukrainian)], expect: "Їжак на")
chain("row: Ти зробив синхронізацію з Constant Contact?", startOn: english,
      [("Ти", ukrainian), ("зробив", ukrainian), ("синхронізацію", ukrainian), ("з", ukrainian),
       ("Constant", english), ("Contact?", english)],
      expect: "Ти зробив синхронізацію з Constant Contact?")
chain("row: I am just shocked (starts with two short words)", startOn: ukrainian,
      [("I", english), ("am", english), ("just", english), ("shocked", english)],
      expect: "I am just shocked")
chain("row: Я просто в шоці наскільки це круто (starts with a one-letter word)", startOn: english,
      [("Я", ukrainian), ("просто", ukrainian), ("в", ukrainian), ("шоці", ukrainian), ("наскільки", ukrainian),
       ("це", ukrainian), ("круто", ukrainian)],
      expect: "Я просто в шоці наскільки це круто")
chain("a real short word before a fixed one stays: I ghbdsn", startOn: english,
      [("I", english), ("привіт", ukrainian)], expect: "I привіт")
// Clicked into text already there ("make them consistent|") and typed ", you": the memory starts at the comma, and
// "," is the "б" key, a Ukrainian word. Punctuation on its own is punctuation, not a short word typed on the wrong layout.
chain("clicked after a word, then , you (the comma stays)", startOn: english,
      [(",", english), ("you", english)], expect: ", you")
chain("clicked after a word, then ; and (the semicolon stays)", startOn: english,
      [(";", english), ("and", english)], expect: "; and")
chain("русский текст и English (Russian)", startOn: russianSet.english!,
      [("привет", russianSet.local!), ("мир", russianSet.local!), ("hello", russianSet.english!), ("world", russianSet.english!)],
      expect: "привет мир hello world", in: russianSet)

// Switching yourself, macOS late to tell, then a word on the wrong layout: it's recorded half on each layout.
for condition in chainConditions {
    let mac = condition.mac(ukrainianSet, startOn: ukrainian)
    mac.type([("привіт", ukrainian)])
    mac.personSwitches(to: english, notice: false)
    mac.type([("світ", ukrainian), ("hello", english)])
    check("chain, \(condition.name): own switch to English, then світ typed on it", mac.screen, "привіт світ hello ")
}

// Tested on a real Mac: switched to English mid-sentence, then "що робиш" typed on it.
for condition in chainConditions {
    let mac = condition.mac(ukrainianSet, startOn: ukrainian)
    mac.type([("привіт", ukrainian), ("як", ukrainian), ("справи", ukrainian)])
    mac.personSwitches(to: english, notice: false)
    mac.type([("що", ukrainian), ("робиш", ukrainian), ("сьогодні", ukrainian)])
    check("chain, \(condition.name): що робиш typed on English after a switch", mac.screen, "привіт як справи що робиш сьогодні ")
}
chain("як справи що робиш (never switches, from English)", startOn: english,
      [("як", ukrainian), ("справи", ukrainian), ("що", ukrainian), ("робиш", ukrainian)], expect: "як справи що робиш")

// The person switches the layout themselves: what they type on it stays, with or without macOS's notice.
for notice in [true, false] {
    for eventCharacters in [true, false] {
        let mac = SimulatedMac(ukrainianSet, startOn: english, eventCharacters: eventCharacters)
        mac.type([("hello", english)])
        mac.personSwitches(to: ukrainian, notice: notice)
        mac.type([("привіт", ukrainian), ("світ", ukrainian)])
        check("chain: own switch (notice \(notice), event text \(eventCharacters)) keeps what's typed",
              mac.screen, "hello привіт світ ")
    }
}

// MARK: Corpus: ~100 real-life sentences (Ukrainian, English, mixed), typed the ways people type them.

/// The layout a word is meant in: Cyrillic letters → Ukrainian, Latin → English, none (numbers, dashes) → nil.
func meantLayout(_ word: String) -> KeyLayout? {
    if word.unicodeScalars.contains(where: { (0x0400...0x04FF).contains($0.value) }) { return ukrainian }
    if word.unicodeScalars.contains(where: { $0.properties.isAlphabetic && $0.isASCII }) { return english }
    return nil
}

enum CorpusScenario: CaseIterable {
    case switchesWithNotice, switchesWithoutNotice, neverSwitchesFromEnglish, neverSwitchesFromUkrainian
    var name: String {
        switch self {
        case .switchesWithNotice: "switches layouts correctly"
        case .switchesWithoutNotice: "switches correctly, macOS sends no notice"
        case .neverSwitchesFromEnglish: "never switches, starts on English"
        case .neverSwitchesFromUkrainian: "never switches, starts on Ukrainian"
        }
    }
}

/// Types one sentence and returns the screen (without the final Space).
func typeSentence(_ sentence: String, _ scenario: CorpusScenario, _ condition: MacCondition) -> String {
    let words = sentence.split(separator: " ").map(String.init)
    let first = words.compactMap(meantLayout).first ?? english
    let start: KeyLayout
    switch scenario {
    case .switchesWithNotice, .switchesWithoutNotice: start = first
    case .neverSwitchesFromEnglish: start = english
    case .neverSwitchesFromUkrainian: start = ukrainian
    }
    let mac = condition.mac(ukrainianSet, startOn: start)
    for word in words {
        let meant = meantLayout(word) ?? mac.actualLayout
        let switches = scenario == .switchesWithNotice || scenario == .switchesWithoutNotice
        if switches && meantLayout(word) != nil && meant.id != mac.actualLayout.id {
            mac.personSwitches(to: meant, notice: scenario == .switchesWithNotice)
        }
        mac.type([(word, meant)])
    }
    return String(mac.screen.dropLast())
}

/// Sentences fix-while-typing can't get right when the person never switches: each has a word no dictionary
/// knows (slang, a name, jargon, an acronym), which it won't guess at. A right ⌥ tap fixes them. The test fails
/// when another sentence misses, and when one of these starts working (so the list stays true).
let knownNeverSwitchMisses: [String: String] = [
    "Задеплоїв на staging, перевір, будь ласка.": "\"Задеплоїв\" is slang, not in the dictionary (from English)",
    "Налаштуй CI для нового репозиторію.": "\"CI\" is an acronym",
    "У Jira створив тікет для API.": "\"Jira\" is a name (from Ukrainian); \"тікет\" isn't in the dictionary (from English)",
]

// Typed on the right layout, every sentence must come out untouched. Never switching, every sentence must come
// out as meant, apart from the known limits above. A miss lists the sentence.
var corpusTotals: [String] = []
for scenario in CorpusScenario.allCases {
    let neverSwitches = scenario == .neverSwitchesFromEnglish || scenario == .neverSwitchesFromUkrainian
    for condition in chainConditions {
        var unexpected: [String] = []
        var known: [String] = []
        for sentence in Corpus.all {
            let screen = typeSentence(sentence, scenario, condition)
            if screen == sentence { continue }
            if neverSwitches && knownNeverSwitchMisses[sentence] != nil { known.append(sentence); continue }
            unexpected.append("\n      got:  \(screen)\n      want: \(sentence)")
        }
        let right = Corpus.all.count - unexpected.count - known.count
        corpusTotals.append("\(right)/\(Corpus.all.count)  \(scenario.name), \(condition.name)"
                            + (known.isEmpty ? "" : " (\(known.count) known limits)"))
        check("corpus: \(scenario.name), \(condition.name)", unexpected.isEmpty ? "all right" : unexpected.joined(), "all right")
        if neverSwitches {
            // A known limit that now works (in both starting layouts it can't be known for one only) is reported.
            let nowRight = knownNeverSwitchMisses.keys.filter { sentence in
                !known.contains(sentence) && typeSentence(sentence, .neverSwitchesFromEnglish, condition) == sentence
                    && typeSentence(sentence, .neverSwitchesFromUkrainian, condition) == sentence
            }
            check("corpus: known limits still missed, \(scenario.name), \(condition.name)",
                  nowRight.isEmpty ? "all still missed" : "now right: \(nowRight)", "all still missed")
        }
    }
}
print("corpus results:\n  " + corpusTotals.joined(separator: "\n  "))
print("known limits (right ⌥ fixes them):\n  " + knownNeverSwitchMisses.map { "\($0.key)  — \($0.value)" }.sorted().joined(separator: "\n  "))
// What the simulated Mac shows for each known limit, to set beside build/e2e-report.txt: the same text there
// means the simulator models the real Mac for that sentence.
for scenario in [CorpusScenario.neverSwitchesFromEnglish, .neverSwitchesFromUkrainian] {
    let shown = knownNeverSwitchMisses.keys.sorted().compactMap { sentence -> String? in
        let screen = typeSentence(sentence, scenario, chainConditions[0])
        return screen == sentence ? nil : "got:  \(screen)\n    want: \(sentence)"
    }
    print("known limits, \(scenario.name):\n    " + shown.joined(separator: "\n    "))
}

// Release notes as the update dialog shows them.
func plain(_ runs: [ReleaseNotes.Run]) -> String {
    runs.map { $0.bold ? "[\($0.text)]" : $0.code ? "<\($0.text)>" : $0.text }.joined()
}
let notes = ReleaseNotes.parse("""
## What's new

**A settings window.** Click the icon.
- Replaces `LayoutFixer.app`
• Turn on **Open at login**


""")
check("notes: kinds", notes.map { "\($0.kind)" }.joined(separator: ","), "heading,blank,text,bullet,bullet")
check("notes: heading", plain(notes[0].runs), "What's new")
check("notes: bold", plain(notes[2].runs), "[A settings window.] Click the icon.")
check("notes: code in a bullet", plain(notes[3].runs), "Replaces <LayoutFixer.app>")
check("notes: • bullet with bold", plain(notes[4].runs), "Turn on [Open at login]")
let wrapped = ReleaseNotes.parse("- Fix while typing no longer\n  trusts `the event`.\n- Next")
check("notes: an indented line carries on its bullet", wrapped.map { "\($0.kind):\(plain($0.runs))" }.joined(separator: " | "),
      "bullet:Fix while typing no longer trusts <the event>. | bullet:Next")
check("notes: unclosed markers stay text", plain(ReleaseNotes.runs("2 ** 3 and a ` tick")), "2 ** 3 and a ` tick")

// Update progress, read from the installer's log.
func progress(_ log: String, _ seconds: Double = 0) -> String {
    let state = UpdateProgress.state(log: log, compilingFor: seconds, expectedCompile: 40)
    return "\(state.step) \(state.percent)%"
}
check("progress: starting", progress(""), "Starting… 1%")
check("progress: downloading", progress("Downloading https://…"), "Downloading… 4%")
check("progress: building, no step yet", progress("Downloading x\nBuilding (about a minute)…"), "Building… 8%")
let compiling = "Downloading x\nBuilding…\n==> Compiling for Apple silicon and Intel"
check("progress: compiling, start", progress(compiling, 0), "Compiling for Apple silicon and Intel… 10%")
check("progress: compiling, halfway", progress(compiling, 20), "Compiling for Apple silicon and Intel… 49%")
check("progress: compiling never claims done", progress(compiling, 400), "Compiling for Apple silicon and Intel… 86%")
check("progress: signing", progress(compiling + "\n==> Signing"), "Signing… 90%")
check("progress: installing", progress(compiling + "\n==> Signing\n==> Installing to ~/Applications"), "Installing… 94%")
check("progress: built", progress(compiling + "\n==> Installing to ~/Applications\nBuilt in 41s"), "Restarting… 97%")
check("progress: build time", UpdateProgress.builtSeconds(log: "x\nBuilt in 41s").map(String.init), "41")

// Versions for the update check.
check("version from a tag", Version("v1.4.2")?.description, "1.4.2")
check("version pads missing parts", Version("2.1")?.description, "2.1.0")
check("version ignores a pre-release suffix", Version("1.5.0-beta.1")?.description, "1.5.0")
check("version rejects junk", Version("latest")?.description, "nil")
check("1.10.0 is newer than 1.9.3", String(Version("1.10.0")! > Version("1.9.3")!), "true")
check("1.0.0 is not newer than 1.0.0", String(Version("v1.0.0")! > Version("1.0.0")!), "false")

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
