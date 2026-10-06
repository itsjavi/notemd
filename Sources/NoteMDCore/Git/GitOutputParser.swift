import Foundation

/// Parsers for NUL-separated (`-z`) git output. Working on bytes keeps paths with spaces, quotes,
/// newlines or non-ASCII characters intact.
enum GitOutputParser {
    // MARK: Status

    struct StatusRecord: Equatable {
        /// Porcelain v1 `X` (index) and `Y` (work tree) status letters.
        let index: UInt8
        let workTree: UInt8
        let entry: GitStatusEntry

        /// Whether the index differs from HEAD for this path.
        var isStaged: Bool { ![UInt8(ascii: " "), UInt8(ascii: "?"), UInt8(ascii: "!")].contains(index) }
    }

    /// Parses `git status --porcelain=v1 -z`: `XY PATH\0`, with renames/copies as `XY PATH\0ORIG\0`.
    static func statusRecords(_ data: Data) -> [StatusRecord] {
        let tokens = data.split(separator: 0, omittingEmptySubsequences: true)
        var records: [StatusRecord] = []
        var cursor = 0
        while cursor < tokens.count {
            let token = tokens[cursor]
            cursor += 1
            guard token.count > 3 else { continue }
            let x = token[token.startIndex]
            let y = token[token.startIndex + 1]
            let path = decode(token.dropFirst(3))
            var originalPath: String?
            if [x, y].contains(where: { $0 == letterR || $0 == letterC }), cursor < tokens.count {
                originalPath = decode(tokens[cursor])
                cursor += 1
            }
            let entry = GitStatusEntry(kind: statusKind(index: x, workTree: y), path: path, originalPath: originalPath)
            records.append(StatusRecord(index: x, workTree: y, entry: entry))
        }
        return records
    }

    static func statusKind(index x: UInt8, workTree y: UInt8) -> GitStatusEntry.Kind {
        switch (Character(Unicode.Scalar(x)), Character(Unicode.Scalar(y))) {
        case ("?", "?"): .untracked
        case ("!", "!"), ("U", _), (_, "U"), ("A", "A"), ("D", "D"): .other  // ignored / unmerged
        case ("R", _), (_, "R"): .renamed
        case ("A", "D"): .other  // added to the index, then removed from disk: nothing to version
        case ("A", _), (_, "A"), ("C", _), (_, "C"): .added
        case ("D", _), (_, "D"): .deleted
        default: .modified  // M, T
        }
    }

    // MARK: Log

    /// `git log --format` producing one header token per commit: RS, then US-separated fields.
    /// The subject goes last so it can never shift the other fields.
    static let logFormat = "%x1e%H%x1f%h%x1f%at%x1f%an%x1f%P%x1f%s"

    struct Change: Equatable {
        var kind: GitStatusEntry.Kind
        var path: String
        var originalPath: String?
        var additions: Int?
        var deletions: Int?
    }

    struct LogRecord: Equatable {
        var id: String
        var shortID: String
        var date: Date
        var authorName: String
        var parents: [String]
        var subject: String
        var changes: [Change] = []

        func commit(for change: Change?) -> GitCommit {
            GitCommit(
                id: id, shortID: shortID, date: date, authorName: authorName, subject: subject,
                path: change?.path, changeKind: change?.kind,
                additions: change?.additions, deletions: change?.deletions
            )
        }
    }

    /// Parses `git log --format=<logFormat> -z [--raw] [--numstat]`.
    ///
    /// Layout per commit: `RS fields \0`, then optionally `\n` followed by raw entries
    /// (`:modes shas STATUS\0path\0` or `...R100\0src\0dst\0`) and numstat entries
    /// (`add\tdel\tpath\0` or `add\tdel\t\0src\0dst\0`).
    static func logRecords(_ data: Data) -> [LogRecord] {
        let tokens = data.split(separator: 0, omittingEmptySubsequences: false)
        var records: [LogRecord] = []
        var cursor = 0

        func take() -> String? {
            guard cursor < tokens.count else { return nil }
            defer { cursor += 1 }
            return decode(tokens[cursor])
        }

        while cursor < tokens.count {
            var token = tokens[cursor]
            cursor += 1
            // A newline separates a commit header from its diff section.
            while token.first == newline { token = token.dropFirst() }
            guard let first = token.first else { continue }

            if first == recordSeparator {
                if let record = parseHeader(token.dropFirst()) { records.append(record) }
                continue
            }
            guard !records.isEmpty else { continue }

            if first == colon {
                // Raw entry: the status is the last space-separated field, e.g. "M", "R087", "D".
                let status = token.split(separator: space).last?.first ?? 0
                let kind = rawKind(status)
                if status == letterR || status == letterC {
                    guard let source = take(), let destination = take() else { break }
                    records[records.count - 1].changes.append(
                        Change(kind: kind, path: destination, originalPath: source))
                } else {
                    guard let path = take() else { break }
                    records[records.count - 1].changes.append(Change(kind: kind, path: path))
                }
                continue
            }

            // Numstat entry.
            let parts = token.split(separator: tab, maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let additions = Int(decode(parts[0]))
            let deletions = Int(decode(parts[1]))
            var path = decode(parts[2])
            if parts[2].isEmpty {
                guard take() != nil, let destination = take() else { break }
                path = destination
            }
            var changes = records[records.count - 1].changes
            if let index = changes.firstIndex(where: { $0.path == path && $0.additions == nil && $0.deletions == nil }) {
                changes[index].additions = additions
                changes[index].deletions = deletions
                records[records.count - 1].changes = changes
            }
        }
        return records
    }

    private static func parseHeader(_ bytes: Data) -> LogRecord? {
        let fields = bytes.split(separator: unitSeparator, maxSplits: 5, omittingEmptySubsequences: false)
        guard fields.count == 6 else { return nil }
        let parents = decode(fields[4]).split(separator: " ").map(String.init)
        return LogRecord(
            id: decode(fields[0]),
            shortID: decode(fields[1]),
            date: Date(timeIntervalSince1970: TimeInterval(decode(fields[2])) ?? 0),
            authorName: decode(fields[3]),
            parents: parents,
            subject: decode(fields[5])
        )
    }

    private static func rawKind(_ status: UInt8) -> GitStatusEntry.Kind {
        switch Character(Unicode.Scalar(status)) {
        case "A", "C": .added
        case "M", "T": .modified
        case "D": .deleted
        case "R": .renamed
        default: .other
        }
    }

    static func decode<Bytes: Collection<UInt8>>(_ bytes: Bytes) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    private static let newline = UInt8(ascii: "\n")
    private static let tab = UInt8(ascii: "\t")
    private static let space = UInt8(ascii: " ")
    private static let colon = UInt8(ascii: ":")
    private static let letterR = UInt8(ascii: "R")
    private static let letterC = UInt8(ascii: "C")
    private static let recordSeparator: UInt8 = 0x1E
    private static let unitSeparator: UInt8 = 0x1F
}
