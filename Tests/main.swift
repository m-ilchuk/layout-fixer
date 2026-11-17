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
func fix(_ buffer: [Typed], wholePhrase: Bool, in layouts: LayoutSet = ukrainianSet) -> String? {
    guard let range = Converter.segment(of: buffer, wholePhrase: wholePhrase),
          let target = Converter.target(for: buffer[range], in: layouts) else { return nil }
    var out = buffer
    out.replaceSubrange(range, with: Converter.retype(buffer[range], on: target))
    return out.map(\.text).joined()
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

// Typed buffer: replay the keys.
check("phrase en→uk", fix(typed("ghbdsn wt z", on: english), wholePhrase: true), "привіт це я")
check("phrase uk→en", fix(typed("руддщ шеєі ьу", on: ukrainian), wholePhrase: true), "hello it's me")
check("last word only", fix(typed("я люблю ізщешан", on: ukrainian), wholePhrase: false), "я люблю spotify")
check("last word with trailing space", fix(typed("ghbdsn ", on: english), wholePhrase: false), "привіт ")
check("punctuation keys are letters", fix(typed("lj,hjuj", on: english), wholePhrase: false), "доброго")
check("flip twice returns", fix(typed(fix(typed("ghbdsn", on: english), wholePhrase: false)!, on: ukrainian), wholePhrase: false), "ghbdsn")

// Other languages ↔ English.
check("russian: en→ru", fix(typed("ghbdtn vbh", on: russianSet.english!), wholePhrase: true, in: russianSet), "привет мир")
check("russian: ru→en", select("руддщ цщкдв", in: russianSet), "hello world")
check("greek: en→el", fix(typed("geia", on: greekSet.english!), wholePhrase: true, in: greekSet), "γεια")
check("greek: el→en", select("ηελλο", in: greekSet), "hello")
check("german: en→de swaps y/z", fix(typed("yu Hause", on: germanSet.english!), wholePhrase: true, in: germanSet), "zu Hause")
check("german: selection uses the layout that is on", select("yu", in: germanSet, current: "ABC"), "zu")

// Several local layouts: English flips to the one you used last; Cyrillic goes back to English.
let threeUA = layoutSet(["ABC", "Ukrainian-PC", "RussianWin"], preferred: "Ukrainian-PC")
let threeRU = layoutSet(["ABC", "Ukrainian-PC", "RussianWin"], preferred: "RussianWin")
check("three layouts: en→last used (uk)", fix(typed("ghbdsn", on: threeUA.english!), wholePhrase: false, in: threeUA), "привіт")
check("three layouts: en→last used (ru)", fix(typed("ghbdtn", on: threeRU.english!), wholePhrase: false, in: threeRU), "привет")
check("three layouts: ru→en", fix(typed("руддщ", on: threeUA.layout(id: "com.apple.keylayout.RussianWin")!), wholePhrase: false, in: threeUA), "hello")
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

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
