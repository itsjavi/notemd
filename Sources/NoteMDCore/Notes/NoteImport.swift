import Foundation

/// Markdown files from outside a notes folder, brought into one (opened from Finder or the Dock, or shared).
public enum NoteImport {
    public static func isMarkdown(_ url: URL) -> Bool {
        NoteMDCore.noteExtensions.contains(url.pathExtension.lowercased())
    }

    /// Copies or moves `file` into `directory` under its own name, numbered (`Name 2.md`) when that's taken.
    /// Returns the new file's URL.
    public static func importFile(_ file: URL, into directory: URL, move: Bool) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = NoteFileName.sanitized(file.deletingPathExtension().lastPathComponent)
        let target = NoteFileName.uniqueURL(in: directory, base: base, pathExtension: file.pathExtension)
        if move {
            try fileManager.moveItem(at: file, to: target)
        } else {
            try fileManager.copyItem(at: file, to: target)
        }
        return target
    }
}
