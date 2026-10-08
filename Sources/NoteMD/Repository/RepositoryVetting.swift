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

    /// Home and its standard folders, iCloud Drive and cloud storage roots, the volume roots.
    nonisolated static func isTopLevel(_ root: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.canonical.path
        let path = root.canonical.path
        let standard = ["Documents", "Desktop", "Downloads", "Library", "Developer", "Pictures", "Music", "Movies", "Public",
                        "Library/Mobile Documents", "Library/Mobile Documents/com~apple~CloudDocs", "Library/CloudStorage"]
        if path == "/" || path == home || standard.contains(where: { path == home + "/" + $0 }) { return true }
        // Dropbox, Google Drive… roots.
        if (path as NSString).deletingLastPathComponent == home + "/Library/CloudStorage" { return true }
        return !path.hasPrefix(home + "/") && path.split(separator: "/").count <= 2
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

    /// Puts the notes of `root` in `files/` (decision-8) when NoteMD may, and returns the layout to use. A marked
    /// repository gets anything that turned up at its root moved back in. An unmarked one is moved and marked only when
    /// `mayRearrange` (see `mayRearrange(_:)`) and its root isn't mostly other files; otherwise its notes stay at the
    /// root. Top-level folders are never touched. `moved` is true when entries were moved; `error` explains a move
    /// that stopped halfway.
    nonisolated static func prepareLayout(_ root: URL, mayRearrange: Bool) -> (layout: RepositoryLayout, moved: Bool, error: Error?) {
        guard !isTopLevel(root) else { return (.root, false, nil) }
        do {
            if RepositoryLayout.hasFilesMarker(at: root) {
                let strays = RepositoryLayout.strayEntries(at: root)
                guard !strays.isEmpty, otherFileCount(strays) == nil else { return (RepositoryLayout.existing(at: root), false, nil) }
                return (try RepositoryLayout.moveIntoNotesFolder(strays, at: root), true, nil)
            }
            if RepositoryLayout.existing(at: root).contentFolder != nil {
                try RepositoryLayout.markFilesLayout(at: root)
                return (RepositoryLayout.existing(at: root), false, nil)
            }
            guard mayRearrange || RepositoryLayout.isMoveInterrupted(at: root) else { return (.root, false, nil) }
            let entries = RepositoryLayout.unmarkedEntries(at: root)
            if !entries.isEmpty, otherFileCount(entries) != nil, !RepositoryLayout.isMoveInterrupted(at: root) { return (.root, false, nil) }
            return (try RepositoryLayout.moveIntoFilesFolder(at: root), !entries.isEmpty, nil)
        } catch {
            return (RepositoryLayout.existing(at: root), false, error)
        }
    }

    /// Whether NoteMD may move an unmarked folder's notes into `files/`: a plain folder, or a git repository NoteMD
    /// started (its first commit) or styled (`.notemd.json` files). Never a folder inside another git repository or
    /// another project's repository (code, another app's vault), whose files would move under someone else's feet.
    static func mayRearrange(_ root: URL) async -> Bool {
        if hasGitAncestor(root) { return false }
        let isGitRoot = FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path)
        guard isGitRoot else { return true }
        if hasFolderAppearance(root) { return true }
        guard let executable = GitClient.locateGit() else { return false }
        let client = GitClient(repositoryURL: root, executableURL: executable)
        guard await client.isRepositoryRoot() else { return false }
        let started = try? await client.run(["log", "--format=%s", "--fixed-strings", "--grep=Start versioning notes with NoteMD", "-1"])
        return started?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// A `.git` in a folder above `root`.
    nonisolated private static func hasGitAncestor(_ root: URL) -> Bool {
        var folder = root.canonical.deletingLastPathComponent()
        while folder.path != "/" {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) { return true }
            folder = folder.deletingLastPathComponent()
        }
        return false
    }

    /// NoteMD's folder appearance files at the root or in a folder right below it.
    nonisolated private static func hasFolderAppearance(_ root: URL) -> Bool {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: root.appendingPathComponent(FolderAppearance.fileName).path) { return true }
        let names = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        return names.contains { !$0.hasPrefix(".") && fileManager.fileExists(atPath: root.appendingPathComponent($0).appendingPathComponent(FolderAppearance.fileName).path) }
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
