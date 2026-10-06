import Foundation

public enum Tag {
    /// Trims, drops a leading `#`, collapses inner whitespace and removes case-insensitive duplicates (first spelling wins).
    public static func normalized(_ tag: String) -> String {
        var value = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix("#") { value.removeFirst() }
        return value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func normalizedList(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in tags {
            let value = normalized(tag)
            guard !value.isEmpty, seen.insert(value.lowercased()).inserted else { continue }
            result.append(value)
        }
        return result
    }
}
