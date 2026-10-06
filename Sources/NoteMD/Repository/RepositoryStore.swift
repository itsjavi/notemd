import AppKit
import NoteMDCore
import Observation

enum SidebarItem: Hashable {
    case allNotes
    case templates
    case recentlyDeleted
    case folder(String)
    case tag(String)
}

enum SearchScope: Hashable {
    case everywhere
    case selection
}

struct NoteRow: Identifiable, Hashable {
    var id: String { note.id }
    let note: Note
    let snippet: String?
}

struct TagCount: Identifiable, Hashable {
    var id: String { tag.lowercased() }
    let tag: String
    let count: Int
}

/// Draft for the folder create/edit sheet.
struct FolderDraft: Identifiable, Hashable {
    enum Mode: Hashable {
        case create(parent: String)
        case edit(path: String)
    }

    var id: String {
        switch mode {
        case .create(let parent): "create:" + parent
        case .edit(let path): "edit:" + path
        }
    }

    var mode: Mode
    var name: String
    var appearance: FolderAppearance
}

enum RepositorySheet: Identifiable {
    case folder(FolderDraft)
    case renameNote(path: String)
    case history(path: String)
    case templateForm(path: String)
    case templateParameters(path: String)

    var id: String {
        switch self {
        case .folder(let draft): "folder:" + draft.id
        case .renameNote(let path): "rename:" + path
        case .history(let path): "history:" + path
        case .templateForm(let path): "form:" + path
        case .templateParameters(let path): "params:" + path
        }
    }
}

enum GitState: Equatable {
    case starting
    case disabled(String)
    case clean(lastCommit: Date?)
    case pending
    case committing
    case failed(String)
}

/// Everything a repository window shows: the notes tree, selection, the open note and versioning.
@Observable final class RepositoryStore: Identifiable {
    let id = UUID()
    let rootURL: URL
    let settings = AppSettings.shared

    private(set) var root: Folder
    private(set) var notes: [Note] = []
    private(set) var tags: [TagCount] = []
    private(set) var isLoaded = false
    private(set) var visibleNotes: [NoteRow] = []
    private(set) var deletedFiles: [GitDeletedFile] = []

    var sidebarSelection: SidebarItem? = .allNotes {
        didSet {
            guard sidebarSelection != oldValue else { return }
            refreshVisibleNotes()
            if sidebarSelection == .recentlyDeleted { Task { await loadDeletedFiles() } }
        }
    }
    var selectedNoteID: String? {
        didSet {
            guard selectedNoteID != oldValue, !suppressReopen else { return }
            openSelectedNote(previousPath: oldValue)
        }
    }
    var selectedDeletedPath: String?
    var searchText = "" { didSet { if searchText != oldValue { refreshVisibleNotes() } } }
    var searchScope: SearchScope = .everywhere { didSet { refreshVisibleNotes() } }

    private(set) var editor: NoteEditor?
    var sheet: RepositorySheet?
    var errorMessage: String?
    private(set) var gitState: GitState = .starting

    @ObservationIgnored private var notesByPath: [String: Note] = [:]
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private(set) var git: GitClient?
    @ObservationIgnored private var autoCommitter: AutoCommitter?
    @ObservationIgnored private var isScanning = false
    @ObservationIgnored private var needsRescan = false
    @ObservationIgnored private var commitDelayObservation = false

    var name: String { rootURL.lastPathComponent }
    var displayPath: String { PathDisplay.abbreviate(rootURL) }

    init(rootURL: URL) {
        self.rootURL = rootURL.canonical
        root = Folder(path: "", name: rootURL.lastPathComponent, appearance: FolderAppearance.load(from: rootURL))
    }

    // MARK: Lifecycle

    func start() {
        watcher = FileWatcher(url: rootURL) { [weak self] paths in self?.filesChanged(paths) }
        Task {
            await reload()
            await setUpGit()
        }
        observeCommitDelay()
    }

    /// Saves the open note, applies an automatic name and commits everything pending.
    func close() async {
        if let editor {
            editor.save()
            finalizeName(of: editor.path)
        }
        watcher?.stop()
        watcher = nil
        await autoCommitter?.flush()
        autoCommitter?.cancel()
    }

