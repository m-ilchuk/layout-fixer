import Carbon
import Foundation

/// One physical key press: the key's code plus the Carbon modifier bits that change the character
/// (shift, caps lock, option). The same stroke gives "g" on ABC and "п" on Ukrainian-PC.
struct KeyStroke: Hashable {
    let keyCode: UInt16
    let modifiers: UInt32

    static let shift = UInt32(shiftKey)
    static let capsLock = UInt32(alphaLock)
    static let option = UInt32(optionKey)
}

/// A keyboard layout macOS has enabled (ABC, Ukrainian-PC, ...), read from the system itself,
/// so the conversion always matches what the keys really type on this Mac.
final class KeyLayout {
    /// Main block keys only (letters, digits, punctuation, space, backtick, the ISO § key).
    static let mainBlockKeyCodes: ClosedRange<UInt16> = 0...50

    let id: String
    let name: String
    let language: String
    let source: TISInputSource
    private let layoutData: Data
    private(set) var strokeForCharacter: [Character: KeyStroke] = [:]

    init?(source: TISInputSource) {
        guard let id: String = KeyLayout.property(source, kTISPropertyInputSourceID),
              let data: Data = KeyLayout.property(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        self.id = id
        self.name = KeyLayout.property(source, kTISPropertyLocalizedName) ?? id
        let languages: [String] = KeyLayout.property(source, kTISPropertyInputSourceLanguages) ?? []
        self.language = languages.first ?? ""
        self.source = source
        self.layoutData = data
        buildReverseMap()
    }

    /// The text this stroke types on this layout, or nil for dead/control keys.
    func character(for stroke: KeyStroke) -> String? {
        layoutData.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 8)
            let status = UCKeyTranslate(
                base.assumingMemoryBound(to: UCKeyboardLayout.self),
                stroke.keyCode,
                UInt16(kUCKeyActionDown),
                (stroke.modifiers >> 8) & 0xFF,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
            guard status == noErr, length > 0 else { return nil }
            let text = String(utf16CodeUnits: chars, count: length)
            let isControl = text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
            return isControl ? nil : text
        }
    }

    func select() {
        TISSelectInputSource(source)
    }

    /// Keyboard layouts the user can switch to right now (System Settings > Keyboard > Input Sources).
    static func enabledLayouts() -> [KeyLayout] {
        list(includeAllInstalled: false, selectableOnly: true)
    }

    /// Any layouts macOS ships, enabled or not, by ID ("com.apple.keylayout.Russian"); for tests.
    static func installed(ids: [String]) -> [KeyLayout] {
        let all = list(includeAllInstalled: true, selectableOnly: false)
        return ids.compactMap { id in all.first { $0.id == id } }
    }

    private static func list(includeAllInstalled: Bool, selectableOnly: Bool) -> [KeyLayout] {
        let filter = NSMutableDictionary(dictionary: [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String])
        if selectableOnly { filter[kTISPropertyInputSourceIsSelectCapable as String] = true }
        guard let list = TISCreateInputSourceList(filter as CFDictionary, includeAllInstalled)?.takeRetainedValue()
                as? [TISInputSource]
        else { return [] }
        return list.compactMap(KeyLayout.init(source:))
    }

    static func currentLayoutID() -> String? {
        let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        return property(source, kTISPropertyInputSourceID)
    }

    /// Plain first, then ⇧, ⌥, ⇧⌥: a character some key types without ⌥ maps to that key ("!" is ⇧1, not ⌥1).
    static let reverseMapModifiers = [0, KeyStroke.shift, KeyStroke.option, KeyStroke.shift | KeyStroke.option]

    private func buildReverseMap() {
        for modifiers in KeyLayout.reverseMapModifiers {
            for keyCode in KeyLayout.mainBlockKeyCodes {
                let stroke = KeyStroke(keyCode: keyCode, modifiers: modifiers)
                guard let text = character(for: stroke), text.count == 1, let char = text.first else { continue }
                if strokeForCharacter[char] == nil { strokeForCharacter[char] = stroke }
            }
        }
    }

    private static func property<T>(_ source: TISInputSource, _ key: CFString) -> T? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? T
    }
}

/// The layouts the fixer flips between: English and your local layout (Ukrainian, Russian, Greek, German, ...).
/// Text typed on any local layout goes to English; text typed on English goes to the local layout you used last.
struct LayoutSet {
    static let englishLanguage = "en"

    let layouts: [KeyLayout]
    /// The local layout English flips to when several are enabled: the one you used last.
    var preferredLocalID: String?

    init(layouts: [KeyLayout], preferredLocalID: String? = nil) {
        self.layouts = layouts
        self.preferredLocalID = preferredLocalID
    }

    var english: KeyLayout? { layouts.first { $0.language == LayoutSet.englishLanguage } }
    var locals: [KeyLayout] { layouts.filter { $0.language != LayoutSet.englishLanguage } }
    var local: KeyLayout? { locals.first { $0.id == preferredLocalID } ?? locals.first }

    /// What the app switches between, e.g. "ABC ↔ Ukrainian-PC"; nil when there is nothing to switch.
    var pairDescription: String? {
        guard let english, let local else { return nil }
        return "\(english.name) ↔ \(local.name)"
    }

    func layout(id: String) -> KeyLayout? {
        layouts.first { $0.id == id }
    }

    func other(than id: String) -> KeyLayout? {
        guard let current = layout(id: id) else { return nil }
        if let english, let local {
            return current.language == LayoutSet.englishLanguage ? local : english
        }
        // No English layout enabled (say Ukrainian + Russian): flip to the other language.
        return layouts.first { $0.id != id && $0.language != current.language }
    }
}
