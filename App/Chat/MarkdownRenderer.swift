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

        func flushParagraph() {
            let text = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                result.append(MarkdownSegment(kind: .paragraph, text: text))
            }
            paragraph.removeAll()
        }

        for raw in lines {
            let line = raw
            if line.hasPrefix("```") {
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
        flushParagraph()
        return result
    }

    static func attributed(from markdown: String, trait: UITraitCollection, user: Bool) -> NSAttributedString {
        let ink = user ? UIColor.white : ZUIColor.ink(trait)
        let muted = ink.withAlphaComponent(0.72)
        let output = NSMutableAttributedString()
        let segments = segments(from: markdown)
        for (index, segment) in segments.enumerated() {
            if index > 0 { output.append(NSAttributedString(string: "\n")) }
            switch segment.kind {
            case .heading(let level):
                let size: CGFloat = level == 1 ? 22 : (level == 2 ? 19 : 17)
                output.append(styled(inline(segment.text, ink: ink), size: size, weight: .semibold, color: ink, spacing: 2))
            case .paragraph:
                output.append(styled(inline(segment.text, ink: ink), size: 16.5, weight: .regular, color: ink, spacing: 4.2))
            case .bullet:
                let bullet = NSMutableAttributedString(string: "•  ", attributes: [
                    .font: UIFont.systemFont(ofSize: 16.5, weight: .semibold),
                    .foregroundColor: ZUIColor.accent
                ])
                bullet.append(styled(inline(segment.text, ink: ink), size: 16.5, weight: .regular, color: ink, spacing: 3))
                output.append(bullet)
            case .quote:
                output.append(styled(inline(segment.text, ink: muted), size: 16, weight: .regular, color: muted, spacing: 3))
            case .code, .mermaid:
                let font = UIFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
                output.append(NSAttributedString(string: segment.text, attributes: [
                    .font: font,
                    .foregroundColor: ink,
                    .backgroundColor: user ? UIColor.white.withAlphaComponent(0.12) : ZUIColor.codeBgLight.withAlphaComponent(trait.userInterfaceStyle == .dark ? 0.35 : 1)
                ]))
            case .divider:
                output.append(NSAttributedString(string: " ", attributes: [.font: UIFont.systemFont(ofSize: 8)]))
            }
        }
        return output
    }

    private static func styled(_ text: NSAttributedString, size: CGFloat, weight: UIFont.Weight, color: UIColor, spacing: CGFloat) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: text)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = spacing
        paragraph.paragraphSpacing = 6
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
