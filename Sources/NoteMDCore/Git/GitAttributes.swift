import Foundation

/// Edits `.gitattributes` content.
public enum GitAttributes {
    /// The rule `git lfs track` writes for `pattern`.
    public static func lfsRule(for pattern: String) -> String {
        "\(pattern) filter=lfs diff=lfs merge=lfs -text"
    }

    /// `existing` with an LFS rule for `pattern` appended, or nil when `pattern` already uses the LFS filter.
    public static func addingLFSTracking(_ pattern: String, to existing: String) -> String? {
        let alreadyTracked = existing.split(whereSeparator: \.isNewline).contains { line in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            return fields.first.map(String.init) == pattern && fields.contains("filter=lfs")
        }
        guard !alreadyTracked else { return nil }
        var result = existing
        if !result.isEmpty && !result.hasSuffix("\n") { result += "\n" }
        return result + lfsRule(for: pattern) + "\n"
    }
}
