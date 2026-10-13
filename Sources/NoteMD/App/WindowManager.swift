import AppKit
import NoteMDCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

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

    /// Opens files from Finder, the Dock or Open…: folders as notes folders, Markdown files in the notes folder that
    /// has them or imported into one, and anything else as a new note embedding it.
    func open(_ urls: [URL]) {
        var markdown: [URL] = []
        var others: [URL] = []
        for url in urls.map(\.canonical) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                openRepository(url)
            } else if NoteImport.isMarkdown(url) {
                if !showExistingNote(url) { markdown.append(url) }
            } else {
                others.append(url)
            }
        }
        if !others.isEmpty { addToNotes(others) }
        if !markdown.isEmpty { requestImport(markdown) }
    }

    /// Shows a Markdown file that is already a note: in its open window, or by opening its recent notes folder.
    @discardableResult
    func showExistingNote(_ url: URL) -> Bool {
        let url = url.canonical
        if let controller = controllers.first(where: { url.path.hasPrefix($0.store.contentURL.canonical.path + "/") }) {
            controller.store.selectNote(controller.store.relativePath(of: url))
            present(controller.window)
            return true
        }
        let recent = AppSettings.shared.recentRepositories.map(PathDisplay.expand).first {
            url.path.hasPrefix($0.canonical.path + "/") && FileManager.default.fileExists(atPath: $0.path)
        }
        guard let recent else { return false }
        openRepository(recent)
        guard let store = controllers.first(where: { $0.store.rootURL == recent.canonical })?.store else { return false }
        // The notes folder's layout is only settled once it has loaded.
        store.whenLoaded { store.selectNote(store.relativePath(of: url)) }
        return true
    }

    // MARK: Importing Markdown files

    /// Markdown files waiting for the import confirmation. Background (Test) builds never show the alert; the
    /// `ui/import` hook answers it instead.
    @ObservationIgnored var pendingImport: [URL] = []

    /// Notes folders an imported file can go to: the active window's, other open ones, then recent ones.
    func importDestinations() -> [URL] {
        let open = ([activeStore].compactMap(\.self) + controllers.map(\.store)).map(\.rootURL)
        let recent = AppSettings.shared.recentRepositories.map(PathDisplay.expand).filter { FileManager.default.fileExists(atPath: $0.path) }
        var seen = Set<String>()
        return (open + recent).filter { seen.insert($0.canonical.path).inserted }
    }

    /// Asks which notes folder the Markdown files go to, and whether to copy or move them there.
    func requestImport(_ files: [URL]) {
        let destinations = importDestinations()
        guard !destinations.isEmpty else {
            presentError("Create or open a notes folder first, then open “\(files[0].lastPathComponent)” again to add it.")
            showWelcome()
            return
        }
        if AppVariant.isBackground {
            pendingImport = files
            return
        }
        // Out of the open-documents event: the alert runs its own modal loop.
        Task { runImportAlert(files, destinations) }
    }

    private func runImportAlert(_ files: [URL], _ destinations: [URL]) {
        let alert = NSAlert()
        alert.messageText = files.count == 1
            ? "Add “\(files[0].lastPathComponent)” to a notes folder?"
            : "Add \(files.count) Markdown files to a notes folder?"
        alert.informativeText = "NoteMD keeps notes in notes folders, versioned with git. Copy leaves the original where it is; Move takes it out of its current folder."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26), pullsDown: false)
        for url in destinations {
            popup.addItem(withTitle: url.lastPathComponent + " — " + PathDisplay.abbreviate(url.deletingLastPathComponent()))
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else {
            if !hasRepositoryWindows { showWelcome() }
            return
        }
        importNotes(files, into: destinations[max(popup.indexOfSelectedItem, 0)], move: response == .alertSecondButtonReturn)
    }

    func importNotes(_ files: [URL], into repository: URL, move: Bool) {
        openRepository(repository)
        guard let store = controllers.first(where: { $0.store.rootURL == repository.canonical })?.store else { return }
        store.importNotes(files, move: move)
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

    /// Services menu and Share menu: Markdown files are imported, anything else becomes a new note.
    func addNoteFromService(_ pasteboard: NSPasteboard) {
        let allFiles = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let markdown = allFiles.filter(NoteImport.isMarkdown)
        let files = allFiles.filter { !NoteImport.isMarkdown($0) }
        let web = allFiles.isEmpty ? (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []) : []
        // Selected files come with their names as text too: ignore it then.
        let text = allFiles.isEmpty ? pasteboard.string(forType: .string) ?? web.first?.absoluteString : nil
        let image = allFiles.isEmpty ? pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) : nil
        if !markdown.isEmpty { open(markdown) }
        guard !files.isEmpty || text != nil || image != nil else { return }
        guard let store = destinationStore() else {
            presentError("Open a notes folder first to create notes from other apps.")
            showWelcome()
            return
        }
        store.addNote(text: text, files: files, imageData: image)
        if let controller = controllers.first(where: { $0.store === store }) { present(controller.window) }
    }

    /// The Share menu's extension leaves what was shared on this pasteboard, then opens `<scheme>://share`.
    static let sharePasteboard = NSPasteboard.Name((Bundle.main.bundleIdentifier ?? "com.itsjavi.notemd") + ".share")

    func addSharedItems() {
        let pasteboard = NSPasteboard(name: Self.sharePasteboard)
        guard pasteboard.pasteboardItems?.isEmpty == false else { return }
        addNoteFromService(pasteboard)
        pasteboard.clearContents()
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.folder, UTType("net.daringfireball.markdown") ?? .plainText]
        panel.message = "Open a notes folder, or choose Markdown files to add to one."
        guard panel.runModal() == .OK else { return }
        open(panel.urls)
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

    /// Reopens the notes folders open at quit; with “Always open the last notes folder”, the most recent one otherwise.
    func restoreRepositories() {
        let settings = AppSettings.shared
        for url in settings.openRepositories.map(PathDisplay.expand) where FileManager.default.fileExists(atPath: url.path) {
            openRepository(url)
        }
        if controllers.isEmpty && settings.alwaysOpenLastRepository { openLastRepository() }
    }

    /// Opens the most recent notes folder that still exists; false when there's none.
    @discardableResult
    func openLastRepository() -> Bool {
        let recent = AppSettings.shared.recentRepositories.map(PathDisplay.expand).first { FileManager.default.fileExists(atPath: $0.path) }
        guard let recent else { return false }
        openRepository(recent)
        return true
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
        // A window made from a view controller starts empty; size it to its content before centring.
        window.layoutIfNeeded()
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
        // A new name: frames saved while windows opened off-centre aren't reused.
        let autosaveName = Self.autosaveName(store)
        if !window.setFrameUsingName(autosaveName) { window.center() }
        window.setFrameAutosaveName(autosaveName)
    }

    private static func autosaveName(_ store: RepositoryStore) -> String { "Repository Window " + store.rootURL.path }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func install(_ store: RepositoryStore) {
        let hosting = NSHostingController(rootView: RepositoryWindowView().environment(store))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        hosting.sizingOptions = [.minSize]
        // Installing a hosting controller shrinks the window to the view's initial, empty size: keep the frame.
        let frame = window?.frame
        window?.contentViewController = hosting
        if let frame { window?.setFrame(frame, display: false) }
        window?.title = store.name
        window?.representedURL = store.rootURL
        store.start()
    }

    func switchTo(_ newStore: RepositoryStore) {
        let old = store
        store = newStore
        install(newStore)
        window?.setFrameAutosaveName(Self.autosaveName(newStore))
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
        let notes = try RepositoryLayout.moveIntoFilesFolder(at: url).contentURL(in: url)
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
    > Drag a Markdown file onto NoteMD in the Dock, or share it from Finder, to copy or move it into a notes folder.

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
