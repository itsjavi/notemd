import Foundation
import Yams

/// A Markdown text split into an optional YAML front matter block and its body.
///
/// Front matter is kept as raw top-level entries so keys the app doesn't own
/// (comments, formatting, unknown fields) survive edits verbatim. Only the keys
/// changed through the typed setters are re-emitted.
public struct MarkdownText: Sendable, Equatable {
    public var frontMatter: FrontMatter?
    public var body: String
    /// The delimiter lines as read (`---\r\n`, `...`, trailing spaces), so unedited files round-trip byte for byte.
    private var original: (opening: String, yaml: String, closing: String, bom: Bool)?

    public init(frontMatter: FrontMatter?, body: String) {
        self.frontMatter = frontMatter
        self.body = body
    }

    public init(_ text: String) {
        let hasBOM = text.hasPrefix("\u{FEFF}")
        let normalized = hasBOM ? String(text.dropFirst()) : text
        guard let split = Self.splitFrontMatter(normalized) else {
            self.init(frontMatter: nil, body: text)
            return
        }
        self.init(frontMatter: FrontMatter(yaml: split.yaml), body: split.body)
        original = (split.opening, split.yaml, split.closing, hasBOM)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text
    }

    /// The full text, front matter included.
    public var text: String {
        guard let frontMatter else { return body }
        if let original, frontMatter.yaml == original.yaml {
            // Untouched front matter keeps its exact delimiters, even when empty.
            return (original.bom ? "\u{FEFF}" : "") + original.opening + original.yaml + original.closing + body
        }
        guard !frontMatter.isEmpty else { return body }
        let opening = original?.opening ?? "---\n"
        var closing = original?.closing ?? "---\n"
        if !(closing as NSString).hasSuffix("\n") { closing += "\n" }
        return (original?.bom == true ? "\u{FEFF}" : "") + opening + frontMatter.yaml + closing + body
    }

    /// Splits `---\n<yaml>---\n<body>`; returns nil without a closing delimiter.
    /// Works on line ranges so CRLF files keep their line endings.
    static func splitFrontMatter(_ text: String) -> (opening: String, yaml: String, closing: String, body: String)? {
        let ns = text as NSString
        guard ns.length >= 4 else { return nil }
        let firstLine = ns.lineRange(for: NSRange(location: 0, length: 0))
        let opening = ns.substring(with: firstLine)
        guard opening.trimmingCharacters(in: .newlines) == "---", (opening as NSString).hasSuffix("\n") else { return nil }
        let yamlStart = NSMaxRange(firstLine)
        var location = yamlStart
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            let closing = ns.substring(with: line)
            let content = closing.trimmingCharacters(in: .whitespacesAndNewlines)
            if content == "---" || content == "..." {
                let yaml = ns.substring(with: NSRange(location: yamlStart, length: line.location - yamlStart))
                return (opening, yaml, closing, ns.substring(from: NSMaxRange(line)))
            }
            location = NSMaxRange(line)
        }
        return nil
    }
}

