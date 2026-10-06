import Foundation

public struct DiffLine: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable {
        case context, added, removed
    }

    /// Unique within its `LineDiff`.
    public let id: Int
    public let kind: Kind
    /// Line content without its line terminator.
    public let text: String
    /// 1-based line number in the old text (nil for added lines).
    public let oldNumber: Int?
    /// 1-based line number in the new text (nil for removed lines).
    public let newNumber: Int?

    public init(id: Int, kind: Kind, text: String, oldNumber: Int?, newNumber: Int?) {
        self.id = id
        self.kind = kind
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
    }
}

public struct DiffHunk: Sendable, Hashable, Identifiable {
    public let id: Int
    /// Unified-diff ranges: 1-based start lines; when a count is 0 the start is the line *before* the change.
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    public let lines: [DiffLine]

    public init(id: Int, oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, lines: [DiffLine]) {
        self.id = id
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
    }

    /// `@@ -a,b +c,d @@`
    public var header: String { "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@" }
}

/// In-process line diff of two texts (Myers, via `CollectionDifference`), grouped into unified-diff hunks.
///
/// Lines are compared without their terminators: `\n`, `\r\n` and `\r` all end a line, and a missing final
/// newline is not a change. So texts that differ only in line endings produce an empty diff.
public struct LineDiff: Sendable {
    public let hunks: [DiffHunk]
    public let additions: Int
    public let deletions: Int
    public var isEmpty: Bool { hunks.isEmpty }

    public init(old: String, new: String, context: Int = 3) {
        let oldLines = Self.lines(of: old)
        let newLines = Self.lines(of: new)
        let operations = Self.operations(old: oldLines, new: newLines)
        additions = operations.count { $0.kind == .added }
        deletions = operations.count { $0.kind == .removed }
        hunks = Self.hunks(
            from: operations, old: oldLines, new: newLines, context: min(max(0, context), operations.count))
    }

    // MARK: Lines

    static func lines(of text: String) -> [Substring] {
        guard let last = text.last else { return [] }
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: isLineBreak)
        if isLineBreak(last) { lines.removeLast() }
        return lines
    }

    /// `\r\n` is a single `Character` in Swift, so it must be matched explicitly.
    private static func isLineBreak(_ character: Character) -> Bool {
        character == "\n" || character == "\r\n" || character == "\r"
    }

    // MARK: Edit script

    struct Operation: Equatable {
        enum Kind: Equatable { case context, added, removed }
        let kind: Kind
        /// 0-based indices into the old/new line arrays.
        let oldIndex: Int?
        let newIndex: Int?
    }

    static func operations(old: [Substring], new: [Substring]) -> [Operation] {
        // Trim the common prefix and suffix first: cheap, and keeps the Myers pass small for typical edits.
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
            old[old.count - 1 - suffix] == new[new.count - 1 - suffix]
        {
            suffix += 1
        }

        let oldMiddle = Array(old[prefix..<(old.count - suffix)])
        let newMiddle = Array(new[prefix..<(new.count - suffix)])
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in newMiddle.difference(from: oldMiddle) {
            switch change {
            case .remove(let offset, _, _): removed.insert(prefix + offset)
            case .insert(let offset, _, _): inserted.insert(prefix + offset)
            }
        }

        var operations: [Operation] = []
        operations.reserveCapacity(old.count + inserted.count)
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            if oldIndex < old.count, removed.contains(oldIndex) {
                operations.append(Operation(kind: .removed, oldIndex: oldIndex, newIndex: nil))
                oldIndex += 1
            } else if newIndex < new.count, inserted.contains(newIndex) {
                operations.append(Operation(kind: .added, oldIndex: nil, newIndex: newIndex))
                newIndex += 1
            } else {
                operations.append(Operation(kind: .context, oldIndex: oldIndex, newIndex: newIndex))
                oldIndex += 1
                newIndex += 1
            }
        }
        return operations
    }

    // MARK: Hunks

    private static func hunks(
        from operations: [Operation], old: [Substring], new: [Substring], context: Int
    ) -> [DiffHunk] {
        // Ranges of operations to show: each change plus `context` lines around it, merged when they touch.
        var ranges: [Range<Int>] = []
        for (index, operation) in operations.enumerated() where operation.kind != .context {
            let range = max(0, index - context)..<min(operations.count, index + context + 1)
            if let last = ranges.last, range.lowerBound <= last.upperBound {
                ranges[ranges.count - 1] = last.lowerBound..<range.upperBound
            } else {
                ranges.append(range)
            }
        }

        // Old/new lines consumed before each operation, for the start of empty ranges.
        var oldBefore = 0
        var newBefore = 0
        var cursor = 0
        var lineID = 0
        var result: [DiffHunk] = []
        for range in ranges {
            for operation in operations[cursor..<range.lowerBound] {
                if operation.oldIndex != nil { oldBefore += 1 }
                if operation.newIndex != nil { newBefore += 1 }
            }
            cursor = range.lowerBound

            var lines: [DiffLine] = []
            var oldCount = 0
            var newCount = 0
            for operation in operations[range] {
                let kind: DiffLine.Kind
                let text: Substring
                switch operation.kind {
                case .context: kind = .context; text = old[operation.oldIndex!]
                case .removed: kind = .removed; text = old[operation.oldIndex!]
                case .added: kind = .added; text = new[operation.newIndex!]
                }
                if operation.oldIndex != nil { oldCount += 1 }
                if operation.newIndex != nil { newCount += 1 }
                lines.append(
                    DiffLine(
                        id: lineID, kind: kind, text: String(text),
                        oldNumber: operation.oldIndex.map { $0 + 1 }, newNumber: operation.newIndex.map { $0 + 1 }))
                lineID += 1
            }
            result.append(
                DiffHunk(
                    id: result.count,
                    oldStart: oldCount > 0 ? oldBefore + 1 : oldBefore, oldCount: oldCount,
                    newStart: newCount > 0 ? newBefore + 1 : newBefore, newCount: newCount,
                    lines: lines))
        }
        return result
    }
}
