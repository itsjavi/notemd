import Foundation

extension URL {
    /// The real path (symlinks resolved, `/tmp` → `/private/tmp`), matching what FSEvents reports.
    /// Unlike `resolvingSymlinksInPath()`, it never strips `/private`. Missing items keep their
    /// last component under the canonical parent.
    public var canonical: URL {
        let path = (self.path as NSString).standardizingPath
        guard let resolved = realpath(path, nil) else {
            let parent = deletingLastPathComponent()
            guard parent.path != path, !parent.path.isEmpty, parent.path != "/" || path != "/" else { return URL(fileURLWithPath: path) }
            return parent.canonical.appendingPathComponent(lastPathComponent, isDirectory: hasDirectoryPath)
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: hasDirectoryPath)
    }
}

/// Writes note files without losing their identity.
public enum SafeFileWriter {
    /// Replaces the contents of `url` atomically while keeping its creation date, Finder tags
    /// and other metadata (a plain atomic write swaps in a new file). New files are written directly.
    public static func write(_ data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            // Foundation traps on `.atomic` combined with `.withoutOverwriting`.
            try data.write(to: url, options: .withoutOverwriting)
            return
        }
        let directory = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        defer { try? fileManager.removeItem(at: directory) }
        let temporary = directory.appendingPathComponent(url.lastPathComponent)
        try data.write(to: temporary)
        _ = try fileManager.replaceItemAt(url, withItemAt: temporary, backupItemName: nil, options: [])
    }

    /// Whether `relativePath` is a plain path inside a repository (no `..`, not absolute, no hidden parts).
    public static func isSafeRelativePath(_ relativePath: String) -> Bool {
        if relativePath.isEmpty { return true }
        guard !relativePath.hasPrefix("/"), !relativePath.hasPrefix("~") else { return false }
        return relativePath.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part != ".." && part != "." && !part.hasPrefix(".")
        }
    }
}
