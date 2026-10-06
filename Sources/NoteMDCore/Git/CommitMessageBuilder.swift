import Foundation

/// Builds commit messages from `git status` entries.
///
/// - One entry: `Create a.md`, `Update a.md`, `Delete a.md` or `Rename a.md → b.md`.
/// - Several: `Update N files`, a blank line, then one `- Create a.md` style line per entry, sorted by path.
public enum CommitMessageBuilder {
    public static func message(for entries: [GitStatusEntry]) -> String {
        let sorted = entries.sorted { $0.path < $1.path }
        switch sorted.count {
        case 0: return "Update files"
        case 1: return description(of: sorted[0])
        default:
            let body = sorted.map { "- \(description(of: $0))" }.joined(separator: "\n")
            return "Update \(sorted.count) files\n\n\(body)"
        }
    }

    static func description(of entry: GitStatusEntry) -> String {
        switch entry.kind {
        case .added, .untracked: "Create \(entry.path)"
        case .deleted: "Delete \(entry.path)"
        case .renamed:
            if let originalPath = entry.originalPath { "Rename \(originalPath) → \(entry.path)" } else { "Rename \(entry.path)" }
        case .modified, .other: "Update \(entry.path)"
        }
    }
}
