import Foundation

/// A value supplied for a template parameter.
public enum TemplateValue: Sendable, Hashable {
    case text(String)
    case number(Double)
    case bool(Bool)
    case list([String])
    case date(Date)

    /// Whether the value counts as "set" for `{{#if}}` blocks and required checks.
    public var isTruthy: Bool {
        switch self {
        case .text(let s): !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .number: true
        case .bool(let b): b
        case .list(let l): !l.isEmpty
        case .date: true
        }
    }
}

public enum ParameterType: String, Sendable, CaseIterable, Identifiable, Codable {
    case text, textarea, number, toggle, choice, multichoice, file, folder, date, list

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .text: "Text"
        case .textarea: "Long Text"
        case .number: "Number"
        case .toggle: "Yes / No"
        case .choice: "Choice"
        case .multichoice: "Multiple Choice"
        case .file: "File"
        case .folder: "Folder"
        case .date: "Date"
        case .list: "List"
        }
    }

    /// Accepts common aliases so hand-written front matter is forgiving.
    public init?(alias: String) {
        switch alias.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "") {
        case "text", "string", "str", "line": self = .text
        case "textarea", "multiline", "longtext", "paragraph": self = .textarea
        case "number", "int", "integer", "float", "double", "numeric": self = .number
        case "toggle", "bool", "boolean", "checkbox", "switch", "flag": self = .toggle
        case "choice", "select", "dropdown", "enum", "option", "radio": self = .choice
        case "multichoice", "multiplechoice", "multiselect", "multi", "checkboxes": self = .multichoice
        case "file", "filepath", "path": self = .file
        case "folder", "directory", "dir", "folderpath": self = .folder
        case "date", "day": self = .date
        case "list", "array", "items", "lines": self = .list
        default: return nil
        }
    }

    public var usesOptions: Bool { self == .choice || self == .multichoice }
}

/// A template parameter declared in a note's `params` front matter.
public struct TemplateParameter: Sendable, Hashable, Identifiable {
    /// Stable identity for editing UIs; not persisted.
    public var id = UUID()
    public var name: String
    public var label: String?
    public var type: ParameterType
    public var required: Bool
    public var help: String?
    public var placeholder: String?
    public var defaultValue: TemplateValue?
    public var options: [String]
    /// Date output format (Unicode pattern, e.g. `yyyy-MM-dd`); ISO date when nil.
    public var format: String?

    public init(
        name: String, label: String? = nil, type: ParameterType = .text, required: Bool = false,
        help: String? = nil, placeholder: String? = nil, defaultValue: TemplateValue? = nil,
        options: [String] = [], format: String? = nil
    ) {
        self.name = name
        self.label = label
        self.type = type
        self.required = required
        self.help = help
        self.placeholder = placeholder
        self.defaultValue = defaultValue
        self.options = options
        self.format = format
    }

