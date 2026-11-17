import AppKit

/// Release notes for the update dialog: headings and bold as bold, `code` monospaced, bullets as "•",
/// in a box that scrolls when the notes are long.
enum ReleaseNotesView {
    static let width: CGFloat = 400
    static let maxHeight: CGFloat = 260
    static let bodySize: CGFloat = 12

    static func make(_ markdown: String) -> NSView {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 4, height: 6)
        text.textStorage?.setAttributedString(attributed(ReleaseNotes.parse(markdown)))
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        let height = (text.layoutManager?.usedRect(for: text.textContainer!).height ?? 0) + 12

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: min(height, maxHeight)))
        scroll.hasVerticalScroller = height > maxHeight
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = text
        text.frame.size.height = height
        return scroll
    }

    static func attributed(_ lines: [ReleaseNotes.Line]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: bodySize)
        let bullet = NSMutableParagraphStyle()
        bullet.headIndent = 14
        bullet.tabStops = [NSTextTab(textAlignment: .left, location: 14)]
        bullet.paragraphSpacing = 3
        let plain = NSMutableParagraphStyle()
        plain.paragraphSpacing = 3

        for (index, line) in lines.enumerated() {
            let ending = index == lines.count - 1 ? "" : "\n"
            switch line.kind {
            case .blank:
                result.append(NSAttributedString(string: ending, attributes: [.font: NSFont.systemFont(ofSize: 5)]))
            case .heading:
                let heading = NSMutableAttributedString()
                for run in line.runs { heading.append(NSAttributedString(string: run.text)) }
                heading.append(NSAttributedString(string: ending))
                heading.addAttributes([.font: NSFont.systemFont(ofSize: bodySize + 1, weight: .semibold),
                                       .foregroundColor: NSColor.labelColor, .paragraphStyle: plain],
                                      range: NSRange(location: 0, length: heading.length))
                result.append(heading)
            case .bullet, .text:
                let style = line.kind == .bullet ? bullet : plain
                let paragraph = NSMutableAttributedString(string: line.kind == .bullet ? "•\t" : "",
                                                          attributes: [.font: body])
                for run in line.runs {
                    let font = run.code ? NSFont.monospacedSystemFont(ofSize: bodySize - 1, weight: .regular)
                        : run.bold ? NSFont.systemFont(ofSize: bodySize, weight: .semibold) : body
                    paragraph.append(NSAttributedString(string: run.text, attributes: [.font: font]))
                }
                paragraph.append(NSAttributedString(string: ending, attributes: [.font: body]))
                paragraph.addAttributes([.foregroundColor: NSColor.labelColor, .paragraphStyle: style],
                                        range: NSRange(location: 0, length: paragraph.length))
                result.append(paragraph)
            }
        }
        return result
    }
}
