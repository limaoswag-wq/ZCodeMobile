import UIKit

struct MarkdownSegment {
    enum Kind {
        case heading(Int)
        case paragraph
        case bullet
        case quote
        case code
        case mermaid
        case divider
        case table([[String]])
    }

    var kind: Kind
    var text: String
}

enum MarkdownRenderer {
    static func segments(from markdown: String) -> [MarkdownSegment] {
        var result: [MarkdownSegment] = []
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var paragraph: [String] = []
        var inCode = false
        var code: [String] = []
        var codeLanguage = ""
        var table: [[String]] = []

        func flushParagraph() {
            let text = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                result.append(MarkdownSegment(kind: .paragraph, text: text))
            }
            paragraph.removeAll()
        }

        func flushTable() {
            if table.count >= 2 {
                result.append(MarkdownSegment(kind: .table(table)))
            } else if table.count == 1 {
                paragraph.append(table[0].joined(separator: " | "))
            }
            table.removeAll()
        }

        func isSeparatorRow(_ cells: [String]) -> Bool {
            !cells.isEmpty && cells.allSatisfy { $0.range(of: "^[-:\\s]+$", options: .regularExpression) != nil }
        }

        func parseRow(_ line: String) -> [String]? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|") else { return nil }
            var cells = trimmed.split(separator: "|", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if let first = cells.first, first.isEmpty { cells.removeFirst() }
            if let last = cells.last, last.isEmpty { cells.removeLast() }
            return cells
        }

