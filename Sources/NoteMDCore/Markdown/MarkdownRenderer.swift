import Foundation
import cmark_gfm
import cmark_gfm_extensions

/// Renders GitHub Flavored Markdown to an HTML fragment with cmark-gfm.
public enum MarkdownRenderer {
    public enum FrontMatterStyle: Sendable {
        /// Drop front matter from the output.
        case hidden
        /// Show it as a key/value table, like GitHub does.
        case table
    }

    public struct Options: Sendable {
        public var frontMatter: FrontMatterStyle
        /// Emit `data-sourcepos` attributes (used to sync scrolling with the editor).
        public var sourcePositions: Bool

        public init(frontMatter: FrontMatterStyle = .hidden, sourcePositions: Bool = true) {
            self.frontMatter = frontMatter
            self.sourcePositions = sourcePositions
        }
    }

    private static let extensionNames = ["table", "strikethrough", "autolink", "tagfilter", "tasklist"]

    public static func html(from markdown: String, options: Options = Options()) -> String {
        let text = MarkdownText(markdown)
        var output = ""
        var lineOffset = 0
        if let frontMatter = text.frontMatter {
            // Keep source positions aligned with the full document.
            lineOffset = frontMatter.lineCount + 2
            if options.frontMatter == .table, !frontMatter.displayValues.isEmpty {
                output += frontMatterTable(frontMatter)
            }
        }
        output += renderBody(text.body, options: options)
        if lineOffset > 0 && options.sourcePositions {
            output = shiftSourcePositions(output, by: lineOffset)
        }
        return output
    }

    private static func renderBody(_ body: String, options: Options) -> String {
        cmark_gfm_core_extensions_ensure_registered()
        var cmarkOptions = CMARK_OPT_UNSAFE | CMARK_OPT_FOOTNOTES | CMARK_OPT_VALIDATE_UTF8 | CMARK_OPT_GITHUB_PRE_LANG
        if options.sourcePositions { cmarkOptions |= CMARK_OPT_SOURCEPOS }
        guard let parser = cmark_parser_new(cmarkOptions) else { return "" }
        defer { cmark_parser_free(parser) }
        for name in extensionNames {
            if let syntaxExtension = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, syntaxExtension)
            }
        }
        body.utf8CString.withUnsafeBufferPointer { buffer in
            cmark_parser_feed(parser, buffer.baseAddress, buffer.count - 1)
        }
        guard let document = cmark_parser_finish(parser) else { return "" }
        defer { cmark_node_free(document) }
        convertAlerts(in: document)
        guard let rendered = cmark_render_html(document, cmarkOptions, cmark_parser_get_syntax_extensions(parser)) else { return "" }
        defer { free(rendered) }
        return String(cString: rendered)
    }

    // MARK: GitHub alerts

    private static let alertKinds = ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"]

    /// Turns `> [!NOTE]` block quotes into `<div class="markdown-alert markdown-alert-note">`.
    private static func convertAlerts(in document: UnsafeMutablePointer<cmark_node>) {
        var quotes: [UnsafeMutablePointer<cmark_node>] = []
        collect(CMARK_NODE_BLOCK_QUOTE, from: document, into: &quotes)
        for quote in quotes {
            guard let paragraph = cmark_node_first_child(quote), cmark_node_get_type(paragraph) == CMARK_NODE_PARAGRAPH,
                  let textNode = cmark_node_first_child(paragraph), cmark_node_get_type(textNode) == CMARK_NODE_TEXT,
                  let literalPointer = cmark_node_get_literal(textNode)
            else { continue }
            let literal = String(cString: literalPointer)
            // cmark splits "[!NOTE]" into "[", "!NOTE", "]" text nodes; join the leading text run.
            var marker = literal
            var markerNodes = [textNode]
            var next = cmark_node_next(textNode)
            while marker.count < 12, let node = next, cmark_node_get_type(node) == CMARK_NODE_TEXT, let pointer = cmark_node_get_literal(node) {
                marker += String(cString: pointer)
                markerNodes.append(node)
                next = cmark_node_next(node)
            }
            guard let kind = alertKinds.first(where: { marker.uppercased().hasPrefix("[!\($0)]") }) else { continue }
            let remainder = String(marker.dropFirst(kind.count + 3)).trimmingCharacters(in: .whitespaces)
            guard remainder.isEmpty else { continue }  // GitHub requires the marker alone on its line
            for node in markerNodes { cmark_node_free(node) }
            // Drop the line break that followed the marker.
            if let first = cmark_node_first_child(paragraph), [CMARK_NODE_SOFTBREAK, CMARK_NODE_LINEBREAK].contains(cmark_node_get_type(first)) {
                cmark_node_free(first)
            }
            if cmark_node_first_child(paragraph) == nil { cmark_node_free(paragraph) }

            guard let alert = cmark_node_new(CMARK_NODE_CUSTOM_BLOCK) else { continue }
            let title = kind.prefix(1) + kind.dropFirst().lowercased()
            let className = kind.lowercased()
            cmark_node_set_on_enter(alert, "<div class=\"markdown-alert markdown-alert-\(className)\"><p class=\"markdown-alert-title\">\(title)</p>\n")
            cmark_node_set_on_exit(alert, "</div>\n")
            while let child = cmark_node_first_child(quote) {
                cmark_node_append_child(alert, child)
            }
            cmark_node_replace(quote, alert)
            cmark_node_free(quote)
        }
    }

    private static func collect(_ type: cmark_node_type, from node: UnsafeMutablePointer<cmark_node>, into result: inout [UnsafeMutablePointer<cmark_node>]) {
        var child = cmark_node_first_child(node)
        while let current = child {
            if cmark_node_get_type(current) == type { result.append(current) }
            collect(type, from: current, into: &result)
            child = cmark_node_next(current)
        }
    }

    // MARK: Helpers

    private static func frontMatterTable(_ frontMatter: FrontMatter) -> String {
        var html = "<table class=\"front-matter\"><thead><tr>"
        let values = frontMatter.displayValues
        for (key, _) in values { html += "<th>\(escape(key))</th>" }
        html += "</tr></thead><tbody><tr>"
        for (_, value) in values { html += "<td>\(escape(value))</td>" }
        return html + "</tr></tbody></table>\n"
    }

    private static let sourceposPattern = try! NSRegularExpression(pattern: #"data-sourcepos="(\d+):(\d+)-(\d+):(\d+)""#)

    static func shiftSourcePositions(_ html: String, by offset: Int) -> String {
        let ns = html as NSString
        var result = ""
        var cursor = 0
        for match in sourceposPattern.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let startLine = Int(ns.substring(with: match.range(at: 1)))! + offset
            let endLine = Int(ns.substring(with: match.range(at: 3)))! + offset
            result += "data-sourcepos=\"\(startLine):\(ns.substring(with: match.range(at: 2)))-\(endLine):\(ns.substring(with: match.range(at: 4)))\""
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    public static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }
}
