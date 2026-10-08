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

    /// NoteMD's mark on a repository in this layout: `"layout": "files"` in the root's `.notemd.json`. It's committed
    /// with the notes, so clones and later opens never mistake a user's own `files` folder for the notes folder.
    static let markerText = "{\n  \"layout\" : \"files\"\n}\n"
    /// Where an unmarked repository's entries gather before becoming `files/`; a move cut short resumes from it.
    static let stagingFolderName = ".notemd-moving"

    public static func hasFilesMarker(at root: URL) -> Bool {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(FolderAppearance.fileName)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["layout"] as? String == filesFolderName
    }

    /// Whether moving the notes into `files/` stopped halfway (e.g. a crash) and should finish.
    public static func isMoveInterrupted(at root: URL) -> Bool {
        isDirectory(root.appendingPathComponent(stagingFolderName))
    }

    /// The layout `root` has now, changing nothing: its notes folder (in any letter case) when the repository is
    /// marked, or when that folder is the only thing at the root that isn't hidden; else the root.
    public static func existing(at root: URL) -> RepositoryLayout {
        guard let folder = notesFolderName(at: root) else { return .root }
        guard hasFilesMarker(at: root) || visibleEntries(at: root, except: folder).isEmpty else { return .root }
        return RepositoryLayout(contentFolder: folder)
    }

    /// Root entries that belong in a marked repository's notes folder: everything that isn't hidden.
    public static func strayEntries(at root: URL) -> [URL] {
        visibleEntries(at: root, except: notesFolderName(at: root))
    }

    /// What an unmarked repository moves into `files/`: every root entry that isn't hidden, a `files` folder of its
    /// own included, and the root's folder appearance file.
    public static func unmarkedEntries(at root: URL) -> [URL] {
        var entries = visibleEntries(at: root, except: nil)
        let appearance = root.appendingPathComponent(FolderAppearance.fileName)
        if exists(appearance) && !hasFilesMarker(at: root) { entries.append(appearance) }
        return entries
    }

    /// Moves an unmarked repository's notes into a new `files/` folder and marks the repository. Entries gather in a
    /// hidden staging folder first, so a `Files` folder of the user's ends up inside the new one even on
    /// case-insensitive volumes, and a move cut short resumes on the next call.
    @discardableResult
    public static func moveIntoFilesFolder(at root: URL) throws -> RepositoryLayout {
        let staging = root.appendingPathComponent(stagingFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for entry in unmarkedEntries(at: root) { try move(entry, into: staging) }
        try FileManager.default.moveItem(at: staging, to: root.appendingPathComponent(filesFolderName, isDirectory: true))
        try writeFilesMarker(at: root)
        return RepositoryLayout(contentFolder: filesFolderName)
    }

    /// Marks a repository whose notes folder is already the only thing at its root (moved by an earlier version).
    /// A folder appearance file at the root moves into the notes folder first.
    public static func markFilesLayout(at root: URL) throws {
        guard !hasFilesMarker(at: root), let folder = notesFolderName(at: root) else { return }
        let appearance = root.appendingPathComponent(FolderAppearance.fileName)
        if exists(appearance) { try move(appearance, into: root.appendingPathComponent(folder, isDirectory: true)) }
        try writeFilesMarker(at: root)
    }

    private static func writeFilesMarker(at root: URL) throws {
        try Data(markerText.utf8).write(to: root.appendingPathComponent(FolderAppearance.fileName))
    }

    /// Moves `entries` into a marked repository's notes folder (created when missing) without overwriting anything:
    /// folders merge into existing ones and a taken file name gets a number. Returns the resulting layout.
    @discardableResult
    public static func moveIntoNotesFolder(_ entries: [URL], at root: URL) throws -> RepositoryLayout {
        let folder = notesFolderName(at: root) ?? filesFolderName
        let target = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for entry in entries { try move(entry, into: target) }
        return RepositoryLayout(contentFolder: folder)
    }

    /// The notes folder's name at `root` in any letter case, if there is one.
    private static func notesFolderName(at root: URL) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.sorted().first { $0.lowercased() == filesFolderName && isDirectory(root.appendingPathComponent($0)) }
    }

    /// Root entries that aren't hidden, other than `except`.
    private static func visibleEntries(at root: URL, except: String?) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.sorted().filter { !$0.hasPrefix(".") && $0 != except }.map { root.appendingPathComponent($0) }
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
            // Only when empty: something written meanwhile (a sync client) stays for the next pass.
            if (try? fileManager.contentsOfDirectory(atPath: item.path))?.isEmpty == true { try fileManager.removeItem(at: item) }
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
