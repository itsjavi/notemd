import Foundation

// MARK: - Links

/// A local file linked from a note body by `[…](…)`, `![…](…)`, `+[…](…)` or a reference definition.
/// Derived from the Markdown, which stays the only source of truth (TASK-33).
public struct AssetLink: Sendable, Hashable {
    public enum Location: Sendable, Hashable {
        /// A file inside the repository, by canonical repository-relative path (`assets/a b.png`).
        case repository(path: String)
        /// A file outside the repository root, by absolute path.
        case external(path: String)
    }

    /// The destination as written in the note, without `<…>`.
    public var destination: String
    public var location: Location

    public init(destination: String, location: Location) {
        self.destination = destination
        self.location = location
    }

    /// The repository-relative path, nil for external files.
    public var repositoryPath: String? {
        if case .repository(let path) = location { return path }
        return nil
    }
}

public enum AttachmentStatus: Sendable, Hashable {
    case found, missing, external
}

public struct NoteAttachment: Sendable, Hashable {
    public var link: AssetLink
    public var status: AttachmentStatus

    public init(link: AssetLink, status: AttachmentStatus) {
        self.link = link
        self.status = status
    }
}

/// Reads, removes and retargets the links from a note to local files.
///
/// Text scanning finds the link syntax and its exact ranges; cmark-gfm decides which of it forms real
/// links, so code blocks, inline code, HTML blocks and escaped brackets are never read or edited. Bodies
/// may include front matter, which is skipped and returned unchanged.
public enum AssetReferences {
    /// Local file links of a note body (links, images, reference definitions, `+[…](…)` embeds), outside
    /// code, excluding web/mailto/other-scheme URLs and links to notes, in document order. Identical
    /// links are listed once. `notePath` is repository-relative, `rootPath` the absolute repository root.
    public static func links(in body: String, notePath: String, rootPath: String) -> [AssetLink] {
        let text = NoteText(body)
        let found = LinkOccurrences(
            scanner: LinkScanner(text.body), resolver: DestinationResolver(notePath: notePath, rootPath: rootPath),
            matching: { _ in true }, unlinking: false)
        var seen = Set<AssetLink>()
        return found.links.filter { seen.insert($0).inserted }
    }

    /// The local file a link destination (as written, with or without `<…>`) points at, or nil for web
    /// URLs, in-page anchors, folders and notes.
    public static func location(of destination: String, notePath: String, rootPath: String) -> AssetLink.Location? {
        DestinationResolver(notePath: notePath, rootPath: rootPath).location(of: LinkScanner.unbracketed(destination))
    }

    /// The body with every link to `assetPath` (repository-relative) removed: standalone `![…](…)` /
    /// `+[…](…)` lines go with their line break, inline images and embeds are removed, inline `[label](…)`
    /// links become their label, reference definitions are removed and their uses become labels.
    public static func unlinking(_ assetPath: String, in body: String, notePath: String, rootPath: String) -> String {
        let text = NoteText(body)
        let resolver = DestinationResolver(notePath: notePath, rootPath: rootPath)
        let target = AssetLink.Location.repository(path: assetPath)
        var result = text.body
        var changed = false
        // A link kept as its label can still hold an image of the asset; a further pass removes it.
        for _ in 0..<4 {
            guard let pass = unlinkPass(target, in: result, resolver: resolver) else { break }
            result = pass.text
            changed = true
            if !pass.needsAnotherPass { break }
        }
        return changed ? text.head + result : body
    }

    /// The body with every link resolving to `oldPath` pointing at `newPath` instead (both
    /// repository-relative), relative to the note's folder. Each link keeps its style: `<…>` or percent
    /// encoding, relative, absolute or `file://` form, `./` prefix, `?query` and `#fragment`.
    public static func renaming(_ oldPath: String, to newPath: String, in body: String, notePath: String, rootPath: String) -> String {
        guard oldPath != newPath else { return body }
        let text = NoteText(body)
        let resolver = DestinationResolver(notePath: notePath, rootPath: rootPath)
        let target = AssetLink.Location.repository(path: oldPath)
        let scanner = LinkScanner(text.body)
        let found = LinkOccurrences(scanner: scanner, resolver: resolver, matching: { $0 == target }, unlinking: false)
        let destinations = found.inline.map(\.link.destination) + found.definitions.map(\.definition.destination)
        guard !destinations.isEmpty else { return body }
        let edits = destinations.map { range in
            TextEdit(range: range, replacement: restyledDestination(scanner.string(range), to: newPath, resolver: resolver))
        }
        return text.head + applying(edits, to: text.body).text
    }

    // MARK: Unlinking

