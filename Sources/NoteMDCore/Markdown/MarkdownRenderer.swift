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
        /// Add a Transcribe link (`notemd-action:transcribe?src=…`) under audio embeds.
        public var transcribeLinks: Bool

        public init(frontMatter: FrontMatterStyle = .hidden, sourcePositions: Bool = true, transcribeLinks: Bool = false) {
            self.frontMatter = frontMatter
            self.sourcePositions = sourcePositions
            self.transcribeLinks = transcribeLinks
        }
    }

    /// Scheme of in-page action links handled by the app.
    public static let actionScheme = "notemd-action"

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

    /// Destinations of every link and image in `markdown`, as written (after Markdown unescaping).
    public static func linkDestinations(in markdown: String) -> [String] {
        withDocument(MarkdownText(markdown).body, options: CMARK_OPT_DEFAULT) { document, _ in
            var nodes: [UnsafeMutablePointer<cmark_node>] = []
            collect(CMARK_NODE_LINK, from: document, into: &nodes)
            collect(CMARK_NODE_IMAGE, from: document, into: &nodes)
            return nodes.compactMap { cmark_node_get_url($0).map { String(cString: $0) } }
        } ?? []
    }

    private static func renderBody(_ body: String, options: Options) -> String {
        var cmarkOptions = CMARK_OPT_UNSAFE | CMARK_OPT_FOOTNOTES | CMARK_OPT_VALIDATE_UTF8 | CMARK_OPT_GITHUB_PRE_LANG
        if options.sourcePositions { cmarkOptions |= CMARK_OPT_SOURCEPOS }
        return withDocument(body, options: cmarkOptions) { document, parser in
            convertAlerts(in: document)
            convertMediaEmbeds(in: document, transcribeLinks: options.transcribeLinks)
            guard let rendered = cmark_render_html(document, cmarkOptions, cmark_parser_get_syntax_extensions(parser)) else { return "" }
            defer { free(rendered) }
            return String(cString: rendered)
        } ?? ""
    }

    /// Parses `body` with the GFM extensions and hands the document to `body`.
    private static func withDocument<T>(
        _ body: String, options: Int32,
        _ work: (UnsafeMutablePointer<cmark_node>, UnsafeMutablePointer<cmark_parser>) -> T
    ) -> T? {
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(options) else { return nil }
        defer { cmark_parser_free(parser) }
        for name in extensionNames {
            if let syntaxExtension = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, syntaxExtension)
            }
        }
        body.utf8CString.withUnsafeBufferPointer { buffer in
            cmark_parser_feed(parser, buffer.baseAddress, buffer.count - 1)
        }
        guard let document = cmark_parser_finish(parser) else { return nil }
        defer { cmark_node_free(document) }
        return work(document, parser)
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

    // MARK: Media embeds

    /// Turns `+[name](clip.m4a)` into an audio or video player (decision-5). Other `+[…](…)` targets
    /// become plain links; `\+[…](…)` stays literal.
    private static func convertMediaEmbeds(in document: UnsafeMutablePointer<cmark_node>, transcribeLinks: Bool) {
        var links: [UnsafeMutablePointer<cmark_node>] = []
        collect(CMARK_NODE_LINK, from: document, into: &links)
        for link in links {
            guard let previous = cmark_node_previous(link), cmark_node_get_type(previous) == CMARK_NODE_TEXT,
                  let literalPointer = cmark_node_get_literal(previous)
            else { continue }
            let literal = String(cString: literalPointer)
            guard literal.hasSuffix("+"), !isEscapedCharacter(previous, literal: literal) else { continue }
            let remainder = String(literal.dropLast())
            if remainder.isEmpty { cmark_node_free(previous) } else { cmark_node_set_literal(previous, remainder) }

            let destination = cmark_node_get_url(link).map { String(cString: $0) } ?? ""
            let kind = AttachmentKind(destination: destination)
            guard kind == .audio || kind == .video, let player = cmark_node_new(CMARK_NODE_HTML_INLINE) else { continue }
            let name = escape(plainText(of: link))
            let source = escape(destination)
            var html = "<span class=\"media-embed media-\(kind == .audio ? "audio" : "video")\">"
            // A start-time fragment makes WebKit show the first frame instead of a black box.
            html += kind == .audio
                ? "<audio controls preload=\"metadata\" src=\"\(source)\"></audio>"
                : "<video controls preload=\"metadata\" src=\"\(source)\(destination.contains("#") ? "" : "#t=0.001")\"></video>"
            html += "<span class=\"media-caption\">\(name)"
            if kind == .audio && transcribeLinks {
                let query = destination.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
                html += " <a class=\"media-action\" href=\"\(actionScheme):transcribe?src=\(query)\">Transcribe</a>"
            }
            html += "</span></span>"
            cmark_node_set_literal(player, html)
            cmark_node_replace(link, player)
            cmark_node_free(link)
        }
    }

    /// cmark keeps a backslash escape (`\+`) as its own one-character text node spanning two columns.
    private static func isEscapedCharacter(_ node: UnsafeMutablePointer<cmark_node>, literal: String) -> Bool {
        literal.utf8.count == 1 && cmark_node_get_end_column(node) - cmark_node_get_start_column(node) == 1
    }

    private static func plainText(of node: UnsafeMutablePointer<cmark_node>) -> String {
        var text = ""
        var child = cmark_node_first_child(node)
        while let current = child {
            if let literal = cmark_node_get_literal(current) { text += String(cString: literal) }
            text += plainText(of: current)
            child = cmark_node_next(current)
        }
        return text
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
