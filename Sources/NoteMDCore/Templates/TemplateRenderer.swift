import Foundation

/// Renders template bodies with a small Mustache/Handlebars-like syntax:
///
/// - `{{name}}` inserts a value (lists join with ", "; dates use the parameter format)
/// - `{{#if name}}…{{#elseif other}}…{{else}}…{{/if}}` and `{{#unless name}}…{{/unless}}` test truthiness,
///   or compare with a literal: `{{#if status == "done"}}`, `!=`, and for numbers `<`, `<=`, `>`, `>=`
/// - `{{#each name}}…{{.}}…{{/each}}` repeats for list items (`{{@index}}` is 1-based)
/// - `{{@today}}`, `{{@now}}` insert the current date / date-time
///
/// Unknown placeholders are left untouched so literal `{{…}}` text survives.
/// Block tags alone on their line remove that line, so blocks don't leave blank lines.
public struct TemplateRenderer: Sendable {
    public var values: [String: TemplateValue]
    public var dateFormats: [String: String]
    public var now: Date

    public init(values: [String: TemplateValue], dateFormats: [String: String] = [:], now: Date = Date()) {
        self.values = values
        self.dateFormats = dateFormats
        self.now = now
    }

    public init(parameters: [TemplateParameter], values: [String: TemplateValue], now: Date = Date()) {
        var formats: [String: String] = [:]
        for parameter in parameters where parameter.type == .date {
            if let format = parameter.format, !format.isEmpty { formats[parameter.name] = format }
        }
        self.init(values: values, dateFormats: formats, now: now)
    }

    public func render(_ template: String) -> String {
        var output = ""
        render(Self.parse(template), scope: Scope(item: nil, index: nil), into: &output)
        return output
    }

    /// Placeholder names referenced in a template (excluding built-ins and `.`).
    public static func referencedNames(in template: String) -> Set<String> {
        var names = Set<String>()
        func add(_ name: String) {
            if !name.hasPrefix("@") && name != "." && name != "this" { names.insert(name) }
        }
        func walk(_ nodes: [Node]) {
            for node in nodes {
                switch node {
                case .text: break
                case .variable(let name, _): add(name)
                case .block(_, let condition, let body, let elseBody):
                    add(condition.name)
                    walk(body)
                    walk(elseBody)
                }
            }
        }
        walk(parse(template))
        return names
    }

    // MARK: AST

    indirect enum Node: Equatable {
        case text(String)
        /// name and the original tag text (re-emitted when the name is unknown)
        case variable(String, String)
        case block(kind: String, condition: Condition, body: [Node], elseBody: [Node])
    }

    /// A block's test: a value's truthiness, or a comparison with a literal (`status == "done"`, `max >= 10`).
    struct Condition: Equatable {
        enum Comparison: String { case equal = "==", notEqual = "!=", less = "<", lessOrEqual = "<=", greater = ">", greaterOrEqual = ">=" }

        var name: String
        var comparison: Comparison?
        /// The literal compared against, without its quotes.
        var operand = ""

        private static let pattern = try! NSRegularExpression(pattern: #"^(\S+?)\s*(==|!=|<=|>=|<|>)\s*(.+)$"#)

        init(name: String) {
            self.name = name
        }

        init(parsing expression: String) {
            let ns = expression as NSString
            guard let match = Self.pattern.firstMatch(in: expression, range: NSRange(location: 0, length: ns.length)) else {
                self.init(name: expression)
                return
            }
            self.init(name: ns.substring(with: match.range(at: 1)))
            comparison = Comparison(rawValue: ns.substring(with: match.range(at: 2)))
            operand = Self.unquoted(ns.substring(with: match.range(at: 3)))
        }

        private static func unquoted(_ literal: String) -> String {
            guard literal.count >= 2, let first = literal.first, first == "\"" || first == "'", literal.last == first else { return literal }
            return String(literal.dropFirst().dropLast())
        }
    }

    private struct Token {
        enum Kind { case text, variable, open, close, elseTag, elseIf }
        var kind: Kind
        var name: String
        var raw: String
        var blockKind = ""
    }

