import Foundation

/// Namespace for shared constants of the UI-free core.
public enum NoteMDCore {
    /// File extensions treated as notes.
    public static let noteExtensions: Set<String> = ["md", "markdown"]
    /// Secret notes (decision-6): Markdown encrypted in the age format, `Name.md.age`.
    public static let secretNoteExtension = "md.age"

    /// Whether `path` names a secret note.
    public static func isSecretNotePath(_ path: String) -> Bool {
        path.lowercased().hasSuffix("." + secretNoteExtension)
    }

    /// Whether `path` names a note, plain or secret.
    public static func isNotePath(_ path: String) -> Bool {
        noteExtensions.contains((path as NSString).pathExtension.lowercased()) || isSecretNotePath(path)
    }
}
