import AppKit

/// Lightweight regex-based Markdown styling for the editor's text storage.
/// Only attributes change, so highlighting never touches undo or the file.
struct MarkdownHighlighter {
    var baseFont: NSFont
    var isMarkdown: Bool

    private var monoFont: NSFont { .monospacedSystemFont(ofSize: baseFont.pointSize * 0.92, weight: .regular) }

    var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = isMarkdown ? 1.22 : 1.1
        style.paragraphSpacing = isMarkdown ? 2 : 0
        return style
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraphStyle]
    }

    func highlight(_ storage: NSTextStorage) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: full)
        if isMarkdown, storage.length < 400_000 {
            apply(to: storage)
        }
        storage.endEditing()
    }

    // MARK: Rules

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = [.anchorsMatchLines]) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let frontMatter = regex(#"\A---\r?\n[\s\S]*?\r?\n(---|\.\.\.)[ \t]*$"#)
    private static let fence = regex(#"^[ \t]{0,3}(```|~~~)[^\n]*\n[\s\S]*?(^[ \t]{0,3}\1[ \t]*$|\z)"#)
    private static let heading = regex(#"^(#{1,6})[ \t]+(.*)$"#)
    private static let setextUnderline = regex(#"^(?:=+|-+)[ \t]*$"#)
    private static let bold = regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italic = regex(#"(?<![\*_\w\\])([*_])(?=[^\s*_])(.+?)(?<=[^\s*_])\1(?![\*_\w])"#)
    private static let strike = regex(#"~~(?=\S)(.+?)(?<=\S)~~"#)
    private static let inlineCode = regex(#"(`+)(?!`)(.+?)(?<!`)\1(?!`)"#)
    private static let link = regex(#"(!?)\[([^\]\n]*)\]\(([^)\n]*)\)"#)
    private static let autolink = regex(#"<(https?://[^>\s]+)>|(?<![(\[<"'=])\bhttps?://[^\s<>()\[\]]+[^\s<>()\[\].,;:!?'"]"#)
    private static let quote = regex(#"^[ \t]{0,3}(>+)[^\n]*$"#)
    private static let listMarker = regex(#"^[ \t]*([-*+]|\d{1,9}[.)])[ \t]+(\[[ xX]\][ \t]+)?"#)
    private static let rule = regex(#"^[ \t]{0,3}([-*_])([ \t]*\1){2,}[ \t]*$"#)
    private static let table = regex(#"^[ \t]*\|.*\|[ \t]*$"#)
    private static let placeholder = regex(#"\{\{[^{}\n]+\}\}"#)
    private static let htmlTag = regex(#"</?[A-Za-z][A-Za-z0-9-]*(\s[^<>\n]*)?/?>|<!--[\s\S]*?-->"#)
    private static let footnoteRef = regex(#"\[\^[^\]\s]+\]"#)

    private func apply(to storage: NSTextStorage) {
        let text = storage.string
        let full = NSRange(location: 0, length: storage.length)
        let secondary = NSColor.secondaryLabelColor
        let tertiary = NSColor.tertiaryLabelColor
        let accent = NSColor.controlAccentColor
        let codeBackground = NSColor.quaternaryLabelColor.withAlphaComponent(0.12)

        // Front matter and fences shield everything; inline code shields only inline rules.
        var protected: [NSRange] = []
        var blockProtected: [NSRange] = []
        func intersects(_ ranges: [NSRange], _ range: NSRange) -> Bool {
            ranges.contains { NSIntersectionRange($0, range).length > 0 }
        }
        func each(_ regex: NSRegularExpression, block: Bool = false, _ body: (NSTextCheckingResult) -> Void) {
            regex.enumerateMatches(in: text, range: full) { match, _, _ in
                if let match, !intersects(block ? blockProtected : protected, match.range) { body(match) }
            }
        }

        // Blocks whose content must not get inline styling.
        if let match = Self.frontMatter.firstMatch(in: text, range: full) {
            storage.addAttributes([.font: monoFont, .foregroundColor: secondary], range: match.range)
            protected.append(match.range)
            blockProtected.append(match.range)
        }
        each(Self.fence) { match in
            storage.addAttributes([.font: monoFont, .backgroundColor: codeBackground], range: match.range)
            let firstLine = (text as NSString).lineRange(for: NSRange(location: match.range.location, length: 0))
            storage.addAttribute(.foregroundColor, value: tertiary, range: NSIntersectionRange(firstLine, match.range))
            if match.range(at: 2).location != NSNotFound {
                storage.addAttribute(.foregroundColor, value: tertiary, range: match.range(at: 2))
            }
            protected.append(match.range)
            blockProtected.append(match.range)
        }
        each(Self.inlineCode) { match in
            storage.addAttributes([.font: monoFont, .backgroundColor: codeBackground, .foregroundColor: NSColor.systemPink], range: match.range)
            protected.append(match.range)
        }
        each(Self.htmlTag) { match in
            storage.addAttribute(.foregroundColor, value: tertiary, range: match.range)
        }
        each(Self.table, block: true) { match in
            storage.addAttribute(.font, value: monoFont, range: match.range)
        }

        each(Self.heading, block: true) { match in
            let level = match.range(at: 1).length
            let scale: CGFloat = [1.55, 1.32, 1.16, 1.06, 1.0, 1.0][level - 1]
            let font = NSFontManager.shared.convert(baseFont.withSize(baseFont.pointSize * scale), toHaveTrait: .boldFontMask)
            storage.addAttribute(.font, value: font, range: match.range)
            storage.addAttribute(.foregroundColor, value: tertiary, range: match.range(at: 1))
        }
        each(Self.quote, block: true) { match in
            storage.addAttribute(.foregroundColor, value: secondary, range: match.range)
            storage.addAttribute(.foregroundColor, value: accent, range: match.range(at: 1))
        }
        each(Self.rule, block: true) { match in
            storage.addAttribute(.foregroundColor, value: tertiary, range: match.range)
        }
        each(Self.listMarker, block: true) { match in
            storage.addAttribute(.foregroundColor, value: accent, range: match.range(at: 1))
            if match.range(at: 2).location != NSNotFound {
                storage.addAttribute(.foregroundColor, value: accent, range: match.range(at: 2))
            }
        }
        each(Self.bold) { match in
            addTrait(.boldFontMask, to: storage, range: match.range)
            dim(match, groups: [], markerLength: match.range(at: 1).length, in: storage)
        }
        each(Self.italic) { match in
            addTrait(.italicFontMask, to: storage, range: match.range)
            dim(match, groups: [], markerLength: 1, in: storage)
        }
        each(Self.strike) { match in
            storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: secondary], range: match.range)
        }
        each(Self.link) { match in
            storage.addAttribute(.foregroundColor, value: tertiary, range: match.range)
            storage.addAttribute(.foregroundColor, value: accent, range: match.range(at: 2))
        }
        each(Self.autolink) { match in
            storage.addAttributes([.foregroundColor: accent, .underlineStyle: NSUnderlineStyle.single.rawValue], range: match.range)
        }
        each(Self.footnoteRef) { match in
            storage.addAttribute(.foregroundColor, value: accent, range: match.range)
        }
        // Template placeholders stand out everywhere, even in code.
        protected.removeAll()
        each(Self.placeholder) { match in
            storage.addAttributes([.foregroundColor: NSColor.systemOrange, .backgroundColor: NSColor.systemOrange.withAlphaComponent(0.14)], range: match.range)
        }
    }

    private func addTrait(_ trait: NSFontTraitMask, to storage: NSTextStorage, range: NSRange) {
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            guard let font = value as? NSFont else { return }
            storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: subrange)
        }
    }

    private func dim(_ match: NSTextCheckingResult, groups: [Int], markerLength: Int, in storage: NSTextStorage) {
        let range = match.range
        guard range.length > markerLength * 2 else { return }
        storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: NSRange(location: range.location, length: markerLength))
        storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: NSRange(location: NSMaxRange(range) - markerLength, length: markerLength))
    }
}
