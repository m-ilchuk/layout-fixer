import Foundation

/// What Layout Fixer will do with the keyboard layouts this Mac has. The installer prints it
/// (`LayoutFixer --layouts`) and the menu shows its first line.
enum Setup {
    static let inputSourcesHint = "System Settings › Keyboard › Text Input › Input Sources › Edit"

    static func pairLine(_ layouts: LayoutSet) -> String {
        if let pair = layouts.pairDescription { return "Switches \(pair)" }
        if layouts.english == nil && layouts.layouts.count >= 2 {
            return "Switches \(layouts.layouts.map(\.name).joined(separator: " ↔ "))"
        }
        return layouts.english == nil ? "Add an English layout (ABC or U.S.)" : "Add your language's keyboard layout"
    }

    static func summary(_ layouts: LayoutSet, speller: Speller) -> [String] {
        let names = layouts.layouts.map { "\($0.name) (\($0.language))" }.joined(separator: ", ")
        var lines = ["Keyboard layouts: \(names.isEmpty ? "none" : names)"]
        guard layouts.layouts.count >= 2 else {
            lines.append("Layout Fixer needs two layouts, English and your language: add one in \(inputSourcesHint).")
            return lines
        }
        var pair = pairLine(layouts)
        if layouts.english != nil && layouts.locals.count > 1 {
            pair += " (English goes to whichever of \(layouts.locals.map(\.name).joined(separator: ", ")) you used last)"
        }
        lines.append(pair)
        let languages = Set(layouts.layouts.map(\.language))
        let missing = languages.filter { !speller.supports($0) }.sorted()
        if !missing.isEmpty {
            lines.append("Fix-while-typing has no macOS dictionary for \(missing.joined(separator: ", ")): "
                + "words typed there are fixed only when they should be English; the hotkeys work for everything.")
        }
        return lines
    }
}
