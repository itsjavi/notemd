import AppKit
import Observation

enum EditorMode: String, CaseIterable, Identifiable {
    case edit, split, preview
    var id: String { rawValue }

    var title: String {
        switch self {
        case .edit: "Editor"
        case .split: "Split"
        case .preview: "Preview"
        }
    }

    var symbol: String {
        switch self {
        case .edit: "square.and.pencil"
        case .split: "rectangle.split.2x1"
        case .preview: "eye"
        }
    }
}

enum EditorFontStyle: String, CaseIterable, Identifiable {
    case system, monospaced, serif
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .monospaced: "Monospaced"
        case .serif: "Serif"
        }
    }
}

enum NoteSortOrder: String, CaseIterable, Identifiable {
    case modified, created, title
    var id: String { rawValue }

    var title: String {
        switch self {
        case .modified: "Date Edited"
        case .created: "Date Created"
        case .title: "Title"
        }
    }
}

/// App preferences, written through to UserDefaults.
@Observable final class AppSettings {
    static let shared = AppSettings()

    @ObservationIgnored private let defaults = UserDefaults.standard

    /// Seconds of inactivity before pending edits are committed.
    var commitDelay: Double { didSet { defaults.set(commitDelay, forKey: Keys.commitDelay) } }
    var editorFontStyle: EditorFontStyle { didSet { defaults.set(editorFontStyle.rawValue, forKey: Keys.editorFontStyle) } }
    var editorFontSize: Double { didSet { defaults.set(editorFontSize, forKey: Keys.editorFontSize) } }
    var readableLineWidth: Bool { didSet { defaults.set(readableLineWidth, forKey: Keys.readableLineWidth) } }
    var spellChecking: Bool { didSet { defaults.set(spellChecking, forKey: Keys.spellChecking) } }
    var showFrontMatter: Bool { didSet { defaults.set(showFrontMatter, forKey: Keys.showFrontMatter) } }
    var editorMode: EditorMode { didSet { defaults.set(editorMode.rawValue, forKey: Keys.editorMode) } }
    var sortOrder: NoteSortOrder { didSet { defaults.set(sortOrder.rawValue, forKey: Keys.sortOrder) } }
    var includeSubfolders: Bool { didSet { defaults.set(includeSubfolders, forKey: Keys.includeSubfolders) } }
    /// Remote images can track when a file is opened; off means only local images load.
    var loadRemoteImages: Bool { didSet { defaults.set(loadRemoteImages, forKey: Keys.loadRemoteImages) } }
    /// Most recent first, `~`-abbreviated paths.
    var recentRepositories: [String] { didSet { defaults.set(recentRepositories, forKey: Keys.recentRepositories) } }
    /// Repositories open at quit, reopened at launch.
    var openRepositories: [String] { didSet { defaults.set(openRepositories, forKey: Keys.openRepositories) } }

    private enum Keys {
        static let commitDelay = "commitDelay"
        static let editorFontStyle = "editorFontStyle"
        static let editorFontSize = "editorFontSize"
        static let readableLineWidth = "readableLineWidth"
        static let spellChecking = "spellChecking"
        static let showFrontMatter = "showFrontMatter"
        static let editorMode = "editorMode"
        static let sortOrder = "sortOrder"
        static let includeSubfolders = "includeSubfolders"
        static let loadRemoteImages = "loadRemoteImages"
        static let recentRepositories = "recentRepositories"
        static let openRepositories = "openRepositories"
    }

    private init() {
        defaults.register(defaults: [
            Keys.commitDelay: 30.0,
            Keys.editorFontStyle: EditorFontStyle.system.rawValue,
            Keys.editorFontSize: 15.0,
            Keys.readableLineWidth: true,
            Keys.spellChecking: true,
            Keys.showFrontMatter: false,
            Keys.editorMode: EditorMode.edit.rawValue,
            Keys.sortOrder: NoteSortOrder.modified.rawValue,
            Keys.includeSubfolders: true,
            Keys.loadRemoteImages: true,
        ])
        commitDelay = defaults.double(forKey: Keys.commitDelay)
        editorFontStyle = EditorFontStyle(rawValue: defaults.string(forKey: Keys.editorFontStyle) ?? "") ?? .system
        editorFontSize = defaults.double(forKey: Keys.editorFontSize)
        readableLineWidth = defaults.bool(forKey: Keys.readableLineWidth)
        spellChecking = defaults.bool(forKey: Keys.spellChecking)
        showFrontMatter = defaults.bool(forKey: Keys.showFrontMatter)
        editorMode = EditorMode(rawValue: defaults.string(forKey: Keys.editorMode) ?? "") ?? .edit
        sortOrder = NoteSortOrder(rawValue: defaults.string(forKey: Keys.sortOrder) ?? "") ?? .modified
        includeSubfolders = defaults.bool(forKey: Keys.includeSubfolders)
        loadRemoteImages = defaults.bool(forKey: Keys.loadRemoteImages)
        recentRepositories = defaults.stringArray(forKey: Keys.recentRepositories) ?? []
        openRepositories = defaults.stringArray(forKey: Keys.openRepositories) ?? []
    }

    func noteRecentRepository(_ url: URL) {
        let path = PathDisplay.abbreviate(url)
        recentRepositories = Array(([path] + recentRepositories.filter { $0 != path }).prefix(12))
    }

    func forgetRecentRepository(_ path: String) {
        recentRepositories.removeAll { $0 == path }
    }

    // MARK: Fonts

    func editorFont(monospacedOverride: Bool = false) -> NSFont {
        let size = CGFloat(editorFontSize)
        if monospacedOverride || editorFontStyle == .monospaced {
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        if editorFontStyle == .serif, let descriptor = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif) {
            return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size)
        }
        return .systemFont(ofSize: size)
    }
}

enum PathDisplay {
    static func abbreviate(_ url: URL) -> String {
        (url.standardizedFileURL.path as NSString).abbreviatingWithTildeInPath
    }

    static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }
}