    /// Equality ignores the editing identity so re-parsed parameters compare equal.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.label == rhs.label && lhs.type == rhs.type && lhs.required == rhs.required
            && lhs.help == rhs.help && lhs.placeholder == rhs.placeholder && lhs.defaultValue == rhs.defaultValue
            && lhs.options == rhs.options && lhs.format == rhs.format
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(type)
    }

    public var displayLabel: String {
        if let label, !label.isEmpty { return label }
        return Self.humanize(name)
    }

    /// `game_name` → `Game name`.
    public static func humanize(_ name: String) -> String {
        let words = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
        guard let first = words.first else { return name }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst().map(String.init)).joined(separator: " ")
    }

    /// Valid placeholder identifier: letters, digits, `_`, `-`, `.`.
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || "_-.".contains($0) }
    }

    /// The value a fresh form starts with.
    public func initialValue(now: Date = Date()) -> TemplateValue {
        if let defaultValue { return defaultValue }
        switch type {
        case .text, .textarea, .file, .folder: return .text("")
        case .number: return .number(0)
        case .toggle: return .bool(false)
        case .choice: return .text(options.first ?? "")
        case .multichoice, .list: return .list([])
        case .date: return .date(now)
        }
    }

    // MARK: Parsing

    static func parse(_ value: Any) -> [TemplateParameter] {
        if let list = value as? [Any] {
            return list.compactMap { item in
                if let map = item as? [String: Any] { return parse(map: map, fallbackName: nil) }
                if let name = item as? String { return TemplateParameter(name: name) }
                return nil
            }
        }
        // Also accept a mapping of name → definition.
        if let map = value as? [String: Any] {
            return map.keys.sorted().compactMap { key in
                if let definition = map[key] as? [String: Any] { return parse(map: definition, fallbackName: key) }
                if let type = map[key] as? String { return TemplateParameter(name: key, type: ParameterType(alias: type) ?? .text) }
                return TemplateParameter(name: key)
            }
        }
        return []
    }

    private static func parse(map: [String: Any], fallbackName: String?) -> TemplateParameter? {
        guard let name = YAMLValue.string(map["name"]) ?? fallbackName, !name.isEmpty else { return nil }
        let type = YAMLValue.string(map["type"]).flatMap(ParameterType.init(alias:)) ?? .text
        var parameter = TemplateParameter(
            name: name,
            label: YAMLValue.string(map["label"]),
            type: type,
            required: YAMLValue.bool(map["required"]) ?? false,
            help: YAMLValue.string(map["help"] ?? map["description"]),
            placeholder: YAMLValue.string(map["placeholder"]),
            options: YAMLValue.stringList(map["options"] ?? map["choices"] ?? map["values"]),
            format: YAMLValue.string(map["format"])
        )
        if let raw = map["default"] {
            parameter.defaultValue = defaultValue(raw, type: type)
        }
        return parameter
    }

    static func defaultValue(_ raw: Any, type: ParameterType) -> TemplateValue? {
        switch type {
        case .text, .textarea, .file, .folder, .choice:
            return YAMLValue.string(raw).map(TemplateValue.text)
        case .number:
            return YAMLValue.double(raw).map(TemplateValue.number)
        case .toggle:
            return YAMLValue.bool(raw).map(TemplateValue.bool)
        case .multichoice, .list:
            return .list(YAMLValue.stringList(raw))
        case .date:
            if let date = raw as? Date { return .date(date) }
            guard let text = YAMLValue.string(raw)?.lowercased() else { return nil }
            if text == "today" || text == "now" { return nil }  // dynamic: initialValue() uses now
            return ISO8601DateFormatter.dateOnly.date(from: text).map(TemplateValue.date)
        }
    }

    // MARK: Emitting

    /// YAML for a `params:` top-level entry.
    static func yaml(for parameters: [TemplateParameter]) -> String {
        var out = "params:\n"
        for parameter in parameters {
            var fields: [(String, String)] = [("name", YAMLScalar.block(parameter.name)), ("type", parameter.type.rawValue)]
            if let label = parameter.label, !label.isEmpty { fields.append(("label", YAMLScalar.block(label))) }
            if parameter.required { fields.append(("required", "true")) }
            if let help = parameter.help, !help.isEmpty { fields.append(("help", YAMLScalar.block(help))) }
            if let placeholder = parameter.placeholder, !placeholder.isEmpty {
                fields.append(("placeholder", YAMLScalar.block(placeholder)))
            }
            if parameter.type.usesOptions || !parameter.options.isEmpty, !parameter.options.isEmpty {
                fields.append(("options", "[" + parameter.options.map(YAMLScalar.flow).joined(separator: ", ") + "]"))
            }
            if parameter.type == .date, let format = parameter.format, !format.isEmpty {
                fields.append(("format", YAMLScalar.block(format)))
            }
            if let value = parameter.defaultValue, let yaml = yamlScalar(value) {
                fields.append(("default", yaml))
            }
            for (index, field) in fields.enumerated() {
                out += (index == 0 ? "  - " : "    ") + field.0 + ": " + field.1 + "\n"
            }
        }
        return out
    }

    private static func yamlScalar(_ value: TemplateValue) -> String? {
        switch value {
        case .text(let s): s.isEmpty ? nil : YAMLScalar.block(s)
        case .number(let d): d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
        case .bool(let b): b ? "true" : nil
        case .list(let l): l.isEmpty ? nil : "[" + l.map(YAMLScalar.flow).joined(separator: ", ") + "]"
        case .date(let d): ISO8601DateFormatter.dateOnly.string(from: d)
        }
    }
}
