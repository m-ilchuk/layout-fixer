import Foundation

// Runs against the layouts enabled on this Mac (needs ABC/US and Ukrainian-PC turned on).
var failures = 0
func check(_ name: String, _ got: String?, _ want: String) {
    let got = got ?? "nil"
    if got == want { print("ok    \(name)") } else { failures += 1; print("FAIL  \(name): got \(got), want \(want)") }
}

let layouts = LayoutSet(layouts: KeyLayout.enabledLayouts())
guard let english = layouts.layouts.first(where: { $0.language == "en" }),
      let ukrainian = layouts.layouts.first(where: { $0.language == "uk" })
else { print("FAIL  need an English and a Ukrainian layout enabled"); exit(1) }
print("layouts: \(layouts.layouts.map(\.id))")

/// Simulate typing `text` as the keys that produce it on `layout`.
func typed(_ text: String, on layout: KeyLayout) -> [Typed] {
    text.map { char in
        let stroke = layout.strokeForCharacter[char]!
        return Typed(stroke: stroke, layoutID: layout.id, text: String(char))
    }
}
func fix(_ buffer: [Typed], wholePhrase: Bool) -> String? {
    guard let range = Converter.segment(of: buffer, wholePhrase: wholePhrase),
          let target = Converter.target(for: buffer[range], in: layouts) else { return nil }
    var out = buffer
    out.replaceSubrange(range, with: Converter.retype(buffer[range], on: target))
    return out.map(\.text).joined()
}

// Selection: text only, layout guessed from the characters.
check("selection uk→en", Converter.convert(text: "руддщ шеєі ьу", layouts: layouts)?.text, "hello it's me")
check("selection en→uk", Converter.convert(text: "ghbdsn wt z", layouts: layouts)?.text, "привіт це я")
check("selection keeps case", Converter.convert(text: "Ghbdsn", layouts: layouts)?.text, "Привіт")
check("selection target", Converter.convert(text: "ghbdsn", layouts: layouts)?.target.language, "uk")
check("selection of digits only is left alone", Converter.convert(text: "123", layouts: layouts)?.text, "nil")

check("selection from the email", Converter.convert(text: "рун умукнщту, рщц фку нщг вщштп , ", layouts: layouts)?.text, "hey everyone, how are you doing , ")
check("selection keeps @ in en→uk", Converter.convert(text: "ghbdsn@", layouts: layouts)?.text, "привіт@")

// Typed buffer: replay the keys.
check("phrase en→uk", fix(typed("ghbdsn wt z", on: english), wholePhrase: true), "привіт це я")
check("phrase uk→en", fix(typed("руддщ шеєі ьу", on: ukrainian), wholePhrase: true), "hello it's me")
check("last word only", fix(typed("я люблю ізщешан", on: ukrainian), wholePhrase: false), "я люблю spotify")
check("last word with trailing space", fix(typed("ghbdsn ", on: english), wholePhrase: false), "привіт ")
check("punctuation keys are letters", fix(typed("lj,hjuj", on: english), wholePhrase: false), "доброго")
check("flip twice returns", fix(typed(fix(typed("ghbdsn", on: english), wholePhrase: false)!, on: ukrainian), wholePhrase: false), "ghbdsn")

// Auto mode with the system spell checker: `text` is typed on `layout` (as if you forgot to switch),
// then Space is pressed. Returns the whole text after the fix, or "nil" when nothing is fixed.
func auto(_ text: String, on layout: KeyLayout) -> String? {
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
check("edit distance", String(AutoFix.editDistance("everone", "everyone")), "1")

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
