import AppKit
import NoteMDCore
import Observation
import SwiftUI

/// Owns repository windows and the welcome window.
@Observable final class WindowManager {
    static let shared = WindowManager()

    private(set) var controllers: [RepositoryWindowController] = []
    /// Store of the most recently focused repository window.
    private(set) var activeStore: RepositoryStore?
    @ObservationIgnored private var welcomeWindow: NSWindow?
    @ObservationIgnored var isTerminating = false

    private init() {
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] notification in
            let windowID = (notification.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let windowID else { return }
                if let controller = self.controllers.first(where: { $0.window.map(ObjectIdentifier.init) == windowID }) {
                    self.activeStore = controller.store
                    AppSettings.shared.noteRecentRepository(controller.store.rootURL)
                }
            }
        }
    }

    var hasRepositoryWindows: Bool { !controllers.isEmpty }

    // MARK: Opening

    /// Opens (or focuses) a repository in its own window.
    func openRepository(_ url: URL) {
        let url = url.canonical
        if let existing = controllers.first(where: { $0.store.rootURL == url }) {
            present(existing.window)
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            presentError("The folder “\(url.lastPathComponent)” doesn't exist anymore.")
            AppSettings.shared.forgetRecentRepository(PathDisplay.abbreviate(url))
            return
        }
        let controller = RepositoryWindowController(store: RepositoryStore(rootURL: url))
        controllers.append(controller)
        AppSettings.shared.noteRecentRepository(url)
        rememberOpenRepositories()
        closeWelcome()
        present(controller.window)
        activeStore = controller.store
    }

    /// Replaces the repository shown by `store`'s window.
    func switchRepository(of store: RepositoryStore, to url: URL) {
        let url = url.canonical
        if let existing = controllers.first(where: { $0.store.rootURL == url }) {
            present(existing.window)
            return
        }
        guard let controller = controllers.first(where: { $0.store === store }) else {
            openRepository(url)
            return
        }
        controller.switchTo(RepositoryStore(rootURL: url))
        AppSettings.shared.noteRecentRepository(url)
        rememberOpenRepositories()
        activeStore = controller.store
    }

    func chooseRepository(replacing store: RepositoryStore?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Open"
        panel.message = "Choose a folder of Markdown notes. It will be versioned with git automatically."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let store { switchRepository(of: store, to: url) } else { openRepository(url) }
    }

    func createRepository(replacing store: RepositoryStore?) {
        let panel = NSSavePanel()
        panel.title = "New Notes Folder"
        panel.prompt = "Create"
        panel.nameFieldLabel = "Folder name:"
        panel.nameFieldStringValue = "Notes"
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try RepositorySeeder.createRepository(at: url)
        } catch {
            presentError("Couldn't create the folder: \(error.localizedDescription)")
            return
        }
        if let store { switchRepository(of: store, to: url) } else { openRepository(url) }
    }

    enum OpenOutcome {
        case repository, note, document, attachment, failed
    }

    /// Opens a file: folders as repositories, notes inside an open repository are selected there, text files
    /// open as documents, and anything else becomes a new note embedding it in the most recent repository.
    @discardableResult
    func openFile(_ url: URL) -> OpenOutcome {
        let url = url.canonical
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            openRepository(url)
            return .repository
        }
        if NoteMDCore.noteExtensions.contains(url.pathExtension.lowercased()),
           let controller = controllers.first(where: { url.path.hasPrefix($0.store.contentURL.canonical.path + "/") }) {
            let store = controller.store
            let path = store.relativePath(of: url)
            if !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
                store.sidebarSelection = .allNotes
                store.selectedNoteID = path
                present(controller.window)
                return .note
            }
        }
        if FileManager.default.fileExists(atPath: url.path), !TextDetection.isText(at: url) {
            return addToNotes([url]) ? .attachment : .failed
        }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { MainActor.assumeIsolated { _ = NSApp.presentError(error) } }
        }
        closeWelcome()
        return .document
    }

    /// The repository files from other apps go to: the last focused window, else the most recent repository.
    func destinationStore() -> RepositoryStore? {
        if let store = activeStore ?? controllers.last?.store { return store }
        let recent = AppSettings.shared.recentRepositories.map(PathDisplay.expand)
            .first { FileManager.default.fileExists(atPath: $0.path) }
        guard let recent else { return nil }
        openRepository(recent)
        return activeStore
    }

    /// New notes embedding `files` (copied into assets) in the destination repository.
    @discardableResult
    func addToNotes(_ files: [URL]) -> Bool {
        guard let store = destinationStore() else {
            presentError("Open a notes folder first to add “\(files.first?.lastPathComponent ?? "the file")” to a note.")
            showWelcome()
            return false
        }
        store.addNotes(embedding: files)
        if let controller = controllers.first(where: { $0.store === store }) { present(controller.window) }
        return true
    }

    /// Services menu: a new note from the selection in another app.
    func addNoteFromService(_ pasteboard: NSPasteboard) {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let web = files.isEmpty ? (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []) : []
        let text = pasteboard.string(forType: .string) ?? web.first?.absoluteString
        let image = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
        guard let store = destinationStore() else {
            presentError("Open a notes folder first to create notes from other apps.")
            showWelcome()
            return
        }
        store.addNote(text: files.isEmpty ? text : nil, files: files, imageData: image)
        if let controller = controllers.first(where: { $0.store === store }) { present(controller.window) }
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = "Open a notes folder, or a Markdown or text file."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { openFile(url) }
    }

    // MARK: Windows

    func present(_ window: NSWindow?) {
        guard let window else { return }
        if AppVariant.isBackground {
            NSApp.unhideWithoutActivation()
            window.orderBack(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }

    func windowClosed(_ controller: RepositoryWindowController) {
        controllers.removeAll { $0 === controller }
        if activeStore === controller.store { activeStore = controllers.last?.store }
        if !isTerminating { rememberOpenRepositories() }
        let store = controller.store
        Task { await store.close() }
    }

    func rememberOpenRepositories() {
        AppSettings.shared.openRepositories = controllers.map { PathDisplay.abbreviate($0.store.rootURL) }
    }

    /// Reopens the repositories open at quit, or else the most recently used one that still exists.
    func restoreRepositories() {
        let settings = AppSettings.shared
        for url in settings.openRepositories.map(PathDisplay.expand) where FileManager.default.fileExists(atPath: url.path) {
            openRepository(url)
        }
        guard controllers.isEmpty else { return }
        if let recent = settings.recentRepositories.map(PathDisplay.expand).first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            openRepository(recent)
        }
    }

    func showWelcome() {
        if let welcomeWindow {
            present(welcomeWindow)
            return
        }
        let hosting = NSHostingController(rootView: WelcomeView())
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.title = "Welcome to NoteMD"
        window.center()
        welcomeWindow = window
        present(window)
    }

    func closeWelcome() {
        welcomeWindow?.close()
        welcomeWindow = nil
    }

    func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        if !AppVariant.isBackground { alert.runModal() }
    }

    /// Commits pending work in every repository (quit).
    func closeAll() async {
        for controller in controllers {
            await controller.store.close()
        }
    }
}

