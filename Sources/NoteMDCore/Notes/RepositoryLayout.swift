import Foundation

/// Where a repository keeps its notes (decision-8): in a `files/` folder, so NoteMD can keep its own sibling folders
/// (such as `.incognito/`) next to them, or at the root for folders NoteMD never rearranges.
///
/// Note paths throughout the app are relative to the notes folder; git paths are relative to the repository root.
public struct RepositoryLayout: Sendable, Hashable {
    public static let filesFolderName = "files"
    public static let root = RepositoryLayout(contentFolder: nil)

    /// The notes folder's name as it is on disk (`files`, or e.g. `Files` on a case-insensitive volume); nil when
    /// notes live at the root.
    public let contentFolder: String?

    public init(contentFolder: String?) {
        self.contentFolder = contentFolder
    }

    /// Git path prefix of note paths: `files/`, or "" at the root.
    public var contentPrefix: String { contentFolder.map { $0 + "/" } ?? "" }

    public func contentURL(in root: URL) -> URL {
        contentFolder.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
    }

    /// The git path of a note path.
    public func repositoryPath(forContentPath path: String) -> String {
        path.isEmpty ? (contentFolder ?? "") : contentPrefix + path
    }

    /// The note path of a git path. Paths outside the notes folder that aren't hidden are from before the notes
    /// moved into it, when the root held them; hidden root entries (`.gitignore`, `.incognito/`…) give nil.
    public func contentPath(forRepositoryPath path: String) -> String? {
        guard let contentFolder else { return path }
        if path.count > contentFolder.count, path.lowercased().hasPrefix(contentFolder.lowercased() + "/") {
            return String(path.dropFirst(contentFolder.count + 1))
        }
        return path.hasPrefix(".") || path.lowercased() == contentFolder.lowercased() ? nil : path
    }

    // MARK: Incognito notes

    /// NoteMD's folder for incognito notes, next to the notes folder: never committed and deleted when the repository
    /// closes. Their note paths keep this prefix (`.incognito/Idea.md`), which no scanned note path can have.
    public static let incognitoFolderName = ".incognito"

    public static func isIncognitoPath(_ path: String) -> Bool {
        path == incognitoFolderName || path.hasPrefix(incognitoFolderName + "/")
    }

    /// A note path that stays inside the repository: a plain relative path, or one inside `.incognito/`.
    public static func isSafeNotePath(_ path: String) -> Bool {
        guard path.hasPrefix(incognitoFolderName + "/") else { return SafeFileWriter.isSafeRelativePath(path) }
        let rest = String(path.dropFirst(incognitoFolderName.count + 1))
        return !rest.isEmpty && SafeFileWriter.isSafeRelativePath(rest)
    }

    /// Creates `.incognito/` with a `.gitignore` ignoring everything in it (itself included), so git never records
    /// it, whatever the repository's own ignore rules say and even inside another repository.
    @discardableResult
    public static func prepareIncognitoFolder(at root: URL) throws -> URL {
        let folder = root.appendingPathComponent(incognitoFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ignore = folder.appendingPathComponent(".gitignore")
        if !FileManager.default.fileExists(atPath: ignore.path) {
            try Data("*\n".utf8).write(to: ignore)
        }
        return folder
    }

    /// Deletes `.incognito/` and everything in it, for good (not to the Bin).
    public static func discardIncognitoFolder(at root: URL) {
        let folder = root.appendingPathComponent(incognitoFolderName, isDirectory: true)
        guard isDirectory(folder) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: On disk

    /// The layout `root` has now: its notes folder in any letter case, else the root.
    public static func existing(at root: URL) -> RepositoryLayout {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let folder = names.sorted().first { name in
            name.lowercased() == filesFolderName && isDirectory(root.appendingPathComponent(name))
        }
        return RepositoryLayout(contentFolder: folder)
    }

    /// Root entries that belong in the notes folder: everything that isn't hidden, plus the root's folder appearance
    /// file when the notes folder has none.
    public static func strayEntries(at root: URL) -> [URL] {
        let layout = existing(at: root)
        let notesAppearance = layout.contentURL(in: root).appendingPathComponent(FolderAppearance.fileName)
        let hasNotesAppearance = layout.contentFolder != nil && FileManager.default.fileExists(atPath: notesAppearance.path)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.sorted().filter { name in
            if name == layout.contentFolder { return false }
            if name == FolderAppearance.fileName { return !hasNotesAppearance }
            return !name.hasPrefix(".")
        }.map { root.appendingPathComponent($0) }
    }

    /// Moves `entries` into the notes folder (created when missing) without overwriting anything: folders merge into
    /// existing ones and a taken file name gets a number. Returns the resulting layout.
    @discardableResult
    public static func moveIntoNotesFolder(_ entries: [URL], at root: URL) throws -> RepositoryLayout {
        var layout = existing(at: root)
        if layout.contentFolder == nil {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(filesFolderName), withIntermediateDirectories: false)
            layout = RepositoryLayout(contentFolder: filesFolderName)
        }
        let target = layout.contentURL(in: root)
        for entry in entries { try move(entry, into: target) }
        return layout
    }

    private static func move(_ item: URL, into directory: URL) throws {
        let fileManager = FileManager.default
        let destination = directory.appendingPathComponent(item.lastPathComponent)
        guard exists(destination) else {
            try fileManager.moveItem(at: item, to: destination)
            return
        }
        if isDirectory(item) && isDirectory(destination) {
            for child in try fileManager.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) {
                try move(child, into: destination)
            }
            try fileManager.removeItem(at: item)
        } else if item.lastPathComponent == ".DS_Store" {
            try fileManager.removeItem(at: item)
        } else {
            try fileManager.moveItem(at: item, to: Attachments.uniqueURL(in: directory, fileName: item.lastPathComponent))
        }
    }

    /// Whether something (even a broken symlink) is at `url`.
    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// A real directory, not a symlink to one.
    private static func isDirectory(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory
    }
}
