import AppKit

/// Asks the macOS spell checker about one word in one language ("en", "uk").
protocol Speller {
    /// Is there a dictionary for this language? Without one, words in it are never called valid.
    func supports(_ language: String) -> Bool
    func isValid(_ word: String, language: String) -> Bool
    func correction(for word: String, language: String) -> String?
    /// The spell checker's suggestions, best first. Its `correction` is often nil where these aren't ("тікет":
    /// no correction, but "пікет" is the first guess).
    func guesses(for word: String, language: String) -> [String]
}

extension Speller {
    func guesses(for word: String, language: String) -> [String] {
        correction(for: word, language: language).map { [$0] } ?? []
    }
}

/// Answers remembered by key: the spell checker takes up to ~9 ms for a correction or guesses, on every Space,
/// for the same words again and again. Forgets everything past `limit` answers.
final class Memo<Value> {
    static var limit: Int { 4000 }
    private let lock = NSLock()
    private var values: [String: Value] = [:]
    /// How many answers were worked out rather than remembered (for the tests).
    private(set) var computed = 0

    func value(_ key: String, _ compute: () -> Value) -> Value {
        if let known = lock.withLock({ values[key] }) { return known }
        let value = compute()
        lock.withLock {
            if values.count >= Memo.limit { values.removeAll() }
            values[key] = value
            computed += 1
        }
        return value
    }

    func clear() { lock.withLock { values.removeAll() } }
}

struct SystemSpeller: Speller {
    private static let dictionaries = Memo<String?>()
    private static let validity = Memo<Bool>()
    private static let corrections = Memo<String?>()
    private static let guessLists = Memo<[String]>()

    /// Forget remembered answers (the layouts or the spell checker's settings may have changed).
    static func forget() {
        dictionaries.clear(); validity.clear(); corrections.clear(); guessLists.clear()
    }

    func supports(_ language: String) -> Bool { dictionary(for: language) != nil }

    func isValid(_ word: String, language: String) -> Bool {
        guard let dictionary = dictionary(for: language) else { return false }
        return SystemSpeller.validity.value(Self.key(word, dictionary)) {
            NSSpellChecker.shared.checkSpelling(
                of: word, startingAt: 0, language: dictionary, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil
            ).location == NSNotFound
        }
    }

    func correction(for word: String, language: String) -> String? {
        guard let dictionary = dictionary(for: language) else { return nil }
        return SystemSpeller.corrections.value(Self.key(word, dictionary)) {
            let range = NSRange(location: 0, length: (word as NSString).length)
            return NSSpellChecker.shared.correction(
                forWordRange: range, in: word, language: dictionary, inSpellDocumentWithTag: 0
            )
        }
    }

    func guesses(for word: String, language: String) -> [String] {
        guard let dictionary = dictionary(for: language) else { return [] }
        return SystemSpeller.guessLists.value(Self.key(word, dictionary)) {
            let range = NSRange(location: 0, length: (word as NSString).length)
            return NSSpellChecker.shared.guesses(
                forWordRange: range, in: word, language: dictionary, inSpellDocumentWithTag: 0
            ) ?? []
        }
    }

    /// "uk" → "uk", "pt" → "pt_BR": the macOS dictionary for a layout's language, if there is one.
    private func dictionary(for language: String) -> String? {
        SystemSpeller.dictionaries.value(language) {
            let available = NSSpellChecker.shared.availableLanguages
            return available.first { $0 == language } ?? available.first { $0.hasPrefix(language + "_") }
        }
    }

    private static func key(_ word: String, _ dictionary: String) -> String { dictionary + "\u{1}" + word }
}

/// Punto-style fixing while you type. When a finished word belongs to the other layout, it is retyped there,
/// and so are the words just before it typed in the same wrong layout, so "рун умукщту рщц" becomes
/// "hey everone how" and not "рун умукщту how".
enum AutoFix {
    static let minimumLength = 3
    /// How many of the spell checker's guesses count when asking whether typed text is a typo where it was typed.
    static let guessesConsidered = 3
    /// Punctuation a word can start or end with in a sentence. Brackets, slashes and the like can't: those turn up
    /// when letter keys are read on the other layout ("Хмм..." → "{vv///"), and around them is code, not a word.
    static let wordEdgePunctuation = CharacterSet(charactersIn: ".,!?:;'\"()«»„“”‘’-–—…*_@#¿¡")
    /// How far a spell-checker correction may be to count as a typo of a real word ("everone" → "everyone"):
    /// none for short words, where nearly anything is that close to some word ("lkz" → "lap").
    static func maximumTypoDistance(forLength length: Int) -> Int {
        length >= 8 ? 2 : length >= 5 ? 1 : 0
    }

