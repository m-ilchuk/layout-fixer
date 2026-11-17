import Foundation

/// A semantic version ("1.4.2", or a release tag "v1.4.2"), compared part by part: 1.10.0 is newer than 1.9.3.
/// A pre-release suffix ("1.5.0-beta.1") is ignored; GitHub's "latest release" never is one.
struct Version: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ text: String) {
        var core = text.trimmingCharacters(in: .whitespaces)
        if core.hasPrefix("v") || core.hasPrefix("V") { core.removeFirst() }
        core = String(core.prefix { $0 != "-" && $0 != "+" })
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(parts.count), parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        let numbers = parts.map { $0! } + Array(repeating: 0, count: 3 - parts.count)
        (major, minor, patch) = (numbers[0], numbers[1], numbers[2])
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: Version, rhs: Version) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