    private static let tagPattern = try! NSRegularExpression(pattern: #"\{\{\s*([#/]?)\s*([^{}]*?)\s*\}\}"#)

    static func parse(_ template: String) -> [Node] {
        let tokens = stripStandaloneLines(tokenize(template))
        var index = 0
        return parseNodes(tokens, &index, closing: nil).nodes
    }

    private static func tokenize(_ template: String) -> [Token] {
        let ns = template as NSString
        var tokens: [Token] = []
        var cursor = 0
        for match in tagPattern.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                tokens.append(Token(kind: .text, name: "", raw: ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))))
            }
            let raw = ns.substring(with: match.range)
            let sigil = ns.substring(with: match.range(at: 1))
            let content = ns.substring(with: match.range(at: 2))
            switch sigil {
            case "#":
                let parts = content.split(separator: " ", maxSplits: 1).map(String.init)
                if parts.count == 2, ["if", "unless", "each"].contains(parts[0]) {
                    tokens.append(Token(kind: .open, name: parts[1].trimmingCharacters(in: .whitespaces), raw: raw, blockKind: parts[0]))
                } else if parts.count == 2, parts[0] == "elseif" {
                    tokens.append(Token(kind: .elseIf, name: parts[1].trimmingCharacters(in: .whitespaces), raw: raw))
                } else {
                    tokens.append(Token(kind: .text, name: "", raw: raw))
                }
            case "/":
                if ["if", "unless", "each"].contains(content) {
                    tokens.append(Token(kind: .close, name: "", raw: raw, blockKind: content))
                } else {
                    tokens.append(Token(kind: .text, name: "", raw: raw))
                }
            default:
                if content == "else" {
                    tokens.append(Token(kind: .elseTag, name: "", raw: raw))
                } else if content.hasPrefix("else if ") {
                    // Handlebars spelling of `{{#elseif …}}`.
                    tokens.append(Token(kind: .elseIf, name: content.dropFirst(8).trimmingCharacters(in: .whitespaces), raw: raw))
                } else if !content.isEmpty {
                    tokens.append(Token(kind: .variable, name: content, raw: raw))
                } else {
                    tokens.append(Token(kind: .text, name: "", raw: raw))
                }
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            tokens.append(Token(kind: .text, name: "", raw: ns.substring(from: cursor)))
        }
        return tokens
    }

    /// Removes the line of a block tag that stands alone on it (only whitespace around it).
    private static func stripStandaloneLines(_ input: [Token]) -> [Token] {
        var tokens = input
        for i in tokens.indices where [.open, .close, .elseTag, .elseIf].contains(tokens[i].kind) {
            let before = i > 0 && tokens[i - 1].kind == .text ? tokens[i - 1].raw : (i == 0 ? "" : nil)
            let after = i + 1 < tokens.count && tokens[i + 1].kind == .text ? tokens[i + 1].raw : (i + 1 == tokens.count ? "" : nil)
            guard let before, let after else { continue }
            let lineStart = before.lastIndex(where: \.isNewline).map { before.index(after: $0) } ?? before.startIndex
            let prefix = before[lineStart...]
            let beforeIsLineStart = before.contains(where: \.isNewline) || i == 0 || (i > 0 && isPrecededByLineBreak(tokens, i - 1))
            guard beforeIsLineStart, prefix.allSatisfy({ $0 == " " || $0 == "\t" }) else { continue }
            let lineEnd = after.firstIndex(where: \.isNewline)
            let suffix = after[..<(lineEnd ?? after.endIndex)]
            guard suffix.allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\r" }) else { continue }
            guard lineEnd != nil || i + 1 >= tokens.count - 1 else { continue }
            if i > 0 && tokens[i - 1].kind == .text { tokens[i - 1].raw = String(before[..<lineStart]) }
            if i + 1 < tokens.count && tokens[i + 1].kind == .text {
                tokens[i + 1].raw = lineEnd.map { String(after[after.index(after: $0)...]) } ?? ""
            }
        }
        return tokens
    }

    /// True when the text token at `index` is empty and everything before it ends at a line start.
    private static func isPrecededByLineBreak(_ tokens: [Token], _ index: Int) -> Bool {
        guard tokens[index].raw.allSatisfy({ $0 == " " || $0 == "\t" }) else { return false }
        if index == 0 { return true }
        let previous = tokens[index - 1]
        return previous.kind != .text && previous.kind != .variable
    }

    private static func parseNodes(_ tokens: [Token], _ index: inout Int, closing: String?) -> (nodes: [Node], elseNodes: [Node]?, closed: Bool) {
        var nodes: [Node] = []
        var elseNodes: [Node]?
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            switch token.kind {
            case .text:
                append(.text(token.raw), to: &nodes, elseNodes: &elseNodes)
            case .variable:
                append(.variable(token.name, token.raw), to: &nodes, elseNodes: &elseNodes)
            case .elseTag:
                if closing != nil && elseNodes == nil {
                    elseNodes = []
                } else {
                    append(.text(token.raw), to: &nodes, elseNodes: &elseNodes)
                }
            case .elseIf:
                guard closing == "if" || closing == "unless", elseNodes == nil else {
                    append(.text(token.raw), to: &nodes, elseNodes: &elseNodes)
                    continue
                }
                // The rest of the chain becomes a nested `if` in the else branch, sharing this block's closing tag.
                let rest = parseNodes(tokens, &index, closing: closing)
                let branch = Node.block(kind: "if", condition: Condition(parsing: token.name), body: rest.nodes, elseBody: rest.elseNodes ?? [])
                return (nodes, [branch], rest.closed)
            case .open:
                let start = index
                let inner = parseNodes(tokens, &index, closing: token.blockKind)
                if inner.closed {
                    let condition = token.blockKind == "each" ? Condition(name: token.name) : Condition(parsing: token.name)
                    append(.block(kind: token.blockKind, condition: condition, body: inner.nodes, elseBody: inner.elseNodes ?? []), to: &nodes, elseNodes: &elseNodes)
                } else {
                    // Unbalanced: keep the tag literally and re-parse what followed it.
                    index = start
                    append(.text(token.raw), to: &nodes, elseNodes: &elseNodes)
                }
            case .close:
                if token.blockKind == closing {
                    return (nodes, elseNodes, true)
                }
                append(.text(token.raw), to: &nodes, elseNodes: &elseNodes)
            }
        }
        return (nodes, elseNodes, false)
    }

    private static func append(_ node: Node, to nodes: inout [Node], elseNodes: inout [Node]?) {
        if elseNodes != nil { elseNodes!.append(node) } else { nodes.append(node) }
    }

    // MARK: Evaluation

    private struct Scope {
        var item: String?
        var index: Int?
    }

    private func render(_ nodes: [Node], scope: Scope, into output: inout String) {
        for node in nodes {
            switch node {
            case .text(let text):
                output += text
            case .variable(let name, let raw):
                output += resolve(name, scope: scope) ?? raw
            case .block(let kind, let condition, let body, let elseBody):
                switch kind {
                case "if":
                    render(test(condition, scope: scope) ? body : elseBody, scope: scope, into: &output)
                case "unless":
                    render(test(condition, scope: scope) ? elseBody : body, scope: scope, into: &output)
                default:
                    let items: [String] = switch values[condition.name] {
                    case .list(let list): list
                    case .some(let other) where other.isTruthy: [format(other, name: condition.name)]
                    default: []
                    }
                    if items.isEmpty {
                        render(elseBody, scope: scope, into: &output)
                    }
                    for (offset, item) in items.enumerated() {
                        render(body, scope: Scope(item: item, index: offset + 1), into: &output)
                    }
                }
            }
        }
    }

    private func test(_ condition: Condition, scope: Scope) -> Bool {
        let value: TemplateValue? = switch condition.name {
        case ".", "this": scope.item.map(TemplateValue.text)
        case "@index": scope.index.map { .number(Double($0)) }
        default: values[condition.name]
        }
        guard let comparison = condition.comparison else { return value?.isTruthy == true }
        switch comparison {
        case .equal: return equals(value, condition)
        case .notEqual: return !equals(value, condition)
        case .less: return Self.compare(value, condition.operand, <)
        case .lessOrEqual: return Self.compare(value, condition.operand, <=)
        case .greater: return Self.compare(value, condition.operand, >)
        case .greaterOrEqual: return Self.compare(value, condition.operand, >=)
        }
    }

    /// Numbers compare numerically, lists (multiple choice) test membership, everything else compares as inserted.
    private func equals(_ value: TemplateValue?, _ condition: Condition) -> Bool {
        switch value {
        case nil: false
        case .number(let d): Double(condition.operand) == d
        case .list(let items): items.contains(condition.operand)
        case .some(let other): format(other, name: condition.name) == condition.operand
        }
    }

    /// Ordering needs a number on both sides (a number value or numeric text such as a choice option).
    private static func compare(_ value: TemplateValue?, _ operand: String, _ order: (Double, Double) -> Bool) -> Bool {
        let lhs: Double? = switch value {
        case .number(let d): d
        case .text(let s): Double(s.trimmingCharacters(in: .whitespaces))
        default: nil
        }
        guard let lhs, let rhs = Double(operand) else { return false }
        return order(lhs, rhs)
    }

    private func resolve(_ name: String, scope: Scope) -> String? {
        switch name {
        case ".", "this": return scope.item
        case "@index": return scope.index.map(String.init)
        case "@today": return ISO8601DateFormatter.dateOnly.string(from: now)
        case "@now":
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            return formatter.string(from: now)
        default:
            return values[name].map { format($0, name: name) }
        }
    }

    private func format(_ value: TemplateValue, name: String) -> String {
        switch value {
        case .text(let s): return s
        case .number(let d): return d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
        case .bool(let b): return b ? "true" : "false"
        case .list(let l): return l.joined(separator: ", ")
        case .date(let date):
            if let pattern = dateFormats[name] {
                let formatter = DateFormatter()
                formatter.dateFormat = pattern
                return formatter.string(from: date)
            }
            return ISO8601DateFormatter.dateOnly.string(from: date)
        }
    }
}

/// Required-field validation for a filled template form.
public enum TemplateValidation {
    /// Names of required parameters without a truthy value.
    public static func missingRequired(_ parameters: [TemplateParameter], values: [String: TemplateValue]) -> [String] {
        parameters.filter { parameter in
            guard parameter.required else { return false }
            if parameter.type == .toggle || parameter.type == .number || parameter.type == .date { return values[parameter.name] == nil }
            return values[parameter.name]?.isTruthy != true
        }.map(\.name)
    }
}
