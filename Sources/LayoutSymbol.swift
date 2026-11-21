/// The short name macOS shows for a layout in the menu bar and in its little indicator under the text cursor:
/// "A" for English, the language's own letters for others ("УК" for Ukrainian). Drawn by Layout Fixer the same
/// way, a filled rounded square with the letters cut out, since macOS doesn't hand these icons to other apps.
enum LayoutSymbol {
    /// Languages whose menu-bar name is in their own script; others show their code ("PL", "DE").
    static let nativeNames: [String: String] = [
        "uk": "УК", "ru": "РУ", "be": "БЕ", "bg": "БГ", "sr": "СР", "mk": "МК", "el": "ΕΛ", "he": "עב",
    ]

    static func name(forLanguage language: String) -> String {
        if language == LayoutSet.englishLanguage { return "A" }
        return nativeNames[language] ?? language.uppercased()
    }
}
