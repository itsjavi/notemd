import Foundation

/// A git invocation that exited with a non-zero status (or could not be launched, `exitCode == -1`).
public struct GitError: Error, LocalizedError, Sendable {
    public let arguments: [String]
    public let exitCode: Int32
    public let stderr: String

    public init(arguments: [String], exitCode: Int32, stderr: String) {
        self.arguments = arguments
        self.exitCode = exitCode
        self.stderr = stderr
    }

    public var errorDescription: String? {
        let command = (["git"] + arguments).joined(separator: " ")
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty
            ? "\(command) failed with exit code \(exitCode)."
            : "\(command) failed with exit code \(exitCode): \(detail)"
    }
}

/// One entry of `git status --porcelain`. Paths are relative to the repository root.
public struct GitStatusEntry: Sendable, Hashable {
    public enum Kind: Sendable {
        case added, modified, deleted, renamed, untracked, other
    }

    public let kind: Kind
    public let path: String
    /// Source path of a rename or copy.
    public let originalPath: String?

    public init(kind: Kind, path: String, originalPath: String? = nil) {
        self.kind = kind
        self.path = path
        self.originalPath = originalPath
    }
}

public struct GitCommit: Sendable, Hashable, Identifiable {
    /// Full SHA.
    public let id: String
    public let shortID: String
    public let date: Date
    public let authorName: String
    public let subject: String
    /// Path the file had in this commit (file history only).
    public let path: String?
    /// How the file changed in this commit (file history only).
    public let changeKind: GitStatusEntry.Kind?
    /// Added/deleted line counts for the file; nil for binary files or commit-level queries.
    public let additions: Int?
    public let deletions: Int?

    public init(
        id: String,
        shortID: String,
        date: Date,
        authorName: String,
        subject: String,
        path: String? = nil,
        changeKind: GitStatusEntry.Kind? = nil,
        additions: Int? = nil,
        deletions: Int? = nil
    ) {
        self.id = id
        self.shortID = shortID
        self.date = date
        self.authorName = authorName
        self.subject = subject
        self.path = path
        self.changeKind = changeKind
        self.additions = additions
        self.deletions = deletions
    }
}

/// A file deleted somewhere in history and not present again at HEAD or on disk.
public struct GitDeletedFile: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public let path: String
    public let deletedIn: GitCommit
    /// Revision (full SHA of the deleting commit's first parent) that still has the file.
    public let lastRevision: String

    public init(path: String, deletedIn: GitCommit, lastRevision: String) {
        self.path = path
        self.deletedIn = deletedIn
        self.lastRevision = lastRevision
    }
}
