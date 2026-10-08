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
    /// Transcribe the clip `source` (link destination as written) embedded in the note at `path`.
    case transcribe(path: String, source: String)

    var id: String {
        switch self {
        case .folder(let draft): "folder:" + draft.id
        case .renameNote(let path): "rename:" + path
        case .history(let path): "history:" + path
        case .templateForm(let path): "form:" + path
        case .templateParameters(let path): "params:" + path
        case .transcribe(let path, let source): "transcribe:" + path + ":" + source
        }
    }
}

enum GitState: Equatable {
    case starting
    case disabled(String)
    /// Folder looks like more than notes (home folder, many other files): ask before `git init`.
    case needsConsent(String)
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
    /// Attachments exist but Git LFS isn't installed, so they're kept out of commits.
    private(set) var lfsMissing = false
    let voiceRecorder = VoiceRecorder()
    var showsVoiceRecorder = false
    /// The syntax guide popover of the Template Parameters sheet.
    var showsTemplateGuide = false

    @ObservationIgnored private var lfsEnabled = false
    @ObservationIgnored private var notesByPath: [String: Note] = [:]
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private(set) var git: GitClient?
    @ObservationIgnored private var gitExecutable: URL?
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
        voiceRecorder.stop()
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
        let relevant = paths.compactMap { path -> String? in
            guard path == rootPath || path.hasPrefix(rootPath + "/") else { return nil }
            let relative = String(path.dropFirst(rootPath.count + 1))
            let components = relative.split(separator: "/")
            // Hidden items don't matter, except folder appearance files (this also skips .git).
            if components.contains(where: { $0.hasPrefix(".") && $0 != Substring(FolderAppearance.fileName) }) { return nil }
            // A recording in progress changes constantly; it's handled when it ends.
            return relative == recordingAsset ? nil : relative
        }
        guard !relevant.isEmpty else { return }
        autoCommitter?.markDirty()
        updatePendingState()
        let isAsset = { (path: String) in path.split(separator: "/").first?.lowercased() == Attachments.folderName }
        if relevant.contains(where: isAsset) { didAddAssets() }
        // Attachments hold no notes: only other changes need a rescan.
        if relevant.contains(where: { !isAsset($0) }) { Task { await reload() } }
    }

    /// Picks up external edits to the open note, or closes it when its file disappeared.
    private func reconcileOpenNote() {
        guard let editor else { return }
        guard FileManager.default.fileExists(atPath: editor.url.path) else {
            if editor.isDirty {
                // Unsaved typing wins: write it back rather than lose it.
                editor.save()
                return
            }
            // Tools like git checkout or sync clients delete and recreate files; give them a moment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self, weak editor] in
                MainActor.assumeIsolated {
                    guard let self, let editor, self.editor === editor, !editor.isDirty,
                          !FileManager.default.fileExists(atPath: editor.url.path) else { return }
                    self.editor = nil
                    self.selectedNoteID = nil
                }
            }
            return
        }
        guard let diskText = RepositoryScanner.readText(editor.url), !editor.isOwnWrite(diskText) else { return }
        if !editor.isDirty {
            editor.replaceText(diskText, markSaved: true)
        } else {
            saveConflictCopy(of: editor, diskText: diskText)
        }
    }

    /// Another app changed the open note while it had unsaved edits: keep both versions.
    private func saveConflictCopy(of editor: NoteEditor, diskText: String) {
        let stamp = Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "")
        let base = (editor.url.lastPathComponent as NSString).deletingPathExtension + " (changed elsewhere \(stamp))"
        let target = NoteFileName.uniqueURL(in: editor.url.deletingLastPathComponent(), base: base, pathExtension: editor.url.pathExtension)
        do {
            try Data(diskText.utf8).write(to: target, options: .withoutOverwriting)
            errorMessage = "“\(editor.title)” was changed by another app while you were editing. Your version is kept; the other one was saved as “\(target.lastPathComponent)”."
        } catch {
            errorMessage = "“\(editor.title)” was changed by another app while you were editing, and the other version couldn't be saved: \(error.localizedDescription)"
        }
        editor.save()
        Task { await reload() }
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
            guard editor.save() else {
                // Keep the note with unsaved edits open; `onSaveError` already explained why.
                suppressReopen = true
                selectedNoteID = previousPath
                suppressReopen = false
                return
            }
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
        guard path == rootPath || path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Only folders from the scanned tree: drag payloads and links can't reach outside the repository.
    func isKnownFolder(_ path: String) -> Bool {
        SafeFileWriter.isSafeRelativePath(path) && root.find(path) != nil
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
        editor?.wantsFocus = true
        autoCommitter?.markDirty()
        updatePendingState()
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
        guard let note = notesByPath[path], note.folderPath != folderPath, isKnownFolder(folderPath) else { return }
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
        if wasOpen {
            editor?.relocate(path: newPath, url: target)
            selectedNoteIDWithoutReopen(newPath)
        }
        rewriteAssetLinks(ofNoteAt: newPath, movedFrom: note.folderPath)
        _ = scanSingle(newPath)
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
        guard SafeFileWriter.isSafeRelativePath(path) else { return }
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
        guard !path.isEmpty, path != parent, !parent.hasPrefix(path + "/"), (path as NSString).deletingLastPathComponent != parent,
              isKnownFolder(path), isKnownFolder(parent) else { return }
        let source = url(forFolder: path)
        let target = NoteFileName.uniqueURL(in: url(forFolder: parent), base: source.lastPathComponent, pathExtension: nil)
        editor?.save()
        let movedNotes = notes.filter { $0.path.hasPrefix(path + "/") }
        do {
            try FileManager.default.moveItem(at: source, to: target)
        } catch {
            errorMessage = "Couldn't move the folder: \(error.localizedDescription)"
            return
        }
        let newPath = relativePath(of: target)
        relocateOpenNote(fromFolder: path, toFolder: newPath)
        for note in movedNotes {
            rewriteAssetLinks(ofNoteAt: newPath + note.path.dropFirst(path.count), movedFrom: note.folderPath)
        }
        if sidebarSelection == .folder(path) { sidebarSelection = .folder(newPath) }
        autoCommitter?.markDirty()
        Task { await reload() }
    }

    /// Keeps relative links into `assets/` resolving after a note moved to another folder.
    private func rewriteAssetLinks(ofNoteAt path: String, movedFrom oldDirectory: String) {
        let newDirectory = (path as NSString).deletingLastPathComponent
        guard newDirectory != oldDirectory else { return }
        if let editor, editor.path == path {
            let updated = Attachments.rewritingAssetLinks(in: editor.fullText, fromDirectory: oldDirectory, toDirectory: newDirectory)
            if updated != editor.fullText { editor.replaceText(updated, markSaved: false) }
            return
        }
        let url = rootURL.appendingPathComponent(path)
        guard let text = RepositoryScanner.readText(url) else { return }
        let updated = Attachments.rewritingAssetLinks(in: text, fromDirectory: oldDirectory, toDirectory: newDirectory)
        guard updated != text else { return }
        do {
            try SafeFileWriter.write(Data(updated.utf8), to: url)
        } catch {
            errorMessage = "Couldn't update the attachment links in “\(url.lastPathComponent)”: \(error.localizedDescription)"
        }
    }

    private func relocateOpenNote(fromFolder old: String, toFolder new: String) {
        guard let editor, editor.path.hasPrefix(old + "/") else { return }
        let newPath = new + editor.path.dropFirst(old.count)
        editor.relocate(path: newPath, url: rootURL.appendingPathComponent(newPath))
        selectedNoteIDWithoutReopen(newPath)
    }

    func trashFolder(_ path: String) {
        guard !path.isEmpty, isKnownFolder(path) else { return }
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
                // Paths and commits would refer to the parent repository; stay out of it entirely.
                gitState = .disabled("This folder is inside the git repository at \(PathDisplay.abbreviate(URL(fileURLWithPath: topLevel))). Open that repository's root, or a folder outside it, to get version history.")
                return
            }
            if let reason = await Task.detached(operation: { [rootURL] in RepositoryVetting.reasonToConfirm(rootURL) }).value {
                gitExecutable = executable
                gitState = .needsConsent(reason)
                return
            }
            do {
                try await initializeRepository(client)
            } catch {
                gitState = .failed(error.localizedDescription)
                return
            }
        }
        startVersioning(client)
    }

    /// Turns on versioning after the user confirmed it for this folder.
    func enableVersioning() async {
        guard case .needsConsent = gitState, let executable = gitExecutable else { return }
        let client = GitClient(repositoryURL: rootURL, executableURL: executable)
        gitState = .starting
        do {
            try await initializeRepository(client)
        } catch {
            gitState = .failed(error.localizedDescription)
            return
        }
        startVersioning(client)
    }

    private func initializeRepository(_ client: GitClient) async throws {
        try await client.initialize()
        RepositoryVetting.extendGitignore(at: rootURL)
        await checkAssetVersioning(using: client)
        try await client.commitAll(message: "Start versioning notes with NoteMD", excluding: commitExclusions)
    }

    private func startVersioning(_ client: GitClient) {
        git = client
        let committer = AutoCommitter(git: client, idleDelay: settings.commitDelay, maxDelay: 300) { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleCommitEvent(event) }
            }
        }
        // Until LFS is confirmed, never commit attachments as plain blobs.
        committer.excludedPaths = commitExclusions
        autoCommitter = committer
        gitState = .clean(lastCommit: nil)
        Task {
            await configureAssetVersioning()
            if let timestamp = try? await client.run(["log", "-1", "--format=%at"]).trimmingCharacters(in: .whitespacesAndNewlines),
               let seconds = TimeInterval(timestamp), case .clean = gitState {
                gitState = .clean(lastCommit: Date(timeIntervalSince1970: seconds))
            }
            // Commit anything that changed while the app wasn't watching.
            if let status = try? await client.status(), !status.isEmpty {
                committer.markDirty()
                gitState = .pending
            }
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
        case .disabled, .starting, .needsConsent: break
        default: gitState = .pending
        }
    }

    // MARK: Attachments

    var assetsURL: URL { rootURL.appendingPathComponent(Attachments.folderName, isDirectory: true) }
    private var hasAssets: Bool { FileManager.default.fileExists(atPath: assetsURL.path) }
    /// The voice note being recorded (repository-relative); kept out of commits until it's finished.
    @ObservationIgnored private var recordingAsset: String?
    @ObservationIgnored private var assetCheck: Task<Void, Never>?

    /// Paths left out of commits: `assets/` until Git LFS is set up for the repository (decision-5),
    /// so attachments never reach history as plain blobs, plus a recording in progress.
    private var commitExclusions: [String] {
        (lfsEnabled ? [] : [Attachments.folderName]) + (recordingAsset.map { [$0] } ?? [])
    }

    /// Sets up LFS once attachments exist and `git lfs` is available; flags a missing install.
    private func checkAssetVersioning(using client: GitClient) async {
        guard hasAssets, !lfsEnabled else {
            if !hasAssets { lfsMissing = false }
            return
        }
        guard await client.isLFSInstalled() else {
            lfsMissing = true
            return
        }
        lfsMissing = false
        do {
            try await client.enableLFS(tracking: Attachments.folderName + "/**")
            lfsEnabled = true
        } catch {
            errorMessage = "Couldn't set up Git LFS for the attachments: \(error.localizedDescription)"
        }
    }

    /// Re-checks Git LFS (e.g. after installing it or when attachments appear) and commits attachments
    /// that were waiting for it. Checks run one at a time.
    func configureAssetVersioning() async {
        let previous = assetCheck
        let check = Task {
            await previous?.value
            guard let git, let autoCommitter else { return }
            let wasEnabled = lfsEnabled
            await checkAssetVersioning(using: git)
            autoCommitter.excludedPaths = commitExclusions
            if !wasEnabled && lfsEnabled {
                autoCommitter.markDirty()
                updatePendingState()
            }
        }
        assetCheck = check
        await check.value
    }

    private func didAddAssets() {
        if !lfsEnabled { Task { await configureAssetVersioning() } }
    }

    /// Copies or links files into the note at `path` (drops, pastes, recordings).
    func attachmentImporter(forNoteAt path: String) -> AttachmentImporter {
        attachmentImporter(forFolder: (path as NSString).deletingLastPathComponent)
    }

    /// Copies or links files for notes in the folder at `folderPath` ("" for the root).
    func attachmentImporter(forFolder folderPath: String) -> AttachmentImporter {
        AttachmentImporter(
            rootURL: rootURL, noteDirectory: url(forFolder: folderPath),
            didAddAssets: { [weak self] in self?.didAddAssets() })
    }

    /// Replaces `range` (UTF-16, full-text coordinates) in the note at `path`: as an undoable edit when the
    /// note is open in the editor, otherwise straight in the file.
    func replace(_ range: NSRange, with text: String, inNoteAt path: String) {
        if let editor, editor.path == path {
            let prefix = editor.hiddenPrefixLength
            let editorRange = NSRange(location: max(range.location - prefix, 0), length: range.length)
            if !editor.textBridge.replace(editorRange, with: text) {
                let full = editor.fullText as NSString
                editor.replaceText(full.replacingCharacters(in: Self.clamp(range, to: full.length, minimum: prefix), with: text), markSaved: false)
            }
            return
        }
        let url = rootURL.appendingPathComponent(path)
        guard SafeFileWriter.isSafeRelativePath(path), let current = RepositoryScanner.readText(url) else {
            errorMessage = "Couldn't update “\((path as NSString).lastPathComponent)”: the note is gone."
            return
        }
        let ns = current as NSString
        let updated = ns.replacingCharacters(in: Self.clamp(range, to: ns.length, minimum: 0), with: text)
        do {
            try SafeFileWriter.write(Data(updated.utf8), to: url)
        } catch {
            errorMessage = "Couldn't update “\(url.lastPathComponent)”: \(error.localizedDescription)"
            return
        }
        _ = scanSingle(path)
        refreshVisibleNotes()
        autoCommitter?.markDirty()
        updatePendingState()
    }

    func insert(_ text: String, intoNoteAt path: String, atFullTextOffset offset: Int) {
        replace(NSRange(location: offset, length: 0), with: text, inNoteAt: path)
    }

    private static func clamp(_ range: NSRange, to length: Int, minimum: Int) -> NSRange {
        let location = min(max(range.location, minimum), length)
        return NSRange(location: location, length: min(max(range.length, 0), length - location))
    }

    /// Full text of the note at `path`: the editor's when it's open, else the file's.
    func currentText(ofNoteAt path: String) -> String? {
        if let editor, editor.path == path { return editor.fullText }
        return RepositoryScanner.readText(rootURL.appendingPathComponent(path))
    }

    // MARK: Voice notes

    static let recordingLabel = "Recording voice note…"

    /// Starts recording a voice note at the open note's caret (or its end). A placeholder embed goes in as
    /// soon as recording starts; it's found again by its file name when recording ends, wherever the
    /// note moved or however it was edited meanwhile.
    func startVoiceNote() {
        showsVoiceRecorder = true
        guard let editor, !voiceRecorder.isRecording else { return }
        let path = editor.path
        let offset = (editor.textBridge.selectedLocation ?? (editor.editorText as NSString).length) + editor.hiddenPrefixLength
        let importer = attachmentImporter(forNoteAt: path)
        guard let url = importer.newAssetURL(fileName: Attachments.timestampedName(prefix: "voice", pathExtension: "m4a")) else { return }
        voiceRecorder.start(saving: url) { [weak self] event in
            guard let self else { return }
            switch event {
            case .started:
                recordingAsset = Attachments.folderName + "/" + url.lastPathComponent
                autoCommitter?.excludedPaths = commitExclusions
                let placeholder = Attachments.markdownLink(name: Self.recordingLabel, destination: importer.relativeDestination(to: url), kind: .audio)
                insert(Attachments.ownLine(placeholder, in: currentText(ofNoteAt: path) ?? "", at: offset), intoNoteAt: path, atFullTextOffset: offset)
            case .finished(let clip):
                finishRecording()
                let label = "Voice note " + Date().formatted(date: .abbreviated, time: .shortened)
                if let (notePath, ranges) = notePath(embedding: clip.lastPathComponent, preferring: path) {
                    replace(ranges.label, with: Attachments.escapeLabel(label), inNoteAt: notePath)
                } else if note(at: path) != nil || editor.path == path {
                    // The placeholder was deleted meanwhile: link the clip at the end of the note.
                    let text = currentText(ofNoteAt: path) ?? ""
                    let link = Attachments.markdownLink(name: label, destination: importer.relativeDestination(to: clip), kind: .audio)
                    insert(Attachments.ownLine(link, in: text, at: (text as NSString).length), intoNoteAt: path, atFullTextOffset: (text as NSString).length)
                }
                didAddAssets()
            case .cancelled:
                finishRecording()
                if let (notePath, ranges) = notePath(embedding: url.lastPathComponent, preferring: path),
                   let text = currentText(ofNoteAt: notePath) {
                    replace(Attachments.removalRange(of: ranges.embed, in: text), with: "", inNoteAt: notePath)
                }
            }
        }
    }

    private func finishRecording() {
        showsVoiceRecorder = false
        recordingAsset = nil
        autoCommitter?.excludedPaths = commitExclusions
        autoCommitter?.markDirty()
        updatePendingState()
    }

    /// The note embedding a file named `fileName`: the open note, then `path`, then any other note.
    private func notePath(embedding fileName: String, preferring path: String) -> (String, (embed: NSRange, label: NSRange))? {
        var candidates = [path] + notes.map(\.path).filter { $0 != path }
        if let open = editor?.path { candidates.insert(open, at: 0) }
        for candidate in candidates {
            guard let text = currentText(ofNoteAt: candidate), text.contains(fileName),
                  let ranges = Attachments.embedRanges(linkingFileNamed: fileName, in: text)
            else { continue }
            return (candidate, ranges)
        }
        return nil
    }

    // MARK: Transcripts

    /// The audio file a `+[…](source)` embed in the note at `path` points at.
    func audioURL(forSource source: String, inNoteAt path: String) -> URL? {
        Attachments.fileURL(forDestination: source, relativeTo: rootURL.appendingPathComponent(path).deletingLastPathComponent())
    }

    /// Adds `transcript` as a quote right below the line embedding `source` (or at the end).
    func insertTranscript(_ transcript: String, forSource source: String, inNoteAt path: String) {
        guard let text = currentText(ofNoteAt: path) else { return }
        let offset = Attachments.endOfLine(linking: source, in: text)
        insert(Attachments.ownLine(Attachments.quote(transcript), in: text, at: offset), intoNoteAt: path, atFullTextOffset: offset)
    }

    // MARK: Files from other apps

    /// Creates one note per file (Dock drops, Open With) embedding it: files from elsewhere are copied into
    /// `assets/`, files already in the repository are linked where they are.
    func addNotes(embedding files: [URL]) {
        let importer = attachmentImporter(forFolder: "")
        for file in files {
            guard let link = importer.markdown(forFiles: [file], mode: .copy) else { continue }
            let name = file.deletingPathExtension().lastPathComponent
            createNote(in: "", title: name, body: "# \(name)\n\n\(link)\n")
        }
    }

    /// A new note from a Services request: text and URLs become the body, files and images are attached.
    func addNote(text: String?, files: [URL], imageData: Data?) {
        let importer = attachmentImporter(forFolder: "")
        var parts: [String] = []
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(text) }
        if !files.isEmpty {
            if let links = importer.markdown(forFiles: files, mode: .copy) { parts.append(links) }
        } else if let imageData, let link = importer.markdown(forImageData: imageData) {
            parts.append(link)
        }
        guard !parts.isEmpty else { return }
        let title = files.count == 1 && text == nil ? files[0].deletingPathExtension().lastPathComponent : nil
        createNote(in: "", title: title, body: (title.map { "# \($0)\n\n" } ?? "") + parts.joined(separator: "\n\n") + "\n")
    }

    var isVersioned: Bool {
        switch gitState {
        case .starting, .disabled, .needsConsent: false
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
            try SafeFileWriter.write(Data(content.utf8), to: url)
        } catch {
            errorMessage = "Couldn't restore the note: \(error.localizedDescription)"
            return
        }
        if let editor, editor.path == path {
            editor.replaceText(content, markSaved: true)
        }
        _ = scanSingle(path)
        refreshVisibleNotes()
        if let autoCommitter {
            // Through the committer's queue so it never races a timed commit.
            await autoCommitter.flush(message: "Restore \(path) to \(revision.prefix(7))")
        }
    }

    func loadDeletedFiles() async {
        guard let git else { return }
        let files = (try? await git.deletedFiles(limit: 200)) ?? []
        deletedFiles = RecentlyDeleted.visible(files, cleared: clearedDeletions, existingPaths: Set(notesByPath.keys))
    }

    /// Hides deletions from Recently Deleted for good (on this Mac). The files stay in git history.
    func removeFromRecentlyDeleted(_ files: [GitDeletedFile]) {
        clearedDeletions.formUnion(files.map(RecentlyDeleted.key))
        let paths = Set(files.map(\.path))
        deletedFiles.removeAll { paths.contains($0.path) }
        if let selected = selectedDeletedPath, paths.contains(selected) { selectedDeletedPath = nil }
    }

    private var clearedDeletions: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "clearedDeletions:" + rootURL.path) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: "clearedDeletions:" + rootURL.path) }
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
    static let repositoryCommitted = Notification.Name("NoteMDRepositoryCommitted")
}
