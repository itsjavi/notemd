import Foundation

/// Builds commit messages from `git status` entries.
///
/// - One entry: `Create a.md`, `Update a.md`, `Delete a.md` or `Rename a.md → b.md`.
/// - Several: `Update N files`, a blank line, then one `- Create a.md` style line per entry, sorted by path.
///
/// Paths starting with `prefix` (the notes folder, `files/`) are shown without it.
public enum CommitMessageBuilder {
    public static func message(for entries: [GitStatusEntry], strippingPrefix prefix: String = "") -> String {
        let sorted = entries.sorted { $0.path < $1.path }
        switch sorted.count {
        case 0: return "Update files"
        case 1: return description(of: sorted[0], strippingPrefix: prefix)
        default:
            let body = sorted.map { "- \(description(of: $0, strippingPrefix: prefix))" }.joined(separator: "\n")
            return "Update \(sorted.count) files\n\n\(body)"
        }
    }

    static func description(of entry: GitStatusEntry, strippingPrefix prefix: String = "") -> String {
        let display = { (path: String) in !prefix.isEmpty && path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path }
        let path = display(entry.path)
        switch entry.kind {
        case .added, .untracked: return "Create \(path)"
        case .deleted: return "Delete \(path)"
        case .renamed:
            if let originalPath = entry.originalPath { return "Rename \(display(originalPath)) → \(path)" } else { return "Rename \(path)" }
        case .modified, .other: return "Update \(path)"
        }
    }
}