/// YAML front matter stored as ordered top-level entries with their raw text.
public struct FrontMatter: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        /// nil for leading comments/blank lines before the first key.
        var key: String?
        var raw: String
    }

    private(set) var entries: [Entry]
    /// Error from the last YAML parse, if the block isn't valid YAML.
    public private(set) var parseError: String?
    private var parsed: ParsedValues

    public init(yaml: String) {
        entries = Self.splitEntries(yaml)
        (parsed, parseError) = Self.parse(yaml)
    }

    public init() {
        self.init(yaml: "")
    }

    public var yaml: String { entries.map(\.raw).joined() }
    public var isEmpty: Bool { yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var keys: [String] { entries.compactMap(\.key) }
    /// Lines between the delimiters.
    public var lineCount: Int {
        var count = 0
        (yaml as NSString).enumerateLines { _, _ in count += 1 }
        return count
    }

    public var title: String? { parsed.title }
    public var tags: [String] { parsed.tags }
    public var parameters: [TemplateParameter] { parsed.parameters }
    /// True when the note declares parameters or `template: true`.
    public var isTemplate: Bool { parsed.templateFlag || !parsed.parameters.isEmpty }

    /// Top-level scalar values as display strings (nested values summarized), for property tables.
    public var displayValues: [(key: String, value: String)] { parsed.display }

    public mutating func setTags(_ tags: [String]) {
        let cleaned = Tag.normalizedList(tags)
        setEntry("tag", raw: nil)
        setEntry("tags", raw: cleaned.isEmpty ? nil : "tags: [" + cleaned.map(YAMLScalar.flow).joined(separator: ", ") + "]\n")
    }

    public mutating func setTitle(_ title: String?) {
        let value = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        setEntry("title", raw: value.isEmpty ? nil : "title: " + YAMLScalar.block(value) + "\n")
    }

    public mutating func setParameters(_ parameters: [TemplateParameter]) {
        setEntry("parameters", raw: nil)
        setEntry("params", raw: parameters.isEmpty ? nil : TemplateParameter.yaml(for: parameters))
    }

    /// Replaces (or appends, or removes when `raw` is nil) a top-level entry and re-parses.
    mutating func setEntry(_ key: String, raw newRaw: String?) {
        // Match the file's line endings so edits don't mix CRLF and LF.
        let raw = yaml.contains("\r\n") ? newRaw?.replacingOccurrences(of: "\n", with: "\r\n") : newRaw
        if let index = entries.firstIndex(where: { $0.key == key }) {
            if let raw {
                entries[index].raw = Self.keepingTrailingTrivia(of: entries[index].raw, replacement: raw)
            } else {
                entries.remove(at: index)
            }
        } else if let raw {
            if let last = entries.indices.last, !(entries[last].raw as NSString).hasSuffix("\n") {
                entries[last].raw += yaml.contains("\r\n") ? "\r\n" : "\n"
            }
            entries.append(Entry(key: key, raw: raw))
        }
        (parsed, parseError) = Self.parse(yaml)
    }

    /// Blank lines and comments that followed the old value stay in place.
    private static func keepingTrailingTrivia(of old: String, replacement: String) -> String {
        var lines = old.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        if lines.last == "" { lines.removeLast() }
        var trivia: [String] = []
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty || last.hasPrefix("#") {
            trivia.insert(last, at: 0)
            lines.removeLast()
        }
        return trivia.isEmpty ? replacement : replacement + trivia.joined(separator: "\n") + "\n"
    }

    /// Splits YAML text into top-level entries: a new entry starts at an unindented `key:` line.
    static func splitEntries(_ yaml: String) -> [Entry] {
        var entries: [Entry] = []
        var current = Entry(key: nil, raw: "")
        let ns = yaml as NSString
        var location = 0
        while location < ns.length {
            let range = ns.lineRange(for: NSRange(location: location, length: 0))
            let line = ns.substring(with: range)
            if let key = topLevelKey(Substring(line.trimmingCharacters(in: .newlines))) {
                if current.key != nil || !current.raw.isEmpty { entries.append(current) }
                current = Entry(key: key, raw: "")
            }
            current.raw += line
            location = NSMaxRange(range)
        }
        if current.key != nil || !current.raw.isEmpty { entries.append(current) }
        return entries
    }

    private static func topLevelKey(_ line: Substring) -> String? {
        guard let first = line.first, !first.isWhitespace, first != "#", first != "-", first != "?" else { return nil }
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let after = line.index(after: colon)
        guard after == line.endIndex || line[after] == " " || line[after] == "\t" || line[after] == "\r" else { return nil }
        var key = line[..<colon].trimmingCharacters(in: .whitespaces)
        if key.count >= 2, let q = key.first, q == "\"" || q == "'", key.last == q {
            key = String(key.dropFirst().dropLast())
        }
        return key.isEmpty ? nil : key
    }

    struct ParsedValues: Sendable, Equatable {
        var title: String?
        var tags: [String] = []
        var parameters: [TemplateParameter] = []
        var templateFlag = false
        var display: [(key: String, value: String)] = []

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.title == rhs.title && lhs.tags == rhs.tags && lhs.parameters == rhs.parameters
                && lhs.templateFlag == rhs.templateFlag
                && lhs.display.map { "\($0.key)=\($0.value)" } == rhs.display.map { "\($0.key)=\($0.value)" }
        }
    }

    static func parse(_ yaml: String) -> (ParsedValues, String?) {
        var values = ParsedValues()
        guard !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (values, nil) }
        let object: Any?
        do {
            // Dates stay strings: Yams would read `2024-03-15` as UTC midnight and shift it a day west of UTC.
            object = try Yams.load(yaml: yaml, Resolver.default.removing(.timestamp))
        } catch {
            return (values, String(describing: error))
        }
        guard let map = object as? [String: Any] else { return (values, nil) }
        if let title = map["title"] { values.title = YAMLValue.string(title) }
        values.tags = Tag.normalizedList(YAMLValue.stringList(map["tags"] ?? map["tag"]))
        values.templateFlag = YAMLValue.bool(map["template"]) ?? false
        if let params = map["params"] ?? map["parameters"] {
            values.parameters = TemplateParameter.parse(params)
        }
        let order = splitEntries(yaml).compactMap(\.key)
        values.display = order.compactMap { key in
            guard let value = map[key] else { return nil }
            return (key, YAMLValue.summary(value))
        }
        return (values, nil)
    }
}