    private static func unlinkPass(
        _ target: AssetLink.Location, in body: String, resolver: DestinationResolver
    ) -> (text: String, needsAnotherPass: Bool)? {
        let scanner = LinkScanner(body)
        let found = LinkOccurrences(scanner: scanner, resolver: resolver, matching: { $0 == target }, unlinking: true)
        var edits: [TextEdit] = []
        for item in found.inline where item.isWanted {
            edits.append(item.link.prefix == .link
                ? TextEdit(range: item.link.range, replacement: scanner.string(item.link.label))
                : TextEdit(range: item.link.range, replacement: ""))
        }
        for item in found.definitions {
            edits.append(TextEdit(range: item.definition.range, replacement: ""))
        }
        for use in found.uses {
            edits.append(TextEdit(range: use.range, replacement: use.prefix == .link ? scanner.string(use.label) : ""))
        }
        guard !edits.isEmpty else { return nil }

        // An image that is a link's whole label (a badge) takes the link with it.
        for index in edits.indices where edits[index].isRemoval {
            if let wrapper = found.inline.first(where: { scanner.trimmed($0.link.label) == edits[index].range }) {
                edits[index].range = wrapper.link.range
            }
        }

        // Outer edits win; an edit inside a link kept as its label waits for the next pass.
        edits.sort {
            $0.range.location != $1.range.location ? $0.range.location < $1.range.location
                : $0.range.length != $1.range.length ? $0.range.length > $1.range.length
                : $0.isRemoval && !$1.isRemoval
        }
        var kept: [TextEdit] = []
        var needsAnotherPass = false
        for edit in edits {
            if let last = kept.last, edit.range.location < NSMaxRange(last.range) {
                if !last.isRemoval && edit.range != last.range { needsAnotherPass = true }
                continue
            }
            kept.append(edit)
        }

        tidySpaces(around: &kept, in: scanner.units)
        let applied = applying(kept, to: body)
        return (removingEmptiedLines(in: applied.text, at: applied.removalPoints), needsAnotherPass)
    }

    /// Widens inline removals so they don't leave a double space, a leading space or a trailing space.
    private static func tidySpaces(around edits: inout [TextEdit], in units: [UInt16]) {
        for index in edits.indices where edits[index].isRemoval {
            let lower = index > 0 ? NSMaxRange(edits[index - 1].range) : 0
            let upper = index + 1 < edits.count ? edits[index + 1].range.location : units.count
            let start = edits[index].range.location
            var end = NSMaxRange(edits[index].range)
            let atLineStart = start == 0 || units[start - 1] == U.lf || units[start - 1] == U.cr
            let spaceBefore = start > 0 && U.isSpaceOrTab(units[start - 1])
            if end < upper, U.isSpaceOrTab(units[end]), atLineStart || spaceBefore {
                end += 1
                while atLineStart, end < upper, U.isSpaceOrTab(units[end]) { end += 1 }
                edits[index].range = NSRange(location: start, length: end - start)
            } else if spaceBefore, end >= units.count || units[end] == U.lf || units[end] == U.cr {
                var newStart = start
                while newStart > lower, U.isSpaceOrTab(units[newStart - 1]) { newStart -= 1 }
                edits[index].range = NSRange(location: newStart, length: end - newStart)
            }
        }
    }

