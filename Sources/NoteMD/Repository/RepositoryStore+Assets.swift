import AppKit
import NoteMDCore

/// A file in the repository's `assets/` folder.
struct AssetFile: Identifiable, Hashable {
    var id: String { path }
    /// Repository-relative path.
    let path: String
    let url: URL
    let size: Int
    let modified: Date
}

enum AssetFilter: String, CaseIterable, Identifiable {
    case all, unused, missing
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .unused: "Unused"
        case .missing: "Missing"
        }
    }
}

/// One row of the Assets view: a file in `assets/`, or a path that notes link but that doesn't exist.
struct AssetRow: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let file: AssetFile?
    /// Notes linking the file, sorted by path.
    let notes: [String]
    var isMissing: Bool { file == nil }
    var name: String { (path as NSString).lastPathComponent }
}

/// Deleted files a restored note links, offered for restoring with it.
struct PendingAssetRestore: Identifiable {
    let id = UUID()
    let notePath: String
    let files: [GitDeletedFile]
}

/// Assets (TASK-33, decision-5): the Markdown links in the notes are the only record of which note uses which file.
/// The reference index is rebuilt from them, so editing notes elsewhere, pulling or moving files in Finder can't
/// leave it out of date. Editing a note never deletes a file; only Move to Bin and Clean Up do, after confirmation.
extension RepositoryStore {
    // MARK: Listing

    func refreshAssetFiles() {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var files: [AssetFile] = []
        if let enumerator = FileManager.default.enumerator(at: assetsURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                files.append(AssetFile(path: relativePath(of: url), url: url, size: values.fileSize ?? 0, modified: values.contentModificationDate ?? .distantPast))
            }
        }
        files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        if files != assetFiles { assetFiles = files }
        assetsRevision += 1
    }

    func assetRows(_ filter: AssetFilter) -> [AssetRow] {
        let listed = Set(assetFiles.map(\.path))
        var rows = assetFiles.map { AssetRow(path: $0.path, file: $0, notes: assetIndex.notes(referencing: $0.path)) }
        let missing = assetIndex.referencedPaths.filter { !listed.contains($0) && !fileExists($0) }
        rows += missing.sorted().map { AssetRow(path: $0, file: nil, notes: assetIndex.notes(referencing: $0)) }
        switch filter {
        case .all: return rows
        case .unused: return rows.filter { !$0.isMissing && $0.notes.isEmpty }
        case .missing: return rows.filter(\.isMissing)
        }
    }

    /// The files a note links, with whether each exists.
    func attachments(ofNoteAt path: String) -> [NoteAttachment] {
        _ = assetsRevision  // re-check existence when files come and go
        return assetIndex.attachments(of: path, fileExists: fileExists)
    }

    func fileURL(for link: AssetLink) -> URL {
        switch link.location {
        case .repository(let path): rootURL.appendingPathComponent(path)
        case .external(let path): URL(fileURLWithPath: path)
        }
    }

    private func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: rootURL.appendingPathComponent(path).path)
    }

    func openNote(_ path: String) {
        sidebarSelection = .allNotes
        selectedNoteID = path
    }

    // MARK: Changing notes

    /// Applies `transform` to the full text of the note at `path` as one edit: undoable in the editor when the note
    /// is open, straight in the file otherwise.
    func rewriteNote(at path: String, _ transform: (String) -> String) {
        let current: String
        if let editor, editor.path == path {
            current = editor.fullText
        } else {
            guard SafeFileWriter.isSafeRelativePath(path), let text = RepositoryScanner.readText(rootURL.appendingPathComponent(path)) else { return }
            current = text
        }
        guard let change = Self.change(from: current, to: transform(current)) else { return }
        replace(change.range, with: change.replacement, inNoteAt: path)
        // Save now so the reference index sees the edit.
        if let editor, editor.path == path { editor.save() }
    }

    /// The smallest single range turning `old` into `new`, kept off the middle of surrogate pairs.
    static func change(from old: String, to new: String) -> (range: NSRange, replacement: String)? {
        guard old != new else { return nil }
        let a = old as NSString
        let b = new as NSString
        var start = 0
        while start < min(a.length, b.length) && a.character(at: start) == b.character(at: start) { start += 1 }
        var endA = a.length
        var endB = b.length
        while endA > start && endB > start && a.character(at: endA - 1) == b.character(at: endB - 1) {
            endA -= 1
            endB -= 1
        }
        if start > 0 && UTF16.isLeadSurrogate(a.character(at: start - 1)) { start -= 1 }
        if endA < a.length && UTF16.isTrailSurrogate(a.character(at: endA)) {
            endA += 1
            endB += 1
        }
        return (NSRange(location: start, length: endA - start), b.substring(with: NSRange(location: start, length: endB - start)))
    }

    /// Removes the links to `assetPath` from a note; the file stays (and shows under Unused when nothing else uses it).
    func unlinkAsset(_ assetPath: String, fromNoteAt notePath: String) {
        let root = rootURL.path
        rewriteNote(at: notePath) { AssetReferences.unlinking(assetPath, in: $0, notePath: notePath, rootPath: root) }
    }

    // MARK: Managing files

    /// Renames the file and points every note that links it at the new name.
    func renameAsset(_ path: String, to name: String) {
        let old = rootURL.appendingPathComponent(path)
        guard SafeFileWriter.isSafeRelativePath(path), FileManager.default.fileExists(atPath: old.path) else { return }
        let ext = old.pathExtension
        var base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ext.isEmpty, base.lowercased().hasSuffix("." + ext.lowercased()) { base = String(base.dropLast(ext.count + 1)) }
        base = NoteFileName.sanitized(base, fallback: old.deletingPathExtension().lastPathComponent)
        let target = NoteFileName.uniqueURL(in: old.deletingLastPathComponent(), base: base, pathExtension: ext.isEmpty ? nil : ext, excluding: old)
        guard target.lastPathComponent != old.lastPathComponent else { return }
        let users = assetIndex.notes(referencing: path)
        do {
            try FileManager.default.moveItem(at: old, to: target)
        } catch {
            errorMessage = "Couldn't rename “\(old.lastPathComponent)”: \(error.localizedDescription)"
            return
        }
        let newPath = relativePath(of: target)
        let root = rootURL.path
        for note in users {
            rewriteNote(at: note) { AssetReferences.renaming(path, to: newPath, in: $0, notePath: note, rootPath: root) }
        }
        if selectedAssetPath == path { selectedAssetPath = newPath }
        refreshAssetFiles()
    }

    /// Moves files to the Bin and removes their links from the notes that use them.
    func trashAssets(_ paths: [String]) {
        for path in paths {
            let url = rootURL.appendingPathComponent(path)
            guard SafeFileWriter.isSafeRelativePath(path), FileManager.default.fileExists(atPath: url.path) else { continue }
            let users = assetIndex.notes(referencing: path)
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                errorMessage = "Couldn't move “\(url.lastPathComponent)” to the Bin: \(error.localizedDescription)"
                continue
            }
            for note in users { unlinkAsset(path, fromNoteAt: note) }
            if selectedAssetPath == path { selectedAssetPath = nil }
        }
        refreshAssetFiles()
    }
}