/// A window showing one repository.
final class RepositoryWindowController: NSWindowController, NSWindowDelegate {
    private(set) var store: RepositoryStore

    init(store: RepositoryStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.titlebarSeparatorStyle = .automatic
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self
        install(store)
        window.center()
        window.setFrameAutosaveName("Repository " + store.rootURL.path)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func install(_ store: RepositoryStore) {
        let hosting = NSHostingController(rootView: RepositoryWindowView().environment(store))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        hosting.sizingOptions = [.minSize]
        window?.contentViewController = hosting
        window?.title = store.name
        window?.representedURL = store.rootURL
        store.start()
    }

    func switchTo(_ newStore: RepositoryStore) {
        let old = store
        store = newStore
        install(newStore)
        window?.setFrameAutosaveName("Repository " + newStore.rootURL.path)
        Task { await old.close() }
    }

    func windowWillClose(_ notification: Notification) {
        WindowManager.shared.windowClosed(self)
    }
}

/// Creates new repositories with a couple of starter notes.
enum RepositorySeeder {
    static func createRepository(at url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        let existing = (try? fileManager.contentsOfDirectory(atPath: url.path)) ?? []
        guard existing.filter({ !$0.hasPrefix(".") }).isEmpty else { return }
        let notes = try RepositoryLayout.moveIntoNotesFolder([], at: url).contentURL(in: url)
        try welcome.write(to: notes.appendingPathComponent("Welcome to NoteMD.md"), atomically: true, encoding: .utf8)
        let templates = notes.appendingPathComponent("Templates", isDirectory: true)
        try fileManager.createDirectory(at: templates, withIntermediateDirectories: true)
        try FolderAppearance(icon: "wand.and.stars", color: .amber).save(to: templates)
        try promptTemplate.write(to: templates.appendingPathComponent("Code Review Prompt.md"), atomically: true, encoding: .utf8)
    }

    static let welcome = """
    ---
    tags: [getting-started]
    ---
    # Welcome to NoteMD

    Your notes are plain **Markdown files** in this folder. Organize them in folders, tag them, and find anything with search (⌘F in the list, or the search field).

    ## Every change is versioned

    NoteMD saves as you type and records a version with **git** a few seconds after you stop. Open **Version History** (the clock button) to compare and restore any earlier version — nothing is ever lost.

    ## Things to try

    - [ ] Create a note with ⌘N
    - [ ] Give a folder a color and icon (right-click it → Edit Folder…)
    - [ ] Switch between Editor, Split and Preview with ⌘1, ⌘2, ⌘3
    - [ ] Open the *Templates* folder and use the code review prompt

    > [!TIP]
    > Any `.md` or text file can also be opened on its own: drag it onto NoteMD in the Dock.

    | Shortcut | Action |
    | -------- | ------ |
    | ⌘S | Save a version now |
    | ⌥⌘Y | Version history |
    | ⌘↩ | Use template |
    """

    static let promptTemplate = """
    ---
    tags: [prompts]
    params:
      - name: project
        type: text
        label: Project name
        required: true
        placeholder: My App
      - name: language
        type: choice
        options: [Swift, TypeScript, Python, Go, Rust]
      - name: focus
        type: multichoice
        label: Focus on
        options: [correctness, security, performance, readability]
        default: [correctness, security]
      - name: files
        type: list
        help: One path per line
      - name: strict
        type: toggle
        label: Be strict
    ---
    # Code review: {{project}}

    Review the following {{language}} changes in **{{project}}**.

    {{#if focus}}
    Pay special attention to: {{focus}}.
    {{/if}}
    {{#if files}}
    Files to review:
    {{#each files}}
    - `{{.}}`
    {{/each}}
    {{/if}}
    {{#if strict}}
    Be strict: flag anything that would not pass a senior review.
    {{else}}
    Focus on the issues that matter most; skip nitpicks.
    {{/if}}
    """
}
