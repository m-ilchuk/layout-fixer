import Foundation

/// While the app types a fix (backspaces, then the new text), keys the person presses are held back and handled
/// afterwards, in order: let through, they'd land between the backspaces and the retyped text. Handling a held
/// key can start another fix (a Space finishing the next word); the rest then wait for that one.
final class HeldKeys<Key> {
    /// More than this many keys during one fix: something is stuck, so keys go through rather than vanish.
    static var limit: Int { 200 }

    private(set) var replaying = false
    private var held: [Key] = []

    var count: Int { held.count }

    func begin() { replaying = true }

    /// Holds `key` while a fix is being typed. False when it should go through now.
    func hold(_ key: Key) -> Bool {
        guard replaying, held.count < HeldKeys.limit else { return false }
        held.append(key)
        return true
    }

    /// The fix is typed: hand over the held keys one by one, stopping when one of them starts another fix.
    func end(handle: (Key) -> Void) {
        replaying = false
        while !replaying, !held.isEmpty { handle(held.removeFirst()) }
    }
}