    private func observeCommitDelay() {
        withObservationTracking {
            _ = settings.commitDelay
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.autoCommitter?.idleDelay = self.settings.commitDelay
                    self.observeCommitDelay()
                }
            }
        }
    }

    // MARK: Scanning

    func reload() async {
        if isScanning {
            needsRescan = true
            return
        }
        isScanning = true
        defer { isScanning = false }
        repeat {
            needsRescan = false
            let rootURL = self.rootURL
            let previous = notesByPath
            do {
                let snapshot = try await Task.detached { try RepositoryScanner.scan(rootURL: rootURL, previous: previous) }.value
                apply(snapshot)
            } catch {
                errorMessage = "Couldn't read “\(name)”: \(error.localizedDescription)"
            }
        } while needsRescan
    }

    private func apply(_ snapshot: RepositorySnapshot) {
        root = snapshot.root
        notes = snapshot.notes
        notesByPath = Dictionary(snapshot.notes.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        tags = snapshot.allTags.map { TagCount(tag: $0.tag, count: $0.count) }
        isLoaded = true
        if case .folder(let path) = sidebarSelection, root.find(path) == nil { sidebarSelection = .allNotes }
        refreshVisibleNotes()
        reconcileOpenNote()
    }

    private func filesChanged(_ paths: [String]) {
        let rootPath = rootURL.path
        let relevant = paths.contains { path in
            guard path.hasPrefix(rootPath) else { return false }
            let relative = String(path.dropFirst(rootPath.count))
            if relative.contains("/.git/") || relative.hasSuffix("/.git") { return false }
            let components = relative.split(separator: "/")
            // Hidden items don't matter, except folder appearance files.
            return !components.contains { $0.hasPrefix(".") && $0 != Substring(FolderAppearance.fileName) }
        }
        guard relevant else { return }
        autoCommitter?.markDirty()
        updatePendingState()
        Task { await reload() }
    }

    /// Picks up external edits to the open note, or closes it when its file disappeared.
    private func reconcileOpenNote() {
        guard let editor else { return }
        guard notesByPath[editor.path] != nil else {
            if !FileManager.default.fileExists(atPath: editor.url.path) {
                self.editor = nil
                selectedNoteID = nil
            }
            return
        }
        guard let diskText = RepositoryScanner.readText(editor.url), !editor.isOwnWrite(diskText) else { return }
        if !editor.isDirty {
            editor.replaceText(diskText, markSaved: true)
        }
    }

    // MARK: Visible notes

    var selectionTitle: String {
        switch sidebarSelection {
        case .allNotes, .none: "All Notes"
        case .templates: "Templates"
        case .recentlyDeleted: "Recently Deleted"
        case .folder(let path): path.isEmpty ? name : (root.find(path)?.name ?? (path as NSString).lastPathComponent)
        case .tag(let tag): "#" + tag
        }
    }

    func refreshVisibleNotes() {
        let query = SearchQuery(searchText)
        var pool: [Note]
        if !query.isEmpty && searchScope == .everywhere {
            pool = notes
        } else {
            pool = notes.filter(matchesSelection)
        }
        if query.isEmpty {
            pool.sort(by: sortComparator)
            visibleNotes = pool.map { NoteRow(note: $0, snippet: nil) }
        } else {
            visibleNotes = NoteSearch.search(query, in: pool).map { NoteRow(note: $0.note, snippet: $0.snippet) }
        }
    }

    private func matchesSelection(_ note: Note) -> Bool {
        switch sidebarSelection {
        case .allNotes, .none: true
        case .templates: note.isTemplate
        case .recentlyDeleted: false
        case .folder(let path):
            if path.isEmpty { settings.includeSubfolders || note.folderPath.isEmpty }
            else { note.folderPath == path || (settings.includeSubfolders && note.folderPath.hasPrefix(path + "/")) }
        case .tag(let tag): note.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame || $0.lowercased().hasPrefix(tag.lowercased() + "/") }
        }
    }

    private var sortComparator: (Note, Note) -> Bool {
        switch settings.sortOrder {
        case .modified: { $0.modified > $1.modified }
        case .created: { $0.created > $1.created }
        case .title: { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    func note(at path: String) -> Note? { notesByPath[path] }

    /// The folder new notes go into for the current selection.
    var targetFolderPath: String {
        if case .folder(let path) = sidebarSelection { return path }
        return ""
    }

    // MARK: Opening notes

    private func openSelectedNote(previousPath: String?) {
        if let editor {
            editor.save()
            if let previousPath { finalizeName(of: previousPath) }
        }
        guard let path = selectedNoteID, let note = notesByPath[path] ?? scanSingle(path) else {
            editor = nil
            return
        }
        guard let text = RepositoryScanner.readText(note.url) else {
            errorMessage = "Couldn't open “\(note.fileName)”."
            editor = nil
            return
        }
        let editor = NoteEditor(path: note.path, url: note.url, text: text, showsFrontMatter: settings.showFrontMatter)
        editor.onSave = { [weak self] editor in self?.noteSaved(editor) }
        editor.onSaveError = { [weak self] error in self?.errorMessage = "Couldn't save the note: \(error.localizedDescription)" }
        self.editor = editor
    }

    /// Reopens the current note, e.g. after toggling front matter visibility.
    func reopenCurrentNote() {
        guard let path = selectedNoteID else { return }
        editor?.save()
        editor = nil
        selectedNoteID = nil
        selectedNoteID = path
    }

    private func scanSingle(_ path: String) -> Note? {
        let url = rootURL.appendingPathComponent(path)
        guard let text = RepositoryScanner.readText(url) else { return nil }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey])
        let note = Note(path: path, url: url, text: text, modified: values?.contentModificationDate ?? Date(), created: values?.creationDate ?? Date(), size: values?.fileSize ?? 0)
        upsert(note)
        return note
    }

    private func upsert(_ note: Note) {
        notesByPath[note.path] = note
        if let index = notes.firstIndex(where: { $0.path == note.path }) {
            notes[index] = note
        } else {
            notes.append(note)
        }
    }

    private func noteSaved(_ editor: NoteEditor) {
        let values = try? editor.url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let previous = notesByPath[editor.path]
        let note = Note(path: editor.path, url: editor.url, text: editor.fullText, modified: values?.contentModificationDate ?? Date(), created: previous?.created ?? Date(), size: values?.fileSize ?? 0)
        upsert(note)
        if previous?.tags != note.tags {
            tags = RepositorySnapshot(root: root, notes: notes).allTags.map { TagCount(tag: $0.tag, count: $0.count) }
        }
        refreshVisibleNotes()
        autoCommitter?.markDirty()
        updatePendingState()
    }

    /// Renames `Untitled` notes after their heading once the user leaves them.
    private func finalizeName(of path: String) {
        guard let note = notesByPath[path], NoteFileName.isUntitled(note.baseName) else { return }
        let title = note.title
        guard title != note.baseName, !NoteFileName.isUntitled(title), title != "Untitled" else { return }
        let base = NoteFileName.sanitized(title)
        let directory = note.url.deletingLastPathComponent()
        let target = NoteFileName.uniqueURL(in: directory, base: base, pathExtension: note.url.pathExtension, excluding: note.url)
        do {
            try FileManager.default.moveItem(at: note.url, to: target)
            let newPath = relativePath(of: target)
            notesByPath[path] = nil
            notes.removeAll { $0.path == path }
            if editor?.path == path { editor?.relocate(path: newPath, url: target) }
            _ = scanSingle(newPath)
            refreshVisibleNotes()
            autoCommitter?.markDirty()
        } catch {
            // Keep the automatic name; renaming is a convenience.
        }
    }

    func relativePath(of url: URL) -> String {
        let path = url.canonical.path
        let rootPath = rootURL.path
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    func url(forFolder path: String) -> URL {
        path.isEmpty ? rootURL : rootURL.appendingPathComponent(path, isDirectory: true)
    }

    // MARK: Note operations

    /// Creates a note and selects it. Returns its path.
    @discardableResult
    func createNote(in folderPath: String? = nil, title: String? = nil, body: String? = nil, tags: [String] = []) -> String? {
        let folder = folderPath ?? targetFolderPath
        let directory = url(forFolder: folder)
        let base = title.map { NoteFileName.sanitized($0) } ?? "Untitled"
        let target = NoteFileName.uniqueURL(in: directory, base: base, pathExtension: "md")
        var markdown = MarkdownText(frontMatter: nil, body: body ?? "# \(title ?? "")")
        var noteTags = tags
        if case .tag(let tag) = sidebarSelection, folderPath == nil { noteTags.append(tag) }
        if !noteTags.isEmpty {
            var frontMatter = FrontMatter()
            frontMatter.setTags(noteTags)
            markdown.frontMatter = frontMatter
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(markdown.text.utf8).write(to: target, options: .withoutOverwriting)
        } catch {
            errorMessage = "Couldn't create the note: \(error.localizedDescription)"
            return nil
        }
        let path = relativePath(of: target)
        _ = scanSingle(path)
        searchText = ""
        if folderPath != nil, sidebarSelection != .folder(folder), sidebarSelection != .allNotes {
            sidebarSelection = folder.isEmpty ? .allNotes : .folder(folder)
        } else if [.templates, .recentlyDeleted, nil].contains(sidebarSelection) {
            sidebarSelection = .allNotes
        }
        refreshVisibleNotes()
        selectedNoteID = path
        autoCommitter?.markDirty()
        updatePendingState()
        NotificationCenter.default.post(name: .focusEditor, object: self)
        return path
    }

    func renameNote(_ path: String, to newName: String) {
        guard let note = notesByPath[path] else { return }
        let base = NoteFileName.sanitized(newName, fallback: note.baseName)
        let target = NoteFileName.uniqueURL(in: note.url.deletingLastPathComponent(), base: base, pathExtension: note.url.pathExtension, excluding: note.url)
        guard target.standardizedFileURL != note.url.standardizedFileURL else { return }
        move(note: note, to: target)
    }

    func moveNote(_ path: String, toFolder folderPath: String) {
        guard let note = notesByPath[path], note.folderPath != folderPath else { return }
        let target = NoteFileName.uniqueURL(in: url(forFolder: folderPath), base: note.baseName, pathExtension: note.url.pathExtension)
        move(note: note, to: target)
    }

    private func move(note: Note, to target: URL) {
        let wasOpen = editor?.path == note.path
        if wasOpen { editor?.save() }
        do {
            try FileManager.default.moveItem(at: note.url, to: target)
        } catch {
            errorMessage = "Couldn't move “\(note.fileName)”: \(error.localizedDescription)"
            return
        }
        let newPath = relativePath(of: target)
        notesByPath[note.path] = nil
        notes.removeAll { $0.path == note.path }
        _ = scanSingle(newPath)
        if wasOpen {
            editor?.relocate(path: newPath, url: target)
            selectedNoteIDWithoutReopen(newPath)
        }
        refreshVisibleNotes()
        autoCommitter?.markDirty()
        updatePendingState()
        Task { await reload() }
    }

    /// Updates the selection to a renamed path while keeping the open editor (and its undo stack).
    @ObservationIgnored private var suppressReopen = false
    private func selectedNoteIDWithoutReopen(_ path: String) {
        suppressReopen = true
        selectedNoteID = path
        suppressReopen = false
    }

    func duplicateNote(_ path: String) {
        guard let note = notesByPath[path], let text = RepositoryScanner.readText(note.url) else { return }
        let target = NoteFileName.uniqueURL(in: note.url.deletingLastPathComponent(), base: note.baseName + " copy", pathExtension: note.url.pathExtension)
        do {
            try Data(text.utf8).write(to: target, options: .withoutOverwriting)
        } catch {
            errorMessage = "Couldn't duplicate the note: \(error.localizedDescription)"
            return
        }
        let newPath = relativePath(of: target)
        _ = scanSingle(newPath)
        refreshVisibleNotes()
        selectedNoteID = newPath
        autoCommitter?.markDirty()
    }

    func trashNote(_ path: String) {
        guard let note = notesByPath[path] else { return }
        if editor?.path == path {
            editor?.save()
            editor = nil
        }
        let index = visibleNotes.firstIndex { $0.id == path }
        do {
            try FileManager.default.trashItem(at: note.url, resultingItemURL: nil)
        } catch {
            errorMessage = "Couldn't move “\(note.fileName)” to the Trash: \(error.localizedDescription)"
            return
        }
        notesByPath[path] = nil
        notes.removeAll { $0.path == path }
        refreshVisibleNotes()
        if selectedNoteID == path {
            if let index, !visibleNotes.isEmpty {
                selectedNoteID = visibleNotes[min(index, visibleNotes.count - 1)].id
            } else {
                selectedNoteID = nil
            }
        }
        autoCommitter?.markDirty()
        updatePendingState()
        Task { await reload() }
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([rootURL.appendingPathComponent(path)])
    }

    // MARK: Folder operations

    func beginCreateFolder(in parent: String? = nil) {
        let parentPath: String
        if let parent { parentPath = parent } else if case .folder(let path) = sidebarSelection { parentPath = path } else { parentPath = "" }
        sheet = .folder(FolderDraft(mode: .create(parent: parentPath), name: "", appearance: FolderAppearance()))
    }

    func beginEditFolder(_ path: String) {
        guard let folder = root.find(path) else { return }
        sheet = .folder(FolderDraft(mode: .edit(path: path), name: path.isEmpty ? name : folder.name, appearance: folder.appearance))
    }

    func commitFolder(_ draft: FolderDraft) {
        let name = NoteFileName.sanitized(draft.name, fallback: "New Folder")
        switch draft.mode {
        case .create(let parent):
            let target = NoteFileName.uniqueURL(in: url(forFolder: parent), base: name, pathExtension: nil)
            do {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                try draft.appearance.save(to: target)
            } catch {
                errorMessage = "Couldn't create the folder: \(error.localizedDescription)"
                return
            }
            let path = relativePath(of: target)
            Task {
                await reload()
                sidebarSelection = .folder(path)
            }
        case .edit(let path):
            var folderURL = url(forFolder: path)
            var newPath = path
            if !path.isEmpty, let folder = root.find(path), folder.name != name {
                let target = NoteFileName.uniqueURL(in: folderURL.deletingLastPathComponent(), base: name, pathExtension: nil)
                do {
                    editor?.save()
                    try FileManager.default.moveItem(at: folderURL, to: target)
                    folderURL = target
                    newPath = relativePath(of: target)
                    relocateOpenNote(fromFolder: path, toFolder: newPath)
                } catch {
                    errorMessage = "Couldn't rename the folder: \(error.localizedDescription)"
                    return
                }
            }
            do {
                try draft.appearance.save(to: folderURL)
            } catch {
                errorMessage = "Couldn't save the folder style: \(error.localizedDescription)"
            }
            Task {
                await reload()
                if newPath != path, sidebarSelection == .folder(path) { sidebarSelection = .folder(newPath) }
            }
        }
        autoCommitter?.markDirty()
        updatePendingState()
    }

    func moveFolder(_ path: String, into parent: String) {
        guard !path.isEmpty, path != parent, !parent.hasPrefix(path + "/"), (path as NSString).deletingLastPathComponent != parent else { return }
        let source = url(forFolder: path)
        let target = NoteFileName.uniqueURL(in: url(forFolder: parent), base: source.lastPathComponent, pathExtension: nil)
        editor?.save()
        do {
            try FileManager.default.moveItem(at: source, to: target)
        } catch {
            errorMessage = "Couldn't move the folder: \(error.localizedDescription)"
            return
        }
        let newPath = relativePath(of: target)
        relocateOpenNote(fromFolder: path, toFolder: newPath)
        if sidebarSelection == .folder(path) { sidebarSelection = .folder(newPath) }
        autoCommitter?.markDirty()
        Task { await reload() }
    }

    private func relocateOpenNote(fromFolder old: String, toFolder new: String) {
        guard let editor, editor.path.hasPrefix(old + "/") else { return }
        let newPath = new + editor.path.dropFirst(old.count)
        editor.relocate(path: newPath, url: rootURL.appendingPathComponent(newPath))
        selectedNoteIDWithoutReopen(newPath)
    }

    func trashFolder(_ path: String) {
        guard !path.isEmpty else { return }
        if let editor, editor.path.hasPrefix(path + "/") {
            editor.save()
            self.editor = nil
            selectedNoteID = nil
        }
        do {
            try FileManager.default.trashItem(at: url(forFolder: path), resultingItemURL: nil)
        } catch {
            errorMessage = "Couldn't move the folder to the Trash: \(error.localizedDescription)"
            return
        }
        if case .folder(let selected) = sidebarSelection, selected == path || selected.hasPrefix(path + "/") { sidebarSelection = .allNotes }
        autoCommitter?.markDirty()
        Task { await reload() }
    }

    // MARK: Git

    private func setUpGit() async {
        guard let executable = GitClient.locateGit() else {
            gitState = .disabled("Install git (e.g. Xcode Command Line Tools or Homebrew) to version your notes.")
            return
        }
        let client = GitClient(repositoryURL: rootURL, executableURL: executable)
        if !(await client.isRepositoryRoot()) {
            if let topLevel = try? await client.run(["rev-parse", "--show-toplevel"]).trimmingCharacters(in: .whitespacesAndNewlines), !topLevel.isEmpty {
                git = client
                gitState = .disabled("This folder is inside the git repository at \(PathDisplay.abbreviate(URL(fileURLWithPath: topLevel))). Automatic commits are off to avoid committing unrelated files.")
                return
            }
            do {
                try await client.initialize()
                try await client.commitAll(message: "Start versioning notes with NoteMD")
            } catch {
                gitState = .failed(error.localizedDescription)
                return
            }
        }
        git = client
        let committer = AutoCommitter(git: client, idleDelay: settings.commitDelay, maxDelay: 300) { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleCommitEvent(event) }
            }
        }
        autoCommitter = committer
        gitState = .clean(lastCommit: try? await client.history(for: ".", limit: 1).first?.date)
        // Commit anything that changed while the app wasn't watching.
        if let status = try? await client.status(), !status.isEmpty {
            committer.markDirty()
            gitState = .pending
        }
    }

    private func handleCommitEvent(_ event: AutoCommitEvent) {
        switch event {
        case .committed(let commit):
            gitState = .clean(lastCommit: commit.date)
            NotificationCenter.default.post(name: .repositoryCommitted, object: self)
        case .nothingToCommit:
            if case .pending = gitState { gitState = .clean(lastCommit: nil) }
            if case .committing = gitState { gitState = .clean(lastCommit: nil) }
        case .failed(let message):
            gitState = .failed(message)
        }
    }

    private func updatePendingState() {
        guard autoCommitter != nil else { return }
        switch gitState {
        case .disabled, .starting: break
        default: gitState = .pending
        }
    }

    var isVersioned: Bool {
        switch gitState {
        case .starting, .disabled: false
        default: true
        }
    }

    /// Saves the open note and commits everything now (⌘S).
    func saveVersionNow() async {
        editor?.save()
        guard let autoCommitter else { return }
        gitState = .committing
        await autoCommitter.flush()
        if case .committing = gitState { gitState = .clean(lastCommit: Date()) }
    }

    /// Restores `path` to `content` from `revision` as a new commit.
    func restore(path: String, content: String, revision: String) async {
        await saveVersionNow()
        let url = rootURL.appendingPathComponent(path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url, options: .atomic)
        } catch {
            errorMessage = "Couldn't restore the note: \(error.localizedDescription)"
            return
        }
        if let editor, editor.path == path {
            editor.replaceText(content, markSaved: true)
        }
        _ = scanSingle(path)
        refreshVisibleNotes()
        if let git {
            do {
                try await git.commitAll(message: "Restore \(path) to \(revision.prefix(7))")
                gitState = .clean(lastCommit: Date())
            } catch {
                autoCommitter?.markDirty()
            }
        }
    }

    func loadDeletedFiles() async {
        guard let git else { return }
        let notesExtensions = NoteMDCore.noteExtensions
        let files = (try? await git.deletedFiles(limit: 200)) ?? []
        deletedFiles = files.filter { file in
            notesExtensions.contains((file.path as NSString).pathExtension.lowercased()) && notesByPath[file.path] == nil
        }
    }

    func restoreDeleted(_ file: GitDeletedFile) async {
        guard let git, let content = try? await git.content(of: file.path, at: file.lastRevision) else {
            errorMessage = "Couldn't read the deleted note from history."
            return
        }
        let original = rootURL.appendingPathComponent(file.path)
        let target = FileManager.default.fileExists(atPath: original.path)
            ? NoteFileName.uniqueURL(in: original.deletingLastPathComponent(), base: (original.lastPathComponent as NSString).deletingPathExtension, pathExtension: original.pathExtension)
            : original
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: target, options: .withoutOverwriting)
        } catch {
            errorMessage = "Couldn't restore the note: \(error.localizedDescription)"
            return
        }
        let path = relativePath(of: target)
        _ = scanSingle(path)
        deletedFiles.removeAll { $0.path == file.path }
        selectedDeletedPath = nil
        autoCommitter?.markDirty()
        updatePendingState()
        sidebarSelection = .allNotes
        selectedNoteID = path
        await reload()
    }
}

extension Notification.Name {
    static let focusEditor = Notification.Name("NoteMDFocusEditor")
    static let repositoryCommitted = Notification.Name("NoteMDRepositoryCommitted")
}
