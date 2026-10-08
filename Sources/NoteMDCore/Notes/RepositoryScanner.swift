import Foundation

/// A point-in-time view of a notes repository on disk.
public struct RepositorySnapshot: Sendable {
    public var root: Folder
    public var notes: [Note]

    public init(root: Folder, notes: [Note]) {
        self.root = root
        self.notes = notes
    }

    public var allTags: [(tag: String, count: Int)] {
        var counts: [String: (display: String, count: Int)] = [:]
        for note in notes {
            for tag in note.tags {
                let key = tag.lowercased()
                counts[key, default: (tag, 0)].count += 1
            }
        }
        return counts.values.map { ($0.display, $0.count) }.sorted { $0.tag.localizedStandardCompare($1.tag) == .orderedAscending }
    }
}

/// Scans a repository folder for notes and sub-folders.
public enum RepositoryScanner {
    /// Folders never shown as note folders.
    static let ignoredDirectories: Set<String> = ["node_modules"]

    /// Scans `rootURL`. Notes whose size and modification date match `previous` are reused without re-reading.
    public static func scan(rootURL: URL, previous: [String: Note] = [:]) throws -> RepositorySnapshot {
        let root = rootURL.canonical
        var notes: [Note] = []
        let tree = try scanFolder(root, relativePath: "", name: root.lastPathComponent, previous: previous, notes: &notes)
        return RepositorySnapshot(root: tree, notes: notes)
    }

    private static func scanFolder(_ url: URL, relativePath: String, name: String, previous: [String: Note], notes: inout [Note]) throws -> Folder {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .creationDateKey, .fileSizeKey, .isPackageKey]
        let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        var folder = Folder(path: relativePath, name: name, appearance: FolderAppearance.load(from: url))
        var children: [Folder] = []
        for item in contents {
            let values = try? item.resourceValues(forKeys: Set(keys))
            let itemName = item.lastPathComponent
            let itemPath = relativePath.isEmpty ? itemName : relativePath + "/" + itemName
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                if values?.isPackage == true || ignoredDirectories.contains(itemName) { continue }
                // Attachments, not a note folder.
                if relativePath.isEmpty && itemName.lowercased() == Attachments.folderName { continue }
                if let child = try? scanFolder(item, relativePath: itemPath, name: itemName, previous: previous, notes: &notes) {
                    children.append(child)
                }
                continue
            }
            guard NoteMDCore.noteExtensions.contains(item.pathExtension.lowercased()) else { continue }
            if let note = note(at: item, path: itemPath, values: values, previous: previous) { notes.append(note) }
            folder.noteCount += 1
        }
        folder.children = children.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        folder.totalNoteCount = folder.noteCount + folder.children.reduce(0) { $0 + $1.totalNoteCount }
        return folder
    }

    /// The notes directly inside `directory` (sub-folders aren't read), with paths starting `pathPrefix/`.
    /// Empty when the folder doesn't exist.
    public static func scanNotes(in directory: URL, pathPrefix: String, previous: [String: Note] = [:]) -> [Note] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .creationDateKey, .fileSizeKey]
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory.canonical, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return contents.compactMap { item in
            let values = try? item.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, values?.isSymbolicLink != true,
                  NoteMDCore.noteExtensions.contains(item.pathExtension.lowercased()) else { return nil }
            return note(at: item, path: pathPrefix + "/" + item.lastPathComponent, values: values, previous: previous)
        }
    }

    /// The note at `item`, reusing `previous[path]` when its size and modification date still match.
    private static func note(at item: URL, path: String, values: URLResourceValues?, previous: [String: Note]) -> Note? {
        let modified = values?.contentModificationDate ?? .distantPast
        let size = values?.fileSize ?? 0
        if let cached = previous[path], cached.modified == modified, cached.size == size { return cached }
        guard let text = readText(item) else { return nil }
        return Note(path: path, url: item, text: text, modified: modified, created: values?.creationDate ?? modified, size: size)
    }

    /// Reads a text file as UTF-8, falling back to other common encodings.
    public static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }
        var encoding = String.Encoding.utf8
        if let text = try? String(contentsOf: url, usedEncoding: &encoding) { return text }
        return String(data: data, encoding: .windowsCP1252)
    }
}
