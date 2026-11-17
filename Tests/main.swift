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
check("selection from the email", select("рун умукнщту, рщц фку нщг вщштп , "), "hey everyone, how are you doing , ")
check("selection keeps @ in en→uk", select("ghbdsn@"), "привіт@")

// Typed keys replayed on the other layout.
check("keys en→uk", retype(typed("ghbdsn wt z", on: english)), "привіт це я")
check("keys uk→en", retype(typed("руддщ шеєі ьу", on: ukrainian)), "hello it's me")
check("punctuation keys are letters", retype(typed("lj,hjuj", on: english)), "доброго")
check("flip twice returns", retype(typed(retype(typed("ghbdsn", on: english))!, on: ukrainian)), "ghbdsn")
let optionSpace = Typed(stroke: KeyStroke(keyCode: 49, modifiers: KeyStroke.option), layoutID: english.id, text: "\u{00A0}")
check("⌥Space (non-breaking space) stays", retype(typed("ghbdsn", on: english) + [optionSpace] + typed("wt", on: english)), "привіт\u{00A0}це")

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
check("edit distance", String(AutoFix.editDistance("everone", "everyone")), "1")

// Versions for the update check.
check("version from a tag", Version("v1.4.2")?.description, "1.4.2")
check("version pads missing parts", Version("2.1")?.description, "2.1.0")
check("version ignores a pre-release suffix", Version("1.5.0-beta.1")?.description, "1.5.0")
check("version rejects junk", Version("latest")?.description, "nil")
check("1.10.0 is newer than 1.9.3", String(Version("1.10.0")! > Version("1.9.3")!), "true")
check("1.0.0 is not newer than 1.0.0", String(Version("v1.0.0")! > Version("1.0.0")!), "false")

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
