import Foundation

/// A note file in a repository with the metadata needed for lists and search.
public struct Note: Sendable, Hashable, Identifiable {
    /// Repository-relative path using `/`, e.g. `Work/Plan.md`.
    public var id: String { path }
    public let path: String
    public let url: URL
    public var title: String
    public var tags: [String]
    public var isTemplate: Bool
    public var excerpt: String
    public var modified: Date
    public var created: Date
    public var size: Int
    /// Body text without front matter.
    public let body: String
    /// Case- and diacritic-folded text used by search.
    let searchTitle: String
    let searchBody: String

    public var fileName: String { (path as NSString).lastPathComponent }
    public var baseName: String { (fileName as NSString).deletingPathExtension }
    /// Folder path ("" for the repository root).
    public var folderPath: String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent == "." ? "" : parent
    }

    public init(path: String, url: URL, text: String, modified: Date, created: Date, size: Int) {
        let markdown = MarkdownText(text)
        let baseName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        self.path = path
        self.url = url
        self.title = NoteTitle.derive(frontMatterTitle: markdown.frontMatter?.title, body: markdown.body, fileName: baseName)
        self.tags = markdown.frontMatter?.tags ?? []
        self.isTemplate = markdown.frontMatter?.isTemplate ?? false
        self.excerpt = NoteTitle.excerpt(of: markdown.body, skippingTitle: title)
        self.modified = modified
        self.created = created
        self.size = size
        self.body = markdown.body
        self.searchTitle = SearchFolding.fold(title + " " + baseName)
        self.searchBody = SearchFolding.fold(markdown.body)
    }
}

public enum NoteTitle {
    /// Front matter `title` → first `# H1` (outside code fences, within the first lines) → file name.
    public static func derive(frontMatterTitle: String?, body: String, fileName: String) -> String {
        if let title = frontMatterTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        if let heading = firstHeading(in: body) { return heading }
        return fileName
    }

    public static func firstHeading(in body: String) -> String? {
        var inFence = false
        var scanned = 0
        for line in body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            scanned += 1
            if scanned > 80 { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); continue }
            guard !inFence, trimmed.hasPrefix("# ") else { continue }
            var heading = String(trimmed.dropFirst(2))
            while heading.hasSuffix("#") { heading.removeLast() }
            heading = stripInlineMarkup(heading).trimmingCharacters(in: .whitespaces)
            if !heading.isEmpty { return heading }
        }
        return nil
    }

    /// A short plain-text preview of the body for note lists.
    public static func excerpt(of body: String, skippingTitle title: String, limit: Int = 180) -> String {
        var parts: [String] = []
        var length = 0
        var inFence = false
        var skippedTitle = false
        for line in body.split(whereSeparator: \.isNewline) {
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("```") || text.hasPrefix("~~~") { inFence.toggle(); continue }
            if inFence || text.isEmpty { continue }
            if !skippedTitle, text.hasPrefix("#") {
                skippedTitle = true
                let heading = stripInlineMarkup(text.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces))
                if heading == title { continue }
            }
            if text.hasPrefix("<!--") || text.hasPrefix("---") || text.hasPrefix("|") && text.allSatisfy({ "|-: ".contains($0) }) { continue }
            text = text.replacingOccurrences(of: #"^(#{1,6}\s+|>\s*|[-*+]\s+\[[ xX]\]\s+|[-*+]\s+|\d+[.)]\s+)"#, with: "", options: .regularExpression)
            text = stripInlineMarkup(text)
            guard !text.isEmpty else { continue }
            parts.append(text)
            length += text.count + 1
            if length >= limit { break }
        }
        let joined = parts.joined(separator: " ")
        return joined.count > limit ? String(joined.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…" : joined
    }

    static func stripInlineMarkup(_ text: String) -> String {
        var result = text
        // Images, media embeds and links: keep the label.
        result = result.replacingOccurrences(of: #"(?<!\\)[!+]?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(\*\*|__|~~|`)"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?<![\w*])[*_](?=\S)([^*_]+)(?<=\S)[*_](?![\w*])"#, with: "$1", options: .regularExpression)
        return result
    }
}

/// Builds file names from titles.
public enum NoteFileName {
    /// A Finder-friendly file name (without extension) for a title.
    public static func sanitized(_ title: String, fallback: String = "Untitled") -> String {
        var name = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        name = name.components(separatedBy: .controlCharacters).joined()
        name = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        if name.count > 80 { name = String(name.prefix(80)).trimmingCharacters(in: .whitespaces) }
        return name.isEmpty ? fallback : name
    }

    /// `base.ext`, or `base 2.ext`, `base 3.ext`… so it doesn't collide with an existing item in `directory`.
    public static func uniqueURL(in directory: URL, base: String, pathExtension: String?, excluding: URL? = nil) -> URL {
        let fileManager = FileManager.default
        var attempt = 1
        while true {
            let name = attempt == 1 ? base : "\(base) \(attempt)"
            var url = directory.appendingPathComponent(name, isDirectory: pathExtension == nil)
            if let pathExtension { url = url.appendingPathExtension(pathExtension) }
            if url.standardizedFileURL == excluding?.standardizedFileURL { return url }
            if !fileManager.fileExists(atPath: url.path) { return url }
            // On case-insensitive volumes a case-only rename finds the item itself.
            if let excluding, isSameItem(url, excluding) { return url }
            attempt += 1
        }
    }

    private static func isSameItem(_ lhs: URL, _ rhs: URL) -> Bool {
        let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let left = try? lhs.resourceValues(forKeys: key).fileResourceIdentifier,
              let right = try? rhs.resourceValues(forKeys: key).fileResourceIdentifier
        else { return false }
        return left.isEqual(right)
    }

    /// Whether a note still has an automatic name and should follow its heading.
    public static func isUntitled(_ baseName: String) -> Bool {
        baseName == "Untitled" || baseName.range(of: #"^Untitled \d+$"#, options: .regularExpression) != nil
    }
}
