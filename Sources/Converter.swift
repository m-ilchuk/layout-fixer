import Foundation

/// One character the user typed, remembered as the key they pressed and the layout that was on.
struct Typed {
    let stroke: KeyStroke
    let layoutID: String
    let text: String

    var isSpace: Bool { text == " " }
}

enum Converter {
    /// The part of the buffer to fix: the last word (with any spaces after it), or the whole phrase
    /// typed since the last click, Enter or arrow key.
    static func segment(of buffer: [Typed], wholePhrase: Bool) -> Range<Int>? {
        var index = buffer.count - 1
        while index >= 0 && buffer[index].isSpace { index -= 1 }
        guard index >= 0 else { return nil }
        if wholePhrase {
            let start = buffer.firstIndex { !$0.isSpace } ?? 0
            return start..<buffer.count
        }
        while index >= 0 && !buffer[index].isSpace { index -= 1 }
        return (index + 1)..<buffer.count
    }

    /// The layout the segment should have been typed in: the other one from its last word's layout.
    static func target(for segment: ArraySlice<Typed>, in layouts: LayoutSet) -> KeyLayout? {
        guard let typedIn = segment.last(where: { !$0.isSpace })?.layoutID else { return nil }
        return layouts.other(than: typedIn)
    }

    /// The same key presses, replayed on the target layout. Spaces stay spaces.
    static func retype(_ segment: ArraySlice<Typed>, on target: KeyLayout) -> [Typed] {
        segment.map { typed in
            if typed.isSpace || typed.layoutID == target.id { return typed }
            let text = keepPunctuation(typed.text, target.character(for: typed.stroke))
            return Typed(stroke: typed.stroke, layoutID: target.id, text: text)
        }
    }

    /// A key that is punctuation on both layouts (Ukrainian "," vs ABC "?") keeps what you saw;
    /// a key that is a letter on either side (ABC "," vs Ukrainian "б") converts.
    static func keepPunctuation(_ original: String, _ converted: String?) -> String {
        guard let converted else { return original }
        let isLetter = { (text: String) in text.first?.isLetter == true }
        return isLetter(original) || isLetter(converted) ? converted : original
    }

    /// For selected text (no key presses to replay): guess the layout it was typed in from its
    /// characters, then map each character to the key that types it and back out on the other layout.
    static func convert(text: String, layouts: LayoutSet) -> (text: String, target: KeyLayout)? {
        guard let source = typedLayout(of: text, layouts: layouts),
              let target = layouts.other(than: source.id)
        else { return nil }
        let converted = text.map { char -> String in
            guard let stroke = source.strokeForCharacter[char] else { return String(char) }
            return keepPunctuation(String(char), target.character(for: stroke))
        }.joined()
        return (converted, target)
    }

    /// The layout whose own characters (ones the other layouts lack, like Cyrillic letters) the text uses most.
    static func typedLayout(of text: String, layouts: LayoutSet) -> KeyLayout? {
        let scored = layouts.layouts.map { layout -> (KeyLayout, Int) in
            let others = layouts.layouts.filter { $0.id != layout.id }
            let own = text.filter { char in
                layout.strokeForCharacter[char] != nil && others.allSatisfy { $0.strokeForCharacter[char] == nil }
            }
            return (layout, own.count)
        }.sorted { $0.1 > $1.1 }
        guard let best = scored.first, best.1 > 0 else { return nil }
        if scored.count > 1 && scored[1].1 == best.1 { return nil }
        return best.0
    }
}
