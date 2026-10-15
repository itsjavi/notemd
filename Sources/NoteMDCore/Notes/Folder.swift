import Foundation

/// Folder colors offered by the app. Stored by name in `.notemd.json`.
public enum FolderColor: String, Sendable, CaseIterable, Codable, Identifiable {
    case red, orange, amber, yellow, lime, green, mint, teal, cyan, blue, indigo, purple, pink
    case silver, gray, graphite, charcoal

    public var id: String { rawValue }
    public var isNeutral: Bool { [.silver, .gray, .graphite, .charcoal].contains(self) }
}

/// Per-folder appearance persisted as `.notemd.json` inside the folder, with whether the folder is hidden.
public struct FolderAppearance: Sendable, Hashable, Codable {
    /// SF Symbol name.
    public var icon: String?
    public var color: FolderColor?
    /// Kept off the screen until the app is unlocked (decision-6). Metadata only: nothing is encrypted.
    public var hidden: Bool

    public init(icon: String? = nil, color: FolderColor? = nil, hidden: Bool = false) {
        self.icon = icon
        self.color = color
        self.hidden = hidden
    }

    /// No custom icon or color.
    public var isDefault: Bool { icon == nil && color == nil }

    public static let fileName = ".notemd.json"

    enum CodingKeys: String, CodingKey { case icon, color, hidden }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        // Unknown color names fall back to default instead of failing the whole file.
        color = (try? container.decodeIfPresent(String.self, forKey: .color)).flatMap { $0.flatMap(FolderColor.init(rawValue:)) }
        hidden = (try? container.decodeIfPresent(Bool.self, forKey: .hidden)) ?? false
    }

    public static func load(from folder: URL) -> FolderAppearance {
        let url = folder.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return FolderAppearance() }
        return (try? JSONDecoder().decode(FolderAppearance.self, from: data)) ?? FolderAppearance()
    }

    /// Writes the file, merging unknown keys already present; removes it when everything is default.
    public func save(to folder: URL) throws {
        let url = folder.appendingPathComponent(Self.fileName)
        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = existing
        }
        object["icon"] = icon
        object["color"] = color?.rawValue
        object["hidden"] = hidden ? true : nil
        if object.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }
}

/// A folder in the repository tree.
public struct Folder: Sendable, Hashable, Identifiable {
    /// Repository-relative path ("" for the root).
    public var id: String { path }
    public let path: String
    public var name: String
    public var appearance: FolderAppearance
    public var children: [Folder]
    /// Notes directly inside this folder.
    public var noteCount: Int
    /// Notes in this folder and all descendants.
    public var totalNoteCount: Int

    public init(path: String, name: String, appearance: FolderAppearance = FolderAppearance(), children: [Folder] = [], noteCount: Int = 0, totalNoteCount: Int = 0) {
        self.path = path
        self.name = name
        self.appearance = appearance
        self.children = children
        self.noteCount = noteCount
        self.totalNoteCount = totalNoteCount
    }

    public var isRoot: Bool { path.isEmpty }

    /// Children for outline views (nil for leaves, so no disclosure triangle).
    public var outlineChildren: [Folder]? { children.isEmpty ? nil : children }

    public func find(_ path: String) -> Folder? {
        if self.path == path { return self }
        for child in children {
            if path == child.path || path.hasPrefix(child.path + "/") { return child.find(path) }
        }
        return nil
    }

    /// Depth-first list of all folders (excluding self).
    public var descendants: [Folder] { children.flatMap { [$0] + $0.descendants } }

    public var isHidden: Bool { appearance.hidden }

    /// Paths of the folders marked hidden (their sub-folders are hidden with them).
    public var hiddenFolderPaths: [String] { descendants.filter(\.isHidden).map(\.path) }

    /// Whether the note or folder at `path` is one of `folders` or inside one of them.
    public static func path(_ path: String, isInside folders: [String]) -> Bool {
        folders.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// The tree as shown: without hidden folders and their sub-folders unless `includingHidden`, with note counts
    /// taken from `notePaths` (the notes that are listed) instead of the files on disk.
    public func visibleTree(includingHidden: Bool, counting notePaths: [String]) -> Folder {
        var direct: [String: Int] = [:]
        for path in notePaths {
            let parent = (path as NSString).deletingLastPathComponent
            direct[parent == "." ? "" : parent, default: 0] += 1
        }
        func rebuild(_ folder: Folder) -> Folder {
            var copy = folder
            copy.children = folder.children.filter { includingHidden || !$0.isHidden }.map(rebuild)
            copy.noteCount = direct[folder.path] ?? 0
            copy.totalNoteCount = copy.noteCount + copy.children.reduce(0) { $0 + $1.totalNoteCount }
            return copy
        }
        return rebuild(self)
    }
}