        for raw in lines {
            let line = raw
            if line.hasPrefix("```") {
                flushTable()
                if inCode {
                    let language = codeLanguage.lowercased()
                    let kind: MarkdownSegment.Kind = language == "mermaid" ? .mermaid : .code
                    result.append(MarkdownSegment(kind: kind, text: code.joined(separator: "\n")))
                    code.removeAll()
                    codeLanguage = ""
                    inCode = false
                } else {
                    flushParagraph()
                    inCode = true
                    codeLanguage = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            if inCode {
                code.append(line)
                continue
            }
            if let cells = parseRow(line) {
                flushParagraph()
                if isSeparatorRow(cells) { continue }
                table.append(cells)
                continue
            }
            if !table.isEmpty { flushTable() }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                continue
            }
            if line.hasPrefix("### ") {
                flushParagraph()
                result.append(MarkdownSegment(kind: .heading(3), text: String(line.dropFirst(4))))
            } else if line.hasPrefix("## ") {
                flushParagraph()
                result.append(MarkdownSegment(kind: .heading(2), text: String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                flushParagraph()
                result.append(MarkdownSegment(kind: .heading(1), text: String(line.dropFirst(2))))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                result.append(MarkdownSegment(kind: .bullet, text: String(line.dropFirst(2))))
            } else if let numbered = line.range(of: "^\\d+\\. ", options: .regularExpression) {
                flushParagraph()
                result.append(MarkdownSegment(kind: .bullet, text: String(line[numbered.upperBound...])))
            } else if line.hasPrefix("> ") {
                flushParagraph()
                result.append(MarkdownSegment(kind: .quote, text: String(line.dropFirst(2))))
            } else if line.hasPrefix("---") {
                flushParagraph()
                result.append(MarkdownSegment(kind: .divider, text: ""))
            } else {
                paragraph.append(line)
            }
        }
        if inCode {
            let kind: MarkdownSegment.Kind = codeLanguage.lowercased() == "mermaid" ? .mermaid : .code
            result.append(MarkdownSegment(kind: kind, text: code.joined(separator: "\n")))
        }
        flushTable()
        flushParagraph()
        return result
    }

    static func attributed(from markdown: String, trait: UITraitCollection, user: Bool) -> NSAttributedString {
        let ink = user ? UIColor.white : ZUIColor.ink(trait)
        let muted = ZUIColor.inkSoft(trait)
        let output = NSMutableAttributedString()
        let segments = segments(from: markdown)
        for (index, segment) in segments.enumerated() {
            if index > 0 { output.append(NSAttributedString(string: "\n")) }
            switch segment.kind {
            case .heading(let level):
                let size: CGFloat = level == 1 ? 20 : (level == 2 ? 18 : 16.5)
                output.append(styled(inline(segment.text, ink: ink), size: size, weight: .semibold, color: ink, spacing: 2))
            case .paragraph:
                output.append(styled(inline(segment.text, ink: ink), size: 15.5, weight: .regular, color: ink, spacing: 4.2))
            case .bullet:
                let bullet = NSMutableAttributedString(string: "•  ", attributes: [
                    .font: UIFont.systemFont(ofSize: 15.5, weight: .semibold),
                    .foregroundColor: ZUIColor.accent(trait)
                ])
                bullet.append(styled(inline(segment.text, ink: ink), size: 15.5, weight: .regular, color: ink, spacing: 3))
                output.append(bullet)
            case .quote:
                output.append(styled(inline(segment.text, ink: muted), size: 15, weight: .regular, color: muted, spacing: 3))
            case .code, .mermaid:
                let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
                output.append(NSAttributedString(string: segment.text, attributes: [
                    .font: font,
                    .foregroundColor: ink,
                    .backgroundColor: ZUIColor.surface(trait)
                ]))
            case .divider:
                output.append(NSAttributedString(string: " ", attributes: [.font: UIFont.systemFont(ofSize: 8)]))
            case .table(let rows):
                for (rowIndex, cells) in rows.enumerated() {
                    if rowIndex > 0 {
                        output.append(NSAttributedString(string: "\n", attributes: [
                            .font: UIFont.systemFont(ofSize: 4)
                        ]))
                    }
                    let isHeader = rowIndex == 0
                    let line = NSMutableAttributedString()
                    for (cellIndex, cell) in cells.enumerated() {
                        if cellIndex > 0 {
                            line.append(NSAttributedString(string: "   ·   ", attributes: [
                                .font: UIFont.systemFont(ofSize: 13),
                                .foregroundColor: ZUIColor.inkFaint(trait)
                            ]))
                        }
                        line.append(styled(inline(cell, ink: ink), size: 14, weight: isHeader ? .semibold : .regular, color: isHeader ? ink : muted, spacing: 2))
                    }
                    output.append(line)
                }
            }
        }
        return output
    }

    private static func styled(_ text: NSAttributedString, size: CGFloat, weight: UIFont.Weight, color: UIColor, spacing: CGFloat) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: text)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = spacing
        paragraph.paragraphSpacing = 8
        mutable.addAttributes([
            .font: UIFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ], range: NSRange(location: 0, length: mutable.length))
        return mutable
    }

    private static func inline(_ text: String, ink: UIColor) -> NSAttributedString {
        let mutable = NSMutableAttributedString(string: text)
        apply(pattern: "`([^`]+)`", in: mutable) { range, _ in
            mutable.addAttributes([
                .font: UIFont.monospacedSystemFont(ofSize: 14.5, weight: .medium),
                .backgroundColor: ink.withAlphaComponent(0.08)
            ], range: range)
        }
        apply(pattern: "\\*\\*([^*]+)\\*\\*", in: mutable) { range, _ in
            mutable.addAttributes([.font: UIFont.systemFont(ofSize: 16.5, weight: .semibold)], range: range)
        }
        return mutable
    }

    private static func apply(pattern: String, in text: NSMutableAttributedString, body: (NSRange, String) -> Void) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let matches = regex.matches(in: text.string, range: NSRange(location: 0, length: text.length)).reversed()
        for match in matches {
            if match.numberOfRanges >= 2 {
                let inner = match.range(at: 1)
                let value = (text.string as NSString).substring(with: inner)
                text.replaceCharacters(in: match.range, with: value)
                body(NSRange(location: match.range.location, length: (value as NSString).length), value)
            }
        }
    }
}
