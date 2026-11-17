import Foundation

/// The small part of Markdown that release notes use, so the update dialog can show them formatted instead of
/// as raw `**` and backticks: headings, "- " / "• " bullets, **bold** and `code`.
enum ReleaseNotes {
    struct Run: Equatable {
        let text: String
        var bold = false
        var code = false
    }

    struct Line: Equatable {
        enum Kind: Equatable { case heading, bullet, text, blank }
        let kind: Kind
        let runs: [Run]
    }

    static let bulletMarkers = ["- ", "* ", "• "]

    static func parse(_ markdown: String) -> [Line] {
        var lines: [Line] = []
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                // One blank line between blocks is enough.
                if let last = lines.last, last.kind != .blank { lines.append(Line(kind: .blank, runs: [])) }
            } else if line.hasPrefix("#") {
                let title = String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                lines.append(Line(kind: .heading, runs: runs(title.replacingOccurrences(of: "**", with: ""))))
            } else if let marker = bulletMarkers.first(where: line.hasPrefix) {
                lines.append(Line(kind: .bullet, runs: runs(String(line.dropFirst(marker.count)))))
            } else {
                lines.append(Line(kind: .text, runs: runs(line)))
            }
        }
        while lines.last?.kind == .blank { lines.removeLast() }
        while lines.first?.kind == .blank { lines.removeFirst() }
        return lines
    }

    /// Splits "a **b** `c`" into plain, bold and code runs. An unclosed marker is kept as text.
    static func runs(_ text: String) -> [Run] {
        var result: [Run] = []
        var current = ""
        var bold = false
        var code = false
        var rest = Substring(text)
        func flush() {
            if !current.isEmpty { result.append(Run(text: current, bold: bold, code: code)) }
            current = ""
        }
        while let char = rest.first {
            if !code && rest.hasPrefix("**") && (bold || rest.dropFirst(2).contains("**")) {
                flush()
                bold.toggle()
                rest = rest.dropFirst(2)
            } else if char == "`" && (code || rest.dropFirst().contains("`")) {
                flush()
                code.toggle()
                rest = rest.dropFirst()
            } else {
                current.append(char)
                rest = rest.dropFirst()
            }
        }
        flush()
        return result
    }
}
