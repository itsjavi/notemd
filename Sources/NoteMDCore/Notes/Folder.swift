import Foundation

/// Folder colors offered by the app. Stored by name in `.notemd.json`.
public enum FolderColor: String, Sendable, CaseIterable, Codable, Identifiable {
    case red, orange, amber, yellow, lime, green, mint, teal, cyan, blue, indigo, purple, pink
    case silver, gray, graphite, charcoal

    public var id: String { rawValue }
    public var isNeutral: Bool { [.silver, .gray, .graphite, .charcoal].contains(self) }
}

/// Per-folder appearance persisted as `.notemd.json` inside the folder.
public struct FolderAppearance: Sendable, Hashable, Codable {
    /// SF Symbol name.
    public var icon: String?
    public var color: FolderColor?

    public init(icon: String? = nil, color: FolderColor? = nil) {
        self.icon = icon
        self.color = color
    }

    public var isDefault: Bool { icon == nil && color == nil }

    public static let fileName = ".notemd.json"

    enum CodingKeys: String, CodingKey { case icon, color }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        // Unknown color names fall back to default instead of failing the whole file.
        color = (try? container.decodeIfPresent(String.self, forKey: .color)).flatMap { $0.flatMap(FolderColor.init(rawValue:)) }
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
}
