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

/// What the Tab key inserts in the editor.
struct Indentation: Equatable {
    var usesTabs: Bool
    var width: Int

    /// The text one indent level adds.
    var unit: String { usesTabs ? "\t" : String(repeating: " ", count: width) }
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

/// What happens to files dropped or pasted into a note from outside its repository (decision-5).
enum AttachmentImportMode: String, CaseIterable, Identifiable {
    case ask, copy, link
    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: "Ask Each Time"
        case .copy: "Copy into Assets"
        case .link: "Link to Original"
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
    var showLineNumbers: Bool { didSet { defaults.set(showLineNumbers, forKey: Keys.showLineNumbers) } }
    /// Draws spaces, tabs and line breaks in the editor.
    var showInvisibles: Bool { didSet { defaults.set(showInvisibles, forKey: Keys.showInvisibles) } }
    /// Tab key inserts a tab character instead of spaces.
    var indentWithTabs: Bool { didSet { defaults.set(indentWithTabs, forKey: Keys.indentWithTabs) } }
    /// Spaces per indent level, and the display width of tab characters.
    var indentWidth: Int { didSet { defaults.set(indentWidth, forKey: Keys.indentWidth) } }
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
    /// Open the most recent notes folder instead of the welcome window (launch, Dock click with no windows).
    var alwaysOpenLastRepository: Bool { didSet { defaults.set(alwaysOpenLastRepository, forKey: Keys.alwaysOpenLastRepository) } }
    var attachmentImportMode: AttachmentImportMode { didSet { defaults.set(attachmentImportMode.rawValue, forKey: Keys.attachmentImportMode) } }
    /// Locale identifier preselected for transcriptions; empty means the system language.
    var transcriptionLanguage: String { didSet { defaults.set(transcriptionLanguage, forKey: Keys.transcriptionLanguage) } }
    /// Off gives the sidebar a solid background instead of the translucent glass that lets the desktop show through.
    var translucentWindows: Bool { didSet { defaults.set(translucentWindows, forKey: Keys.translucentWindows) } }
    /// Seconds without activity before NoteMD locks hidden folders and secret notes again (decision-6: at most 5 minutes).
    var lockAfter: Double { didSet { defaults.set(lockAfter, forKey: Keys.lockAfter) } }

    private enum Keys {
        static let commitDelay = "commitDelay"
        static let editorFontStyle = "editorFontStyle"
        static let editorFontSize = "editorFontSize"
        static let readableLineWidth = "readableLineWidth"
        static let spellChecking = "spellChecking"
        static let showLineNumbers = "showLineNumbers"
        static let showInvisibles = "showInvisibles"
        static let indentWithTabs = "indentWithTabs"
        static let indentWidth = "indentWidth"
        static let showFrontMatter = "showFrontMatter"
        static let editorMode = "editorMode"
        static let sortOrder = "sortOrder"
        static let includeSubfolders = "includeSubfolders"
        static let loadRemoteImages = "loadRemoteImages"
        static let recentRepositories = "recentRepositories"
        static let openRepositories = "openRepositories"
        static let alwaysOpenLastRepository = "alwaysOpenLastRepository"
        static let attachmentImportMode = "attachmentImportMode"
        static let transcriptionLanguage = "transcriptionLanguage"
        static let translucentWindows = "translucentWindows"
        static let lockAfter = "lockAfter"
    }

    private init() {
        defaults.register(defaults: [
            Keys.commitDelay: 30.0,
            Keys.editorFontStyle: EditorFontStyle.system.rawValue,
            Keys.editorFontSize: 15.0,
            Keys.readableLineWidth: true,
            Keys.spellChecking: true,
            Keys.showLineNumbers: false,
            Keys.showInvisibles: false,
            Keys.indentWithTabs: false,
            Keys.indentWidth: 4,
            Keys.showFrontMatter: false,
            Keys.editorMode: EditorMode.edit.rawValue,
            Keys.sortOrder: NoteSortOrder.modified.rawValue,
            Keys.includeSubfolders: true,
            Keys.loadRemoteImages: true,
            Keys.attachmentImportMode: AttachmentImportMode.ask.rawValue,
            Keys.transcriptionLanguage: "",
            Keys.translucentWindows: true,
            Keys.lockAfter: 120.0,
        ])
        commitDelay = defaults.double(forKey: Keys.commitDelay)
        editorFontStyle = EditorFontStyle(rawValue: defaults.string(forKey: Keys.editorFontStyle) ?? "") ?? .system
        editorFontSize = defaults.double(forKey: Keys.editorFontSize)
        readableLineWidth = defaults.bool(forKey: Keys.readableLineWidth)
        spellChecking = defaults.bool(forKey: Keys.spellChecking)
        showLineNumbers = defaults.bool(forKey: Keys.showLineNumbers)
        showInvisibles = defaults.bool(forKey: Keys.showInvisibles)
        indentWithTabs = defaults.bool(forKey: Keys.indentWithTabs)
        indentWidth = min(max(defaults.integer(forKey: Keys.indentWidth), 1), 8)
        showFrontMatter = defaults.bool(forKey: Keys.showFrontMatter)
        editorMode = EditorMode(rawValue: defaults.string(forKey: Keys.editorMode) ?? "") ?? .edit
        sortOrder = NoteSortOrder(rawValue: defaults.string(forKey: Keys.sortOrder) ?? "") ?? .modified
        includeSubfolders = defaults.bool(forKey: Keys.includeSubfolders)
        loadRemoteImages = defaults.bool(forKey: Keys.loadRemoteImages)
        recentRepositories = defaults.stringArray(forKey: Keys.recentRepositories) ?? []
        openRepositories = defaults.stringArray(forKey: Keys.openRepositories) ?? []
        alwaysOpenLastRepository = defaults.bool(forKey: Keys.alwaysOpenLastRepository)
        attachmentImportMode = AttachmentImportMode(rawValue: defaults.string(forKey: Keys.attachmentImportMode) ?? "") ?? .ask
        transcriptionLanguage = defaults.string(forKey: Keys.transcriptionLanguage) ?? ""
        translucentWindows = defaults.bool(forKey: Keys.translucentWindows)
        lockAfter = min(max(defaults.double(forKey: Keys.lockAfter), 1), 300)
    }

    var indentation: Indentation { Indentation(usesTabs: indentWithTabs, width: indentWidth) }

    func noteRecentRepository(_ url: URL) {
        let path = PathDisplay.abbreviate(url)
        guard recentRepositories.first != path else { return }
        recentRepositories = Array(([path] + recentRepositories.filter { $0 != path }).prefix(12))
    }

    func forgetRecentRepository(_ path: String) {
        recentRepositories.removeAll { $0 == path }
    }

    // MARK: Fonts

    func editorFont() -> NSFont {
        let size = CGFloat(editorFontSize)
        if editorFontStyle == .monospaced {
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