    /// The range of `buffer` to retype on `target`, or nil to leave it. `buffer` ends with the finished word.
    /// Why a word was left as typed; the log shows it (never the word itself).
    enum Skip: String {
        case noWord = "no word typed before the space since the memory was last cleared"
        case mixedLayouts = "the word was typed on more than one layout"
        case noOtherLayout = "no other layout to switch to"
        case tooShort = "shorter than 3 keys"
        case notAWordThere = "it would not look like a word on the other layout"
        case realWordHere = "it reads as a real word where it was typed"
        case notAWordOnOtherLayout = "it isn't a word on the other layout either"
        case excluded = "it's on your exclusions list"
    }

    enum Decision {
        case fix(range: Range<Int>, target: KeyLayout)
        /// The finished word stays, but the short words just before it go to `target` ("Z yf call" → "Я на call").
        case fixShortWords(range: Range<Int>, target: KeyLayout)
        case skip(Skip)
    }

    /// Whether a word, as typed on a layout of the given language, is one the person wants left as typed.
    typealias IsExcluded = (_ word: String, _ language: String) -> Bool
    static let noExclusions: IsExcluded = { _, _ in false }

    /// The range of `buffer` to retype on `target`, or nil to leave it. `buffer` ends with the finished word.
    static func fix(buffer: [Typed], layouts: LayoutSet, speller: Speller = SystemSpeller(),
                    isExcluded: IsExcluded = noExclusions) -> (range: Range<Int>, target: KeyLayout)? {
        if case .fix(let range, let target) = decide(buffer: buffer, layouts: layouts, speller: speller,
                                                     isExcluded: isExcluded) {
            return (range, target)
        }
        return nil
    }

    static func decide(buffer: [Typed], layouts: LayoutSet, speller: Speller = SystemSpeller(),
                       isExcluded: IsExcluded = noExclusions) -> Decision {
        let words = wordRanges(in: buffer)
        guard let last = words.last, last.upperBound == buffer.count else { return .skip(.noWord) }
        guard let id = buffer[last].first?.layoutID, buffer[last].allSatisfy({ $0.layoutID == id })
        else { return .skip(.mixedLayouts) }
        guard let (source, target) = layoutsOf(buffer[last], layouts: layouts) else { return .skip(.noOtherLayout) }
        guard buffer[last].count >= minimumLength else { return .skip(.tooShort) }
        let excluded = isExcluded(text(of: buffer[last]), source.language)
        if let reason = excluded ? .excluded : skipReason(buffer[last], from: source, to: target, speller: speller) {
            if let run = shortWordsToFix(before: words.dropLast(), in: buffer, layouts: layouts, speller: speller,
                                         isExcluded: isExcluded) {
                return .fixShortWords(range: run.range, target: run.target)
            }
            return .skip(reason)
        }

        // Walk back over the words before it typed in the same layout; stop at the first that belongs there.
        // Without a dictionary for the source language nothing can be said to belong, so fix only this word.
        // A short word is judged on its own: "Z" isn't English but "Я" is Ukrainian, so it goes ("Z просто" →
        // "Я просто"); "з" is Ukrainian, so it stays ("синхронізацію з Constant"). One the two languages can't tell
        // apart goes along only when a longer word before it goes too.
        var start = last.lowerBound
        let canJudgeEarlierWords = speller.supports(source.language) && speller.supports(target.language)
        for word in words.dropLast().reversed() where canJudgeEarlierWords {
            guard let (wordSource, _) = layoutsOf(buffer[word], layouts: layouts), wordSource.id == source.id
            else { break }
            if isExcluded(text(of: buffer[word]), source.language) { break }
            if buffer[word].count < minimumLength {
                let typed = buffer[word].map(\.text).joined()
                let fixed = Converter.retype(buffer[word], on: target).map(\.text).joined()
                if readsAsShortWord(typed, language: source.language, speller: speller) { break }
                if !isPunctuationOnly(typed) && readsAsShortWord(fixed, language: target.language, speller: speller) {
                    start = word.lowerBound
                }
                continue
            }
            // Only a word that reads on the other layout goes along: a name no dictionary knows ("Jira") stays.
            guard readsOnTarget(buffer[word], source: source, target: target, speller: speller) else { break }
            start = word.lowerBound  // takes the short words between this word and the fixed one along
        }
        return .fix(range: start..<buffer.count, target: target)
    }

