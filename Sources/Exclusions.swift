import Foundation

/// Words fix-while-typing leaves as typed: learned from undos (a word whose automatic fix was undone 3 times) or
/// added by the person. Each is the word as typed, in the language of the layout it was typed on ("csv" on
/// English, never "сім"). The person's own words: only the exclusions themselves are saved (in the app's
/// preferences); words still being counted stay in memory, so a word undone once or twice never reaches disk.
/// Never logged or sent.
struct Exclusions: Codable, Equatable {
    enum Origin: String, Codable { case learned, added }

    struct Entry: Codable, Equatable {
        /// Lowercased, without punctuation at its ends ("CSV," is "csv").
        let word: String
        /// The language of the layout it's typed on ("en", "uk"): ABC and U.S. type the same.
        let language: String
        var origin: Origin
        /// Undos of its automatic fix, counted until it's learned.
        var undos: Int
        var lastUndo: Date?
        /// When it became an exclusion (learned or added); nil while it's still being counted.
        var since: Date?

        var isExcluded: Bool { origin == .added || undos >= Exclusions.undosToLearn }
    }

    static let undosToLearn = 3
    /// Undos counted for a word that isn't excluded yet are forgotten after this long without another.
    static let forgetAfterDays = 30
    /// At most this many words are being counted; the oldest go first.
    static let maxCounted = 200
    static let defaultsKey = "exclusions"

    private(set) var entries: [Entry] = []
    private enum CodingKeys: String, CodingKey { case entries }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        entries = try values.decodeIfPresent([Entry].self, forKey: .entries) ?? []
    }

    /// Saves the exclusions only, never the words still being counted.
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(entries.filter(\.isExcluded), forKey: .entries)
    }

    /// The exclusions themselves, newest first (what the window lists).
    var excluded: [Entry] {
        entries.filter(\.isExcluded).sorted { ($0.since ?? .distantPast) > ($1.since ?? .distantPast) }
    }

    static func normalized(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: AutoFix.wordEdgePunctuation)
    }

    func contains(_ word: String, language: String) -> Bool {
        let key = Exclusions.normalized(word)
        return entries.contains { $0.word == key && $0.language == language && $0.isExcluded }
    }

    /// The automatic fix of `word` (typed on a `language` layout) was undone. True when this undo made it an exclusion.
    @discardableResult
    mutating func noteUndo(_ word: String, language: String, at now: Date) -> Bool {
        forgetOld(now: now)
        let key = Exclusions.normalized(word)
        guard !key.isEmpty else { return false }
        guard let index = entries.firstIndex(where: { $0.word == key && $0.language == language }) else {
            entries.append(Entry(word: key, language: language, origin: .learned, undos: 1, lastUndo: now))
            dropOldestCounted()
            return false
        }
        guard !entries[index].isExcluded else { return false }
        entries[index].undos += 1
        entries[index].lastUndo = now
        guard entries[index].isExcluded else { return false }
        entries[index].since = now
        return true
    }

    /// An undo taken back right away (right ⌥ tapped again): it doesn't count, and a word it just taught is
    /// learned no longer.
    mutating func takeBackUndo(_ word: String, language: String) {
        let key = Exclusions.normalized(word)
        guard let index = entries.firstIndex(where: { $0.word == key && $0.language == language }),
              entries[index].origin == .learned
        else { return }
        entries[index].undos -= 1
        if entries[index].undos < Exclusions.undosToLearn { entries[index].since = nil }
        if entries[index].undos <= 0 { entries.remove(at: index) }
    }

    /// Learn from what the typing session reports. Only an undo of a one-word fix of 3 keys or more teaches: when
    /// ⌘Z undid several words at once, any of them may be the one objected to, and a fixed short word ("yf" →
    /// "на") is better left to the short-word rules. Returns the word when this made it an exclusion.
    mutating func learn(from event: TypingSession.Event, layouts: LayoutSet, at now: Date) -> String? {
        switch event {
        case .undone(let typed, let layoutID):
            guard typed.count == 1, let word = typed.first, word.count >= AutoFix.minimumLength,
                  let language = layouts.layout(id: layoutID)?.language
            else { return nil }
            return noteUndo(word, language: language, at: now) ? Exclusions.normalized(word) : nil
        case .restored(let typed, let layoutID):
            guard typed.count == 1, let word = typed.first, let language = layouts.layout(id: layoutID)?.language
            else { return nil }
            takeBackUndo(word, language: language)
            return nil
        case .autoFixed, .converted:
            return nil
        }
    }

    /// What the word would have been changed to (the window's "Not changed to"): its keys on the other layout.
    /// Nil when no layout on now types its language.
    static func otherReading(of entry: Entry, layouts: LayoutSet) -> String? {
        let sources = layouts.layouts.filter { $0.language == entry.language }
        guard let source = sources.first(where: { $0.id == layouts.local?.id }) ?? sources.first,
              let target = layouts.other(than: source.id)
        else { return nil }
        return entry.word.map { char in
            source.strokeForCharacter[char].flatMap { target.character(for: $0) } ?? String(char)
        }.joined()
    }

    mutating func add(_ word: String, language: String, at now: Date) {
        let key = Exclusions.normalized(word)
        guard !key.isEmpty else { return }
        entries.removeAll { $0.word == key && $0.language == language }
        entries.append(Entry(word: key, language: language, origin: .added, undos: 0, lastUndo: nil, since: now))
    }

    /// Removes it from the list and forgets its undos: the next fixes start counting again.
    mutating func remove(_ word: String, language: String) {
        entries.removeAll { $0.word == word && $0.language == language }
    }

    /// Words still being counted whose last undo is over `forgetAfterDays` old.
    mutating func forgetOld(now: Date) {
        let cutoff = now.addingTimeInterval(-Double(Exclusions.forgetAfterDays) * 24 * 3600)
        entries.removeAll { !$0.isExcluded && ($0.lastUndo ?? .distantPast) < cutoff }
    }

    private mutating func dropOldestCounted() {
        let counted = entries.filter { !$0.isExcluded }
        guard counted.count > Exclusions.maxCounted,
              let oldest = counted.min(by: { ($0.lastUndo ?? .distantPast) < ($1.lastUndo ?? .distantPast) })
        else { return }
        entries.removeAll { $0 == oldest }
    }

    /// The list saved under `defaultsKey`, words counted too long ago forgotten; an empty one when there's none
    /// or it can't be read (then dropped: it may hold words, and nothing reads a copy kept aside).
    static func load(from defaults: UserDefaults, now: Date, log: (String) -> Void = { _ in }) -> Exclusions {
        guard let data = defaults.data(forKey: defaultsKey) else { return Exclusions() }
        guard var saved = try? JSONDecoder().decode(Exclusions.self, from: data) else {
            log("the saved exclusions couldn't be read; starting with none")
            defaults.removeObject(forKey: defaultsKey)
            return Exclusions()
        }
        saved.forgetOld(now: now)
        return saved
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Exclusions.defaultsKey)
    }
}