    private static let emptiedLinePattern = try! NSRegularExpression(pattern: #"^[ \t>]*(?:(?:[-*+]|[0-9]{1,9}[.)])[ \t]*)?$"#)

    /// Removes the lines holding a removal point that are left blank (or with only block quote or list
    /// markers), with their line break, plus one neighbouring blank line when they sat between two.
    private static func removingEmptiedLines(in text: String, at points: [Int]) -> String {
        guard !points.isEmpty else { return text }
        let ns = text as NSString
        func content(_ line: NSRange) -> String { ns.substring(with: line).trimmingCharacters(in: .newlines) }
        func isBlank(_ line: NSRange) -> Bool { content(line).trimmingCharacters(in: .whitespaces).isEmpty }

        var blocks: [NSRange] = []
        for point in points {
            let line = ns.lineRange(for: NSRange(location: min(point, ns.length), length: 0))
            let lineText = content(line)
            guard emptiedLinePattern.firstMatch(in: lineText, range: NSRange(location: 0, length: lineText.utf16.count)) != nil
            else { continue }
            if let last = blocks.last, NSMaxRange(last) >= line.location {
                blocks[blocks.count - 1] = NSUnionRange(last, line)
            } else {
                blocks.append(line)
            }
        }

        var removals: [NSRange] = []
        for block in blocks {
            var range = block
            let previous = block.location > 0 ? ns.lineRange(for: NSRange(location: block.location - 1, length: 0)) : nil
            let next = NSMaxRange(block) < ns.length ? ns.lineRange(for: NSRange(location: NSMaxRange(block), length: 0)) : nil
            if previous.map(isBlank) ?? true, next.map(isBlank) ?? true {
                if let next { range = NSUnionRange(range, next) } else if let previous { range = NSUnionRange(previous, range) }
            }
            if let last = removals.last, NSMaxRange(last) >= range.location {
                removals[removals.count - 1] = NSUnionRange(last, range)
            } else {
                removals.append(range)
            }
        }
        guard !removals.isEmpty else { return text }
        return applying(removals.map { TextEdit(range: $0, replacement: "") }, to: text).text
    }

    // MARK: Renaming

    /// `newPath` written in the style of the `written` destination it replaces.
    private static func restyledDestination(_ written: String, to newPath: String, resolver: DestinationResolver) -> String {
        let bracketed = written.hasPrefix("<") && written.hasSuffix(">") && written.count >= 2
        var path = bracketed ? String(written.dropFirst().dropLast()) : written
        var suffix = ""
        if let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            suffix = String(path[cut...])
            path = String(path[..<cut])
        }
        let encoded = path.range(of: "%[0-9A-Fa-f]{2}", options: .regularExpression) != nil
        func styled(_ value: String) -> String {
            if encoded { return Attachments.encodeDestination(value) }
            if bracketed { return value.replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E") }
            return minimallyEncoded(value)
        }

        let replacement: String
        if path.lowercased().hasPrefix("file:") {
            let rest = path.dropFirst(5)
            let authority = rest.hasPrefix("//") ? "//" + rest.dropFirst(2).prefix { $0 != "/" } : ""
            replacement = String(path.prefix(5)) + authority + styled(resolver.absolutePath(of: newPath))
        } else if path.hasPrefix("/") {
            replacement = styled(resolver.absolutePath(of: newPath))
        } else {
            var relative = Attachments.relativePath(fromDirectory: resolver.noteDirectory.joined(separator: "/"), to: newPath)
            if path.hasPrefix("./") && !relative.hasPrefix("../") { relative = "./" + relative }
            replacement = styled(relative)
        }
        return bracketed ? "<\(replacement)\(suffix)>" : replacement + suffix
    }

    /// Percent-encodes only what a bare Markdown destination can't hold, so plain and non-ASCII names stay readable.
    private static func minimallyEncoded(_ path: String) -> String {
        var result = ""
        for scalar in path.unicodeScalars {
            if scalar.value <= 0x20 || scalar.value == 0x7F || "()<>%\\".unicodeScalars.contains(scalar) || scalar.properties.isWhitespace {
                for byte in String(scalar).utf8 { result += String(format: "%%%02X", byte) }
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    // MARK: Editing

    private struct TextEdit {
        var range: NSRange
        var replacement: String
        var isRemoval: Bool { replacement.isEmpty }
    }

    /// Applies sorted, non-overlapping `edits`, returning UTF-16 offsets in the result where text was removed.
    private static func applying(_ edits: [TextEdit], to text: String) -> (text: String, removalPoints: [Int]) {
        let ns = text as NSString
        var result = ""
        var length = 0
        var cursor = 0
        var points: [Int] = []
        for edit in edits {
            let kept = ns.substring(with: NSRange(location: cursor, length: edit.range.location - cursor))
            result += kept
            length += kept.utf16.count
            if edit.isRemoval { points.append(length) }
            result += edit.replacement
            length += edit.replacement.utf16.count
            cursor = NSMaxRange(edit.range)
        }
        result += ns.substring(from: cursor)
        return (result, points)
    }
}

// MARK: - Index

/// Which notes link to which files, kept per note from the bodies the app already holds (TASK-33).
public struct AssetReferenceIndex: Sendable {
    private struct Entry: Sendable {
        var body: String
        var rootPath: String
        var links: [AssetLink]
    }

    private var entries: [String: Entry] = [:]
    private var notesByPath: [String: Set<String>] = [:]
    /// Bodies parsed so far; unchanged bodies are not parsed again.
    private(set) var parseCount = 0

    public init() {}

    /// Re-parses only when `body` differs from the last body seen for that note.
    public mutating func update(notePath: String, body: String, rootPath: String) {
        if let entry = entries[notePath], entry.body == body, entry.rootPath == rootPath { return }
        parseCount += 1
        let links = AssetReferences.links(in: body, notePath: notePath, rootPath: rootPath)
        unregister(notePath)
        entries[notePath] = Entry(body: body, rootPath: rootPath, links: links)
        for path in Set(links.compactMap(\.repositoryPath)) {
            notesByPath[path, default: []].insert(notePath)
        }
    }

    public mutating func remove(notePath: String) {
        unregister(notePath)
        entries[notePath] = nil
    }

    /// Drops notes not in the set (after a repository scan).
    public mutating func retain(notePaths: Set<String>) {
        for notePath in entries.keys where !notePaths.contains(notePath) {
            remove(notePath: notePath)
        }
    }

    public func links(of notePath: String) -> [AssetLink] {
        entries[notePath]?.links ?? []
    }

    /// Sorted paths of the notes linking to `assetPath` (repository-relative).
    public func notes(referencing assetPath: String) -> [String] {
        (notesByPath[assetPath] ?? []).sorted()
    }

    /// The files a note links to, once each in document order. `fileExists` gets repository-relative paths.
    public func attachments(of notePath: String, fileExists: (String) -> Bool) -> [NoteAttachment] {
        var seen = Set<AssetLink.Location>()
        return links(of: notePath).compactMap { link in
            guard seen.insert(link.location).inserted else { return nil }
            switch link.location {
            case .repository(let path): return NoteAttachment(link: link, status: fileExists(path) ? .found : .missing)
            case .external: return NoteAttachment(link: link, status: .external)
            }
        }
    }

    /// Repository-relative paths linked from at least one note.
    public var referencedPaths: Set<String> {
        Set(notesByPath.keys)
    }

    private mutating func unregister(_ notePath: String) {
        guard let entry = entries[notePath] else { return }
        for path in Set(entry.links.compactMap(\.repositoryPath)) {
            notesByPath[path]?.remove(notePath)
            if notesByPath[path]?.isEmpty == true { notesByPath[path] = nil }
        }
    }
}

// MARK: - Resolving destinations

/// Maps link destinations of one note to repository or external files.
struct DestinationResolver {
    /// The note's folder, as path components.
    let noteDirectory: [String]
    private let root: [String]
    /// `/private/tmp/x` for a root at `/tmp/x` and the other way round (same folder, both spellings occur).
    private let rootAlias: [String]?

    init(notePath: String, rootPath: String) {
        noteDirectory = notePath.split(separator: "/").dropLast().map(String.init)
        root = Self.absoluteComponents(rootPath)
        if root.count > 1, root[0] == "private", ["tmp", "var", "etc"].contains(root[1]) {
            rootAlias = Array(root.dropFirst())
        } else if let first = root.first, ["tmp", "var", "etc"].contains(first) {
            rootAlias = ["private"] + root
        } else {
            rootAlias = nil
        }
    }

    /// The absolute path of a repository-relative path.
    func absolutePath(of repositoryPath: String) -> String {
        "/" + (root + repositoryPath.split(separator: "/").map(String.init)).joined(separator: "/")
    }

    /// The file `destination` (as written, without `<…>`) points at.
    func location(of destination: String) -> AssetLink.Location? {
        // Byte scans: this runs for every link of every note on each scan.
        var value = destination.utf8.contains(where: { $0 == 0x5C || $0 == 0x26 }) ? Self.unescaped(destination) : destination
        guard let first = value.utf8.first, first != 0x23, !value.hasPrefix("//") else { return nil }
        if let scheme = Self.scheme(of: value) {
            guard scheme == "file", let path = Self.fileURLPath(value) else { return nil }
            return absoluteLocation(path)
        }
        if let cut = value.utf8.firstIndex(where: { $0 == 0x3F || $0 == 0x23 }) { value = String(value[..<cut]) }
        let path = value.utf8.contains(0x25) ? value.removingPercentEncoding ?? value : value
        guard !path.isEmpty else { return nil }
        if path == "~" || path.hasPrefix("~/") {
            // The preview doesn't expand `~`, so these never count as repository files.
            let components = Self.absoluteComponents(NSHomeDirectory() + path.dropFirst())
            guard !path.hasSuffix("/"), !components.isEmpty, !Self.isNote(components) else { return nil }
            return .external(path: "/" + components.joined(separator: "/"))
        }
        if path.hasPrefix("/") { return absoluteLocation(path) }
        guard !path.hasSuffix("/") else { return nil }
        let components = path.split(separator: "/").map(String.init)
        guard let resolved = Attachments.normalize(noteDirectory + components) else {
            return classify(Self.normalizedAbsolute(root + noteDirectory + components))
        }
        guard !resolved.isEmpty, !Self.isNote(resolved) else { return nil }
        return .repository(path: resolved.joined(separator: "/"))
    }

    private func absoluteLocation(_ path: String) -> AssetLink.Location? {
        guard !path.hasSuffix("/") else { return nil }
        return classify(Self.absoluteComponents(path))
    }

    private func classify(_ components: [String]) -> AssetLink.Location? {
        guard !components.isEmpty, !Self.isNote(components) else { return nil }
        for base in [root] + (rootAlias.map { [$0] } ?? []) where components.starts(with: base) {
            guard components.count > base.count else { return nil }  // the root folder itself
            return .repository(path: components.dropFirst(base.count).joined(separator: "/"))
        }
        return .external(path: "/" + components.joined(separator: "/"))
    }

    private static func isNote(_ components: [String]) -> Bool {
        guard let name = components.last, let dot = name.utf8.lastIndex(of: 0x2E) else { return false }
        return NoteMDCore.noteExtensions.contains(name[name.utf8.index(after: dot)...].lowercased())
    }

    static func absoluteComponents(_ path: String) -> [String] {
        normalizedAbsolute(path.split(separator: "/").map(String.init))
    }

    /// Resolves `.` and `..` in an absolute path; `..` stops at `/`.
    private static func normalizedAbsolute(_ components: [String]) -> [String] {
        var result: [String] = []
        for component in components where component != "." && !component.isEmpty {
            if component == ".." { _ = result.popLast() } else { result.append(component) }
        }
        return result
    }

    /// The lowercased URL scheme (`https`, `mailto`, `file`…), nil for paths.
    private static func scheme(of value: String) -> String? {
        var length = 0
        for unit in value.utf8 {
            if unit == 0x3A { return length > 0 ? String(decoding: value.utf8.prefix(length), as: UTF8.self).lowercased() : nil }
            let isLetter = (0x61...0x7A).contains(unit | 0x20)
            let isOther = (0x30...0x39).contains(unit) || unit == 0x2B || unit == 0x2D || unit == 0x2E
            guard isLetter || (length > 0 && isOther) else { return nil }
            length += 1
        }
        return nil
    }

    /// The decoded path of a local `file:` URL, nil for other hosts.
    private static func fileURLPath(_ value: String) -> String? {
        var rest = Substring(value).dropFirst(5)
        if let cut = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) { rest = rest[..<cut] }
        if rest.hasPrefix("//") {
            rest = rest.dropFirst(2)
            let host = rest.prefix { $0 != "/" }
            guard host.isEmpty || host.lowercased() == "localhost" else { return nil }
            rest = rest.dropFirst(host.count)
        }
        let path = String(rest).removingPercentEncoding ?? String(rest)
        return path.hasPrefix("/") ? path : nil
    }

    private static let entities: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'"]

    /// Resolves Markdown backslash escapes and character references, as cmark does for destinations.
    static func unescaped(_ value: String) -> String {
        guard value.contains("\\") || value.contains("&") else { return value }
        let characters = Array(value)
        var result = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count, characters[index + 1].isASCII,
               characters[index + 1].isPunctuation || characters[index + 1].isSymbol {
                result.append(characters[index + 1])
                index += 2
                continue
            }
            if character == "&", let semicolon = characters[(index + 1)...].prefix(10).firstIndex(of: ";") {
                let name = String(characters[(index + 1)..<semicolon])
                var decoded = entities[name]
                if decoded == nil, name.hasPrefix("#") {
                    let digits = name.dropFirst()
                    let number = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                    decoded = number.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                }
                if let decoded {
                    result += decoded
                    index = semicolon + 1
                    continue
                }
            }
            result.append(character)
            index += 1
        }
        return result
    }
}

// MARK: - Finding links

/// Note text split into front matter, kept verbatim, and the Markdown body links are read from.
private struct NoteText {
    let head: String
    let body: String

    init(_ text: String) {
        let hasBOM = text.hasPrefix("\u{FEFF}")
        guard let split = MarkdownText.splitFrontMatter(hasBOM ? String(text.dropFirst()) : text) else {
            head = ""
            body = text
            return
        }
        body = split.body
        head = (text as NSString).substring(to: text.utf16.count - split.body.utf16.count)
    }
}

/// UTF-16 code units the scanner looks for.
private enum U {
    static let tab: UInt16 = 0x09, lf: UInt16 = 0x0A, cr: UInt16 = 0x0D, space: UInt16 = 0x20
    static let bang: UInt16 = 0x21, quote: UInt16 = 0x22, apostrophe: UInt16 = 0x27
    static let openParen: UInt16 = 0x28, closeParen: UInt16 = 0x29, star: UInt16 = 0x2A, plus: UInt16 = 0x2B
    static let dash: UInt16 = 0x2D, dot: UInt16 = 0x2E, colon: UInt16 = 0x3A, less: UInt16 = 0x3C, greater: UInt16 = 0x3E
    static let openBracket: UInt16 = 0x5B, backslash: UInt16 = 0x5C, closeBracket: UInt16 = 0x5D

    static func isASCIIPunctuation(_ unit: UInt16) -> Bool {
        (0x21...0x2F).contains(unit) || (0x3A...0x40).contains(unit) || (0x5B...0x60).contains(unit) || (0x7B...0x7E).contains(unit)
    }

    static func isSpaceOrTab(_ unit: UInt16) -> Bool { unit == space || unit == tab }
}

/// Link syntax found by scanning the text, with exact UTF-16 ranges. It over-matches (code, HTML,
/// unmatched labels); `LinkOccurrences` asks cmark which of it forms real links.
struct LinkScanner {
    enum Prefix { case link, image, embed }

    struct InlineLink {
        var prefix: Prefix
        /// The whole link, `!` / `+` prefix included.
        var range: NSRange
        /// Between the brackets.
        var label: NSRange
        /// As written, `<…>` included.
        var destination: NSRange
    }

    struct Definition {
        /// Normalized label.
        var key: String
        var label: String
        /// From the opening bracket to the end of the destination or title.
        var range: NSRange
        var destination: NSRange
    }

    struct ReferenceUse {
        enum Form { case full(reference: NSRange), collapsed(at: Int), shortcut(after: Int) }
        var prefix: Prefix
        var range: NSRange
        /// The first brackets' content: the text a link keeps when unlinked.
        var label: NSRange
        var key: String
        var form: Form
    }

    let text: String
    let units: [UInt16]

    init(_ text: String) {
        self.text = text
        units = Array(text.utf16)
    }

    func string(_ range: NSRange) -> String {
        String(decoding: units[range.location..<NSMaxRange(range)], as: UTF16.self)
    }

    /// The destination at `range` without `<…>`.
    func destination(_ range: NSRange) -> String {
        Self.unbracketed(string(range))
    }

    static func unbracketed(_ destination: String) -> String {
        destination.hasPrefix("<") && destination.hasSuffix(">") && destination.count >= 2
            ? String(destination.dropFirst().dropLast()) : destination
    }

    /// `range` without surrounding whitespace.
    func trimmed(_ range: NSRange) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        func isWhitespace(_ unit: UInt16) -> Bool { U.isSpaceOrTab(unit) || unit == U.lf || unit == U.cr }
        while start < end, isWhitespace(units[start]) { start += 1 }
        while end > start, isWhitespace(units[end - 1]) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    func isEscaped(_ index: Int) -> Bool {
        var count = 0
        var position = index - 1
        while position >= 0, units[position] == U.backslash {
            count += 1
            position -= 1
        }
        return count % 2 == 1
    }

    // MARK: Inline links

    /// `[label](destination "title")`, with an optional `!` or `+` prefix.
    func inlineLinks() -> [InlineLink] {
        var links: [InlineLink] = []
        var index = 0
        while index + 1 < units.count {
            if units[index] == U.closeBracket, units[index + 1] == U.openParen, !isEscaped(index),
               let link = inlineLink(closingBracket: index) {
                links.append(link)
            }
            index += 1
        }
        return links
    }

    private func inlineLink(closingBracket close: Int) -> InlineLink? {
        let start = skipWhitespace(from: close + 2)
        guard let end = destinationEnd(from: start), end > start else { return nil }
        var position = skipWhitespace(from: end)
        if position > end, position < units.count, let title = titleEnd(from: position) {
            position = skipWhitespace(from: title)
        }
        guard position < units.count, units[position] == U.closeParen, let open = labelOpener(before: close) else { return nil }
        let (prefix, linkStart) = prefix(before: open)
        return InlineLink(
            prefix: prefix, range: NSRange(location: linkStart, length: position + 1 - linkStart),
            label: NSRange(location: open + 1, length: close - open - 1),
            destination: NSRange(location: start, length: end - start))
    }

    /// The `[` matching the `]` at `close`, balancing nested brackets, within the paragraph.
    private func labelOpener(before close: Int) -> Int? {
        var depth = 0
        var index = close - 1
        var sawLineBreak = false
        var lineHasContent = false
        let limit = max(0, close - 4000)
        while index >= limit {
            let unit = units[index]
            if unit == U.lf {
                if sawLineBreak && !lineHasContent { return nil }  // blank line: the paragraph ends
                sawLineBreak = true
                lineHasContent = false
            } else if !U.isSpaceOrTab(unit) && unit != U.cr {
                lineHasContent = true
            }
            if unit == U.closeBracket, !isEscaped(index) {
                depth += 1
            } else if unit == U.openBracket, !isEscaped(index) {
                if depth == 0 { return index }
                depth -= 1
            }
            index -= 1
        }
        return nil
    }

    private func prefix(before open: Int) -> (Prefix, Int) {
        guard open > 0, !isEscaped(open - 1) else { return (.link, open) }
        switch units[open - 1] {
        case U.bang: return (.image, open - 1)
        case U.plus: return (.embed, open - 1)
        default: return (.link, open)
        }
    }

    /// End of a destination starting at `start`: `<…>` on one line, or a run without spaces or control
    /// characters whose parentheses balance.
    private func destinationEnd(from start: Int) -> Int? {
        guard start < units.count else { return nil }
        if units[start] == U.less {
            var index = start + 1
            while index < units.count {
                switch units[index] {
                case U.backslash: index += 2
                case U.greater: return index + 1
                case U.less, U.lf, U.cr: return nil
                default: index += 1
                }
            }
            return nil
        }
        var depth = 0
        var index = start
        while index < units.count {
            let unit = units[index]
            if unit == U.backslash, index + 1 < units.count, U.isASCIIPunctuation(units[index + 1]) {
                index += 2
                continue
            }
            if unit <= U.space || unit == 0x7F { break }
            if unit == U.openParen {
                depth += 1
            } else if unit == U.closeParen {
                if depth == 0 { break }
                depth -= 1
            }
            index += 1
        }
        return depth == 0 ? index : nil
    }

    /// End of a `"…"`, `'…'` or `(…)` title starting at `start`, within the paragraph.
    private func titleEnd(from start: Int) -> Int? {
        let closer: UInt16
        switch units[start] {
        case U.quote: closer = U.quote
        case U.apostrophe: closer = U.apostrophe
        case U.openParen: closer = U.closeParen
        default: return nil
        }
        var index = start + 1
        var lineHasContent = true
        while index < units.count {
            let unit = units[index]
            if unit == U.backslash {
                index += 2
                continue
            }
            if unit == closer { return index + 1 }
            if closer == U.closeParen && unit == U.openParen { return nil }
            if unit == U.lf {
                if !lineHasContent { return nil }
                lineHasContent = false
            } else if !U.isSpaceOrTab(unit) && unit != U.cr {
                lineHasContent = true
            }
            index += 1
        }
        return nil
    }

    /// Skips spaces and tabs, and at most one line break.
    private func skipWhitespace(from start: Int) -> Int {
        var index = start
        var lineBreaks = 1
        while index < units.count {
            let unit = units[index]
            if U.isSpaceOrTab(unit) {
                index += 1
            } else if (unit == U.lf || unit == U.cr) && lineBreaks > 0 {
                lineBreaks -= 1
                index += unit == U.cr && index + 1 < units.count && units[index + 1] == U.lf ? 2 : 1
            } else {
                break
            }
        }
        return index
    }

    private func skipSpaces(from start: Int) -> Int {
        var index = start
        while index < units.count, U.isSpaceOrTab(units[index]) { index += 1 }
        return index
    }

    private func isLineEnd(_ index: Int) -> Bool {
        index >= units.count || units[index] == U.lf || units[index] == U.cr
    }

    // MARK: Reference definitions

    /// `[label]: destination "title"` lines, inside block quotes and list items too.
    func definitions() -> [Definition] {
        var result: [Definition] = []
        var lineStart = 0
        while lineStart < units.count {
            var lineEnd = lineStart
            while lineEnd < units.count, units[lineEnd] != U.lf { lineEnd += 1 }
            if let definition = definition(from: lineStart, lineEnd: lineEnd) { result.append(definition) }
            lineStart = lineEnd + 1
        }
        return result
    }

    private func definition(from lineStart: Int, lineEnd: Int) -> Definition? {
        var index = skipContainerMarkers(from: lineStart, to: lineEnd)
        guard index < lineEnd, units[index] == U.openBracket else { return nil }
        let open = index
        index += 1
        var hasContent = false
        while index < lineEnd, units[index] != U.closeBracket {
            if units[index] == U.openBracket { return nil }
            if !U.isSpaceOrTab(units[index]) { hasContent = true }
            index += units[index] == U.backslash ? 2 : 1
        }
        guard index < lineEnd, hasContent, index - open <= 1000, index + 1 < units.count, units[index + 1] == U.colon else { return nil }
        let close = index
        let start = skipWhitespace(from: close + 2)
        guard let end = destinationEnd(from: start), end > start else { return nil }
        var rangeEnd = end
        let afterDestination = skipSpaces(from: end)
        if !isLineEnd(afterDestination) {
            guard afterDestination > end, let title = titleEnd(from: afterDestination), isLineEnd(skipSpaces(from: title)) else { return nil }
            rangeEnd = title
        } else if afterDestination < units.count {
            // A title alone on the next line belongs to the definition.
            var nextLine = afterDestination + 1
            if units[afterDestination] == U.cr, nextLine < units.count, units[nextLine] == U.lf { nextLine += 1 }
            let titleStart = skipSpaces(from: nextLine)
            if titleStart < units.count, let title = titleEnd(from: titleStart), isLineEnd(skipSpaces(from: title)) {
                rangeEnd = title
            }
        }
        let label = string(NSRange(location: open + 1, length: close - open - 1))
        return Definition(
            key: Self.key(label), label: label, range: NSRange(location: open, length: rangeEnd - open),
            destination: NSRange(location: start, length: end - start))
    }

    /// Skips indentation, block quote markers and list markers at the start of a line.
    private func skipContainerMarkers(from start: Int, to end: Int) -> Int {
        var index = start
        while true {
            index = skipSpaces(from: index)
            guard index < end else { return index }
            let unit = units[index]
            if unit == U.greater {
                index += 1
                continue
            }
            if unit == U.dash || unit == U.star || unit == U.plus, index + 1 < end, U.isSpaceOrTab(units[index + 1]) {
                index += 2
                continue
            }
            var digits = index
            while digits < end, digits - index < 9, (0x30...0x39).contains(units[digits]) { digits += 1 }
            if digits > index, digits + 1 < end, units[digits] == U.dot || units[digits] == U.closeParen, U.isSpaceOrTab(units[digits + 1]) {
                index = digits + 2
                continue
            }
            return index
        }
    }

    /// A link label as cmark matches it: case-folded, inner whitespace collapsed.
    static func key(_ label: String) -> String {
        label.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    // MARK: Reference uses

    private static let usePattern = try! NSRegularExpression(
        pattern: #"([!+]?)\[((?:[^\[\]\\\r\n]|\\.)+)\](?:\[((?:[^\[\]\\\r\n]|\\.)*)\])?"#)

    /// `[text][label]`, `[label][]` and `[label]` uses of the given labels, with an optional `!` or `+`.
    func referenceUses(keys: Set<String>) -> [ReferenceUse] {
        var uses: [ReferenceUse] = []
        for match in Self.usePattern.matches(in: text, range: NSRange(location: 0, length: units.count)) {
            let labelRange = match.range(at: 2)
            let open = labelRange.location - 1
            guard !isEscaped(open) else { continue }
            let end = NSMaxRange(match.range)
            if end < units.count, units[end] == U.openParen { continue }  // an inline link's label
            var (prefix, start) = (LinkScanner.Prefix.link, open)
            let prefixRange = match.range(at: 1)
            if prefixRange.length == 1, !isEscaped(prefixRange.location) {
                (prefix, start) = (units[prefixRange.location] == U.bang ? .image : .embed, prefixRange.location)
            }
            let referenceRange = match.range(at: 3)
            let form: ReferenceUse.Form
            let key: String
            if referenceRange.location == NSNotFound {
                if end < units.count, units[end] == U.colon { continue }  // a definition's label
                (form, key) = (.shortcut(after: end), Self.key(string(labelRange)))
            } else if referenceRange.length == 0 {
                (form, key) = (.collapsed(at: referenceRange.location), Self.key(string(labelRange)))
            } else {
                (form, key) = (.full(reference: referenceRange), Self.key(string(referenceRange)))
            }
            guard keys.contains(key) else { continue }
            uses.append(ReferenceUse(
                prefix: prefix, range: NSRange(location: start, length: end - start), label: labelRange, key: key, form: form))
        }
        return uses
    }

    /// The text with `substitutions` (sorted or not; overlapping ones skipped) applied, after `preamble`.
    func substituting(_ substitutions: [(range: NSRange, text: String)], after preamble: String) -> String {
        var result = Array(preamble.utf16)
        result.reserveCapacity(result.count + units.count + substitutions.count * 24)
        var cursor = 0
        for substitution in substitutions.sorted(by: { $0.range.location < $1.range.location }) where substitution.range.location >= cursor {
            result += units[cursor..<substitution.range.location]
            result += substitution.text.utf16
            cursor = NSMaxRange(substitution.range)
        }
        result += units[cursor...]
        return String(decoding: result, as: UTF16.self)
    }
}

/// The scanned links that cmark confirms, among those pointing at wanted files.
///
/// Each candidate's destination (or reference label) is swapped for a unique token and the text is parsed
/// once: a token that comes back as a link or image URL marks a real link. Unused reference definitions
/// are confirmed by probe uses placed before the text, which cmark resolves to the first definition.
struct LinkOccurrences {
    struct Inline {
        var link: LinkScanner.InlineLink
        var destination: String
        var location: AssetLink.Location?
        /// False for a link checked only because a wanted image is its whole label.
        var isWanted: Bool
    }

    struct Definition {
        var definition: LinkScanner.Definition
        var destination: String
        var location: AssetLink.Location
    }

    private(set) var inline: [Inline] = []
    /// The effective (first) definitions of their labels.
    private(set) var definitions: [Definition] = []
    /// Uses of `definitions`, found only when unlinking.
    private(set) var uses: [LinkScanner.ReferenceUse] = []

    init(scanner: LinkScanner, resolver: DestinationResolver, matching wanted: (AssetLink.Location) -> Bool, unlinking: Bool) {
        guard scanner.units.contains(U.closeBracket) else { return }
        var candidates: [Inline] = []
        var others: [Inline] = []
        for link in scanner.inlineLinks() {
            let destination = scanner.destination(link.destination)
            let location = resolver.location(of: destination)
            if let location, wanted(location) {
                candidates.append(Inline(link: link, destination: destination, location: location, isWanted: true))
            } else if unlinking {
                others.append(Inline(link: link, destination: destination, location: location, isWanted: false))
            }
        }
        let candidateDefinitions = scanner.definitions().compactMap { definition -> Definition? in
            let destination = scanner.destination(definition.destination)
            guard let location = resolver.location(of: destination), wanted(location) else { return nil }
            return Definition(definition: definition, destination: destination, location: location)
        }
        var candidateUses: [LinkScanner.ReferenceUse] = []
        if unlinking {
            if !candidateDefinitions.isEmpty {
                candidateUses = scanner.referenceUses(keys: Set(candidateDefinitions.map(\.definition.key)))
            }
            // Links whose whole label is a wanted image go with it, so check them too.
            let images = Set(candidates.filter { $0.link.prefix != .link }.map(\.link.range)
                + candidateUses.filter { $0.prefix != .link }.map(\.range))
            if !images.isEmpty {
                candidates += others.filter { images.contains(scanner.trimmed($0.link.label)) }
            }
        }
        guard !candidates.isEmpty || !candidateDefinitions.isEmpty else { return }

        func token(_ kind: String, _ index: Int) -> String { "notemd-probe:\(kind)\(index)" }
        var substitutions: [(range: NSRange, text: String)] = []
        for (index, candidate) in candidates.enumerated() {
            substitutions.append((candidate.link.destination, token("l", index)))
        }
        for (index, candidate) in candidateDefinitions.enumerated() {
            substitutions.append((candidate.definition.destination, token("d", index)))
        }
        var preamble = ""
        for (index, use) in candidateUses.enumerated() {
            let label = "notemd-probe-u\(index)"
            preamble += "[\(label)]: \(token("u", index))\n"
            switch use.form {
            case .full(let reference): substitutions.append((reference, label))
            case .collapsed(let position): substitutions.append((NSRange(location: position, length: 0), label))
            case .shortcut(let position): substitutions.append((NSRange(location: position, length: 0), "[\(label)]"))
            }
        }
        if !preamble.isEmpty { preamble += "\n" }
        var probedKeys = Set<String>()
        for candidate in candidateDefinitions where probedKeys.insert(candidate.definition.key).inserted {
            preamble += "[\(candidate.definition.label)]\n\n"
        }

        let urls = Set(MarkdownRenderer.linkURLs(in: scanner.substituting(substitutions, after: preamble)))
        inline = candidates.enumerated().filter { urls.contains(token("l", $0.offset)) }.map(\.element)
        definitions = candidateDefinitions.enumerated().filter { urls.contains(token("d", $0.offset)) }.map(\.element)
        let keys = Set(definitions.map(\.definition.key))
        uses = candidateUses.enumerated().filter { keys.contains($0.element.key) && urls.contains(token("u", $0.offset)) }.map(\.element)
    }

    /// The wanted links in document order.
    var links: [AssetLink] {
        let inlineLinks = inline.compactMap { item in
            item.location.map { (item.link.destination.location, AssetLink(destination: item.destination, location: $0)) }
        }
        let definitionLinks = definitions.map {
            ($0.definition.destination.location, AssetLink(destination: $0.destination, location: $0.location))
        }
        return (inlineLinks + definitionLinks).sorted { $0.0 < $1.0 }.map(\.1)
    }
}