    /// The finished word on its own: it reads as a word (or a typo of one) only on the other layout.
    /// Nil when the finished word should go to the other layout; otherwise why not.
    static func skipReason(_ word: ArraySlice<Typed>, from source: KeyLayout, to target: KeyLayout,
                           speller: Speller) -> Skip? {
        let typed = word.map(\.text).joined()
        let fixed = Converter.retype(word, on: target).map(\.text).joined()
        guard looksLikeWord(fixed) else { return .notAWordThere }
        let typedIsWord = !hasLetterKeys(word, on: target) && readsAsWord(typed, language: source.language, speller: speller)
        guard !typedIsWord else { return .realWordHere }
        if speller.isValid(fixed, language: target.language) { return nil }
        // Typo: the other language knows a close word, and this language has nothing close to offer. Not when
        // the spell checker takes the typed text as it is ("it's"): then only a real word on the other layout counts.
        // Close on both sides ("тікет" is one letter from "пікет", "nsrtn" one from "nsrtf"), it stays as typed.
        let typo = word.count > minimumLength
            && !speller.isValid(typed, language: source.language)
            && closeCorrection(fixed, language: target.language, speller: speller)
            && !nearAWord(typed, language: source.language, speller: speller)
        return typo ? nil : .notAWordOnOtherLayout
    }

    /// A word before the fixed one goes along when it reads on the other layout, also when it reads where it
    /// was typed too ("рун" = "hey" follows the phrase; "умукщту" = "everone", a typo, flips). One that reads only
    /// where it was typed ("люблю"), or nowhere (a name like "Jira"), stays and ends the look back.
    private static func readsOnTarget(_ word: ArraySlice<Typed>, source: KeyLayout, target: KeyLayout,
                                      speller: Speller) -> Bool {
        let fixed = Converter.retype(word, on: target).map(\.text).joined()
        guard looksLikeWord(fixed) else { return false }
        if speller.isValid(fixed, language: target.language) { return true }
        // A near miss on the other side isn't enough to undo a real word ("для" must not become "lkz").
        let typed = word.map(\.text).joined()
        let typedIsWord = !hasLetterKeys(word, on: target) && readsAsWord(typed, language: source.language, speller: speller)
        return !typedIsWord && closeCorrection(fixed, language: target.language, speller: speller)
            && !nearAWord(typed, language: source.language, speller: speller)
    }

    /// When the finished word stays, the short words right before it, if each is a word only on the other layout:
    /// two or more of them, or one at the start of what was typed ("Z yf call" → "Я на call"). A lone short word
    /// mid-text stays (an "f" or "e" in a technical message).
    private static func shortWordsToFix(before words: ArraySlice<Range<Int>>, in buffer: [Typed], layouts: LayoutSet,
                                        speller: Speller, isExcluded: IsExcluded)
        -> (range: Range<Int>, target: KeyLayout)? {
        var run: [Range<Int>] = []
        for word in words.reversed() {
            guard buffer[word].count < minimumLength else { break }
            run.insert(word, at: 0)
        }
        guard let first = run.first, let last = run.last,
              let (source, target) = layoutsOf(buffer[first.lowerBound..<last.upperBound].filter { !$0.isSpace }[...],
                                               layouts: layouts),
              run.count >= 2 || words.first == first
                || mostlyOn(target, before: first.lowerBound, in: buffer, comparedWith: source)
        else { return nil }
        for word in run {
            let typed = buffer[word].map(\.text).joined()
            let fixed = Converter.retype(buffer[word], on: target).map(\.text).joined()
            guard !isPunctuationOnly(typed), !isExcluded(typed, source.language),
                  !readsAsShortWord(typed, language: source.language, speller: speller),
                  readsAsShortWord(fixed, language: target.language, speller: speller)
            else { return nil }
        }
        return (first.lowerBound..<last.upperBound, target)
    }

    /// Typed with keys that are punctuation here but letters on the other layout ("];fr" is "їжак"): then the
    /// spell checker's yes means little, since it skips the punctuation and sees only "fr".
    /// The text so far is mostly in `target`'s language: at least as many longer words on it as on `source`, and
    /// one or more ("Перевір, чи працює login yf mobile": a Ukrainian sentence with English terms).
    private static func mostlyOn(_ target: KeyLayout, before end: Int, in buffer: [Typed],
                                 comparedWith source: KeyLayout) -> Bool {
        let longWords = wordRanges(in: Array(buffer[..<end])).filter { $0.count >= minimumLength }
        let onTarget = longWords.filter { buffer[$0].first?.layoutID == target.id }.count
        let onSource = longWords.filter { buffer[$0].first?.layoutID == source.id }.count
        return onTarget >= 1 && onTarget >= onSource
    }

    private static func hasLetterKeys(_ word: ArraySlice<Typed>, on target: KeyLayout) -> Bool {
        // Punctuation at the end is just punctuation ("staging," is English even though "," is "б" in Ukrainian);
        // at the start or inside ("];fr", "k.,k.") it stands for letters.
        let body = word.reversed().drop { $0.text.first?.isLetter == false }.reversed()
        return body.contains { typed in
            typed.text.first?.isLetter == false && target.character(for: typed.stroke)?.first?.isLetter == true
        }
    }