/// Helpers to read loosely-typed YAML values.
enum YAMLValue {
    static func string(_ value: Any?) -> String? {
        switch value {
        case let s as String: s
        case let b as Bool: b ? "true" : "false"
        case let i as Int: String(i)
        case let d as Double: d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
        case let date as Date: ISO8601DateFormatter.dateOnly.string(from: date)
        default: nil
        }
    }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let b as Bool: b
        case let s as String: ["true", "yes", "on", "1"].contains(s.lowercased()) ? true : (["false", "no", "off", "0"].contains(s.lowercased()) ? false : nil)
        case let i as Int: i != 0
        default: nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: d
        case let i as Int: Double(i)
        case let s as String: Double(s.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    static func stringList(_ value: Any?) -> [String] {
        switch value {
        case let list as [Any]: list.compactMap { string($0) }
        case let s as String:
            s.split(whereSeparator: { $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        default: []
        }
    }

    static func summary(_ value: Any) -> String {
        if let s = string(value) { return s }
        if let list = value as? [Any] { return list.map { summary($0) }.joined(separator: ", ") }
        if let map = value as? [String: Any] { return "{" + map.keys.sorted().joined(separator: ", ") + "}" }
        return String(describing: value)
    }
}

/// Emits YAML scalars safely.
enum YAMLScalar {
    private static let reserved: Set<String> = ["true", "false", "yes", "no", "on", "off", "null", "~", "y", "n"]

    /// A scalar usable inside a flow sequence (`[a, b]`).
    static func flow(_ value: String) -> String {
        isPlainSafe(value, extra: "") ? value : quoted(value)
    }

    /// A scalar for `key: value` positions.
    static func block(_ value: String) -> String {
        isPlainSafe(value, extra: ",[]{}") ? value : quoted(value)
    }

    static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\x%02X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    private static func isPlainSafe(_ value: String, extra: String) -> Bool {
        guard let first = value.first, let last = value.last else { return false }
        if first.isWhitespace || last.isWhitespace { return false }
        if reserved.contains(value.lowercased()) || Double(value) != nil { return false }
        if "-?:,[]{}#&*!|>'\"%@`".contains(first) { return false }
        if value.contains(": ") || value.contains(" #") || value.hasSuffix(":") { return false }
        let allowedPunctuation = Set(" ._-/()+'!?&$€£=~^<>;" + extra)
        return value.allSatisfy { ($0.isLetter || $0.isNumber || allowedPunctuation.contains($0)) && $0 != "\n" }
    }
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let dateOnly: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = .current
        return formatter
    }()
}
