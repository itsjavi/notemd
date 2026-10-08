import Foundation
import NoteMDCore

/// Guards against turning folders that hold more than notes into git repositories by accident.
enum RepositoryVetting {
    /// A reason to ask before `git init`, or nil when the folder looks like a notes folder.
    nonisolated static func reasonToConfirm(_ root: URL) -> String? {
        if isTopLevel(root) {
            return "“\(root.lastPathComponent)” is a top-level folder. Versioning it would record every file inside, not just notes."
        }
        if let others = otherFileCount([root]) {
            return "“\(root.lastPathComponent)” contains \(others) files that aren't notes. Versioning it would record all of them."
        }
        return nil
    }

    /// Home, Documents, Desktop…, the volume roots.
    nonisolated static func isTopLevel(_ root: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.canonical.path
        let path = root.canonical.path
        let sensitive = [home] + ["Documents", "Desktop", "Downloads", "Library", "Developer"].map { home + "/" + $0 }
        return path == "/" || sensitive.contains(path) || !path.hasPrefix(home + "/") && path.split(separator: "/").count <= 2
    }

    /// How many files that aren't notes `items` hold (folders counted recursively), when they're mostly such files.
    nonisolated static func otherFileCount(_ items: [URL]) -> Int? {
        var notes = 0
        var others = 0
        let count = { (url: URL) in
            if NoteMDCore.noteExtensions.contains(url.pathExtension.lowercased()) { notes += 1 } else { others += 1 }
        }
        for item in items {
            guard let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]), values.isDirectory == true, values.isPackage != true else {
                count(item)
                continue
            }
            guard let enumerator = FileManager.default.enumerator(at: item, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                if url.lastPathComponent == "node_modules" { enumerator.skipDescendants(); others += 100; continue }
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                count(url)
                if notes + others > 5000 { break }
            }
        }
        return others > 200 && others > notes * 2 ? others : nil
    }

    /// Moves what sits at the root of `root` into its notes folder (decision-8), creating it, unless the folder is one
    /// NoteMD must not rearrange: a top-level folder, or one whose root holds mostly other files. Those keep their
    /// current layout. `moved` is true when entries were moved; `error` explains a move that stopped halfway.
    nonisolated static func prepareLayout(_ root: URL) -> (layout: RepositoryLayout, moved: Bool, error: Error?) {
        guard !isTopLevel(root) else { return (.root, false, nil) }
        let strays = RepositoryLayout.strayEntries(at: root)
        if !strays.isEmpty, otherFileCount(strays) != nil { return (RepositoryLayout.existing(at: root), false, nil) }
        do {
            return (try RepositoryLayout.moveIntoNotesFolder(strays, at: root), !strays.isEmpty, nil)
        } catch {
            return (RepositoryLayout.existing(at: root), false, error)
        }
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
