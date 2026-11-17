/// How a fixed word goes into the focused text field.
enum ReplaceMethod: Equatable {
    /// Select the word and set its text through Accessibility, in one step (native apps: Mail, Notes, TextEdit).
    case accessibility
    /// Backspaces, then the new text, as key presses.
    case keystrokes

    static let webAreaRole = "AXWebArea"

    /// `roles` are the Accessibility roles from the focused field up to its window. A field inside a web page
    /// (Gmail or any site in a browser, Slack and other Electron apps) gets keystrokes: browsers take
    /// Accessibility's "select this" and "set its text" late or not at all, and the word was left selected,
    /// unconverted. Nothing known about the field: keystrokes too, what worked before.
    static func forField(roles: [String]) -> ReplaceMethod {
        guard !roles.isEmpty, !roles.contains(webAreaRole) else { return .keystrokes }
        return .accessibility
    }
}
