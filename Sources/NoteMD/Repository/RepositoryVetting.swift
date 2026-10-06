import Foundation
import NoteMDCore

/// Guards against turning folders that hold more than notes into git repositories by accident.
enum RepositoryVetting {
    /// A reason to ask before `git init`, or nil when the folder looks like a notes folder.
    nonisolated static func reasonToConfirm(_ root: URL) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.canonical.path
        let path = root.canonical.path
        let sensitive = [home] + ["Documents", "Desktop", "Downloads", "Library", "Developer"].map { home + "/" + $0 }
        if path == "/" || sensitive.contains(path) || !path.hasPrefix(home + "/") && path.split(separator: "/").count <= 2 {
            return "“\(root.lastPathComponent)” is a top-level folder. Versioning it would record every file inside, not just notes."
        }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        var notes = 0
        var others = 0
        for case let url as URL in enumerator {
            if url.lastPathComponent == "node_modules" { enumerator.skipDescendants(); others += 100; continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            if NoteMDCore.noteExtensions.contains(url.pathExtension.lowercased()) { notes += 1 } else { others += 1 }
            if notes + others > 5000 { break }
        }
        if others > 200 && others > notes * 2 {
            return "“\(root.lastPathComponent)” contains \(others) files that aren't notes. Versioning it would record all of them."
        }
        return nil
    }

    /// Adds ignore rules for secrets and build output to a new repository's .gitignore.
    nonisolated static func extendGitignore(at root: URL) {
        let url = root.appendingPathComponent(".gitignore")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let rules = [".DS_Store", ".env", ".env.*", "*.pem", "*.key", "node_modules/", ".build/"]
        let missing = rules.filter { rule in !existing.split(whereSeparator: \.isNewline).contains { $0 == rule } }
        guard !missing.isEmpty else { return }
        let prefix = existing.isEmpty || existing.hasSuffix("\n") ? existing : existing + "\n"
        try? (prefix + missing.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
