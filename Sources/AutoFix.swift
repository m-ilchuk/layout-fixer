import AppKit

/// Asks the macOS spell checker about one word in one language ("en", "uk").
protocol Speller {
    /// Is there a dictionary for this language? Without one, words in it are never called valid.
    func supports(_ language: String) -> Bool
    func isValid(_ word: String, language: String) -> Bool
    func correction(for word: String, language: String) -> String?
}

struct SystemSpeller: Speller {
    func supports(_ language: String) -> Bool { dictionary(for: language) != nil }

    func isValid(_ word: String, language: String) -> Bool {
        guard let dictionary = dictionary(for: language) else { return false }
        return NSSpellChecker.shared.checkSpelling(
            of: word, startingAt: 0, language: dictionary, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil
        ).location == NSNotFound
    }

    func correction(for word: String, language: String) -> String? {
        guard let dictionary = dictionary(for: language) else { return nil }
        let range = NSRange(location: 0, length: (word as NSString).length)
        return NSSpellChecker.shared.correction(
            forWordRange: range, in: word, language: dictionary, inSpellDocumentWithTag: 0
        )
    }

    /// "uk" → "uk", "pt" → "pt_BR": the macOS dictionary for a layout's language, if there is one.
    private func dictionary(for language: String) -> String? {
        let available = NSSpellChecker.shared.availableLanguages
        return available.first { $0 == language } ?? available.first { $0.hasPrefix(language + "_") }
    }
}

/// Punto-style fixing while you type. When a finished word belongs to the other layout, it is retyped there,
/// and so are the words just before it typed in the same wrong layout, so "рун умукщту рщц" becomes
/// "hey everone how" and not "рун умукщту how".
enum AutoFix {
    static let minimumLength = 3
    /// A spell-checker correction this close counts as a typo of a real word ("everone" → "everyone").
    static let maximumTypoDistance = 2

    /// The range of `buffer` to retype on `target`, or nil to leave it. `buffer` ends with the finished word.
    static func fix(buffer: [Typed], layouts: LayoutSet, speller: Speller = SystemSpeller())
        -> (range: Range<Int>, target: KeyLayout)? {
        let words = wordRanges(in: buffer)
        guard let last = words.last, last.upperBound == buffer.count,
              let (source, target) = layoutsOf(buffer[last], layouts: layouts),
              buffer[last].count >= minimumLength,
              shouldFlip(buffer[last], from: source, to: target, speller: speller)
        else { return nil }

        // Walk back over the words before it typed in the same layout; stop at the first that belongs there.
        // Without a dictionary for the source language nothing can be said to belong, so fix only this word.
        var start = last.lowerBound
        let canJudgeEarlierWords = speller.supports(source.language) && speller.supports(target.language)
        for word in words.dropLast().reversed() where canJudgeEarlierWords {
            guard let (wordSource, _) = layoutsOf(buffer[word], layouts: layouts), wordSource.id == source.id,
                  !belongsToSource(buffer[word], source: source, target: target, speller: speller)
            else { break }
            start = word.lowerBound
        }
        return (start..<buffer.count, target)
    }

    /// The finished word on its own: it reads as a word (or a typo of one) only on the other layout.
    static func shouldFlip(_ word: ArraySlice<Typed>, from source: KeyLayout, to target: KeyLayout,
                           speller: Speller) -> Bool {
        let typed = word.map(\.text).joined()
        let fixed = Converter.retype(word, on: target).map(\.text).joined()
        guard looksLikeWord(fixed), !readsAsWord(typed, language: source.language, speller: speller) else { return false }
        if speller.isValid(fixed, language: target.language) { return true }
        // Typo: the other language knows a close word, and this language has nothing close to offer.
        return word.count > minimumLength
            && closeCorrection(fixed, language: target.language, speller: speller)
            && !closeCorrection(typed, language: source.language, speller: speller)
    }

    /// A word before the fixed one stays only if it reads right where it was typed and wrong on the other
    /// layout ("люблю" stays, "рун" = "hey" follows the phrase, "умукщту" = "everone" flips).
    private static func belongsToSource(_ word: ArraySlice<Typed>, source: KeyLayout, target: KeyLayout,
                                        speller: Speller) -> Bool {
        let typed = word.map(\.text).joined()
        let fixed = Converter.retype(word, on: target).map(\.text).joined()
        let readsAsSource = looksLikeWord(typed)
            && (speller.isValid(typed, language: source.language)
                || closeCorrection(typed, language: source.language, speller: speller))
        let readsAsTarget = looksLikeWord(fixed)
            && (speller.isValid(fixed, language: target.language)
                || closeCorrection(fixed, language: target.language, speller: speller))
        return readsAsSource && !readsAsTarget
    }

    /// A real word as typed. The spell checker skips punctuation, so "k.,k." ("люблю" typed on English) would pass
    /// as two k's: a word with punctuation inside it isn't one.
    private static func readsAsWord(_ word: String, language: String, speller: Speller) -> Bool {
        looksLikeWord(word) && speller.isValid(word, language: language)
    }

    private static func closeCorrection(_ word: String, language: String, speller: Speller) -> Bool {
        guard let correction = speller.correction(for: word, language: language) else { return false }
        return editDistance(word.lowercased(), correction.lowercased()) <= maximumTypoDistance
    }

    /// The words of the buffer (runs between spaces), as index ranges.
    static func wordRanges(in buffer: [Typed]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start: Int?
        for (index, typed) in buffer.enumerated() {
            if typed.isSpace {
                if let begin = start { ranges.append(begin..<index); start = nil }
            } else if start == nil {
                start = index
            }
        }
        if let begin = start { ranges.append(begin..<buffer.count) }
        return ranges
    }

    private static func layoutsOf(_ word: ArraySlice<Typed>, layouts: LayoutSet) -> (KeyLayout, KeyLayout)? {
        guard let id = word.first?.layoutID, word.allSatisfy({ $0.layoutID == id }),
              let source = layouts.layout(id: id), let target = layouts.other(than: id)
        else { return nil }
        return (source, target)
    }

    /// Letters, with punctuation only at the ends or an apostrophe/hyphen inside ("it's", "hey,"): no digits, no code.
    private static func looksLikeWord(_ text: String) -> Bool {
        let core = text.trimmingCharacters(in: .punctuationCharacters)
        let allowed = CharacterSet.letters.union(CharacterSet(charactersIn: "'’-"))
        return !core.isEmpty && core.unicodeScalars.allSatisfy(allowed.contains)
            && core.first?.isLetter == true && core.last?.isLetter == true
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1,
                                 previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