    /// A real word as typed. The spell checker skips punctuation, so "k.,k." ("люблю" typed on English) would pass
    /// as two k's: a word with punctuation inside it isn't one.
    private static func readsAsWord(_ word: String, language: String, speller: Speller) -> Bool {
        looksLikeWord(word) && speller.isValid(word, language: language)
    }

    /// The real one- and two-letter words of the main languages. The spell checker takes almost any short string
    /// ("Z", "p", "wt", "Nb"), so it can't tell "Я" or "Це" (words) from "Z" or "Wt" (not).
    static let shortWords: [String: Set<String>] = [
        "en": ["a", "i", "ah", "am", "an", "as", "at", "be", "by", "do", "eh", "go", "ha", "he", "hi", "if", "in",
               "is", "it", "me", "my", "no", "of", "oh", "ok", "on", "or", "ox", "so", "to", "uh", "um", "up", "us",
               "we", "yo"],
        "uk": ["а", "в", "з", "і", "й", "о", "у", "я", "ж", "б", "ти", "ми", "ви", "на", "до", "за", "по", "та",
               "це", "ця", "ці", "як", "чи", "не", "ні", "її", "їх", "їм", "ще", "що", "же", "бо", "аж", "ну", "де",
               "то", "із", "зі", "об", "ой", "ох", "ах", "ей", "он", "от", "уж", "ба", "ну", "га", "ти", "мі", "ні"],
        "ru": ["а", "в", "и", "к", "о", "с", "у", "я", "ж", "б", "ты", "мы", "вы", "на", "до", "за", "по", "не", "ни", "но",
               "да", "же", "бы", "ли", "он", "от", "из", "со", "во", "об", "то", "её", "ее", "их", "им", "ей", "ой",
               "ну", "уж", "аж", "ах", "ох"],
    ]

    /// A one- or two-letter word that is a real word in `language`: from the lists above, or, for another language,
    /// the spell checker on the lowercase word.
    static func readsAsShortWord(_ word: String, language: String, speller: Speller) -> Bool {
        let core = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
        guard !core.isEmpty, core.allSatisfy(\.isLetter) else { return false }
        if let list = shortWords[language] { return list.contains(core) }
        return core.count > 1 && speller.isValid(core, language: language)
    }

    /// Typed with no letter at all (",", ";"): punctuation, not a short word on the wrong layout, though its keys
    /// are "б" and "ж" in Ukrainian. Typed after clicking behind a word ("consistent|" then ", you"), the memory
    /// starts at the comma, and it must stay a comma.
    private static func isPunctuationOnly(_ typed: String) -> Bool {
        !typed.contains(where: \.isLetter)
    }

    /// The other language knows a word close to this one: its correction is within a typo's distance, or one of
    /// its first guesses is the same word split in two ("webhook" → "web hook", "hotfix" → "hot fix").
    private static func closeCorrection(_ word: String, language: String, speller: Speller) -> Bool {
        if let correction = speller.correction(for: word, language: language) {
            let letters = word.filter(\.isLetter).count
            if editDistance(word.lowercased(), correction.lowercased()) <= maximumTypoDistance(forLength: letters) {
                return true
            }
        }
        let core = word.lowercased().trimmingCharacters(in: wordEdgePunctuation)
        return speller.guesses(for: word, language: language).prefix(guessesConsidered).contains { guess in
            let joined = guess.lowercased().filter { $0 != " " && $0 != "-" }
            return guess.contains(where: { $0 == " " || $0 == "-" }) && joined == core
        }
    }

    /// The typed text may be a typo where it was typed: its correction or one of the first guesses is within a
    /// typo's distance. Looser than `closeCorrection` on purpose: a doubt keeps the word as typed.
    private static func nearAWord(_ word: String, language: String, speller: Speller) -> Bool {
        guard looksLikeWord(word) else { return false }
        let letters = word.filter(\.isLetter).count
        let limit = maximumTypoDistance(forLength: letters)
        let candidates = [speller.correction(for: word, language: language)].compactMap { $0 }
            + speller.guesses(for: word, language: language).prefix(guessesConsidered)
        return candidates.contains { editDistance(word.lowercased(), $0.lowercased()) <= limit }
    }

    private static func text(of word: ArraySlice<Typed>) -> String { word.map(\.text).joined() }

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
    /// Only punctuation words really carry counts at the ends: "{vv///" (what "Хмм..." types on English) isn't a word.
    private static func looksLikeWord(_ text: String) -> Bool {
        let core = text.trimmingCharacters(in: wordEdgePunctuation)
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
