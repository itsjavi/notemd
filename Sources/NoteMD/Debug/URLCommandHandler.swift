import AppKit
import NoteMDCore

/// Handles the app's URL scheme. Release builds accept no verbs; DEBUG builds expose
/// test hooks that call the same model methods as the UI, restricted to temp folders.
enum URLCommandHandler {
    static func handle(_ url: URL) {
        #if DEBUG
        DebugHooks.handle(url)
        #endif
    }
}

#if DEBUG
enum DebugHooks {
    private static var windows: WindowManager { .shared }
    private static var targetRepo: String?
    private static var store: RepositoryStore? {
        if let targetRepo, let match = windows.controllers.first(where: { $0.store.rootURL.path.hasSuffix(targetRepo) }) { return match.store }
        return windows.activeStore ?? windows.controllers.last?.store
    }

    static func handle(_ url: URL) {
        // Only the agents' Test build, and only for repositories in temp folders.
        guard url.scheme == AppVariant.urlScheme, AppVariant.name == "test" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let verb = (url.host() ?? "") + url.path()
        // Optional `repo=<path suffix>` targets a specific repository window.
        targetRepo = query["repo"]
        for key in ["note", "path", "folder", "parent"] {
            if let value = query[key], !SafeFileWriter.isSafeRelativePath(value) && safePath(value) == nil { return }
        }
        if verb.hasPrefix("ui/"), let store, safePath(store.rootURL.path) == nil { return }
        switch verb {
        case "ui/open-repo":
            if let path = safePath(query["path"]) { windows.openRepository(URL(fileURLWithPath: path)) }
        case "ui/create-repo":
            if let path = safePath(query["path"]) {
                try? RepositorySeeder.createRepository(at: URL(fileURLWithPath: path))
                windows.openRepository(URL(fileURLWithPath: path))
            }
        case "ui/open-file":
            if let path = safePath(query["path"]) { windows.openFile(URL(fileURLWithPath: path)) }
        case "ui/welcome":
            windows.showWelcome()
        case "ui/sidebar":
            guard let store else { return }
            if let folder = query["folder"] { store.sidebarSelection = .folder(folder) }
            else if let tag = query["tag"] { store.sidebarSelection = .tag(tag) }
            else {
                switch query["item"] {
                case "templates": store.sidebarSelection = .templates
                case "deleted": store.sidebarSelection = .recentlyDeleted
                default: store.sidebarSelection = .allNotes
                }
            }
        case "ui/select":
            store?.selectedNoteID = query["note"]
        case "ui/select-deleted":
            store?.selectedDeletedPath = query["path"]
        case "ui/search":
            store?.searchText = query["q"] ?? ""
        case "ui/mode":
            if let mode = EditorMode(rawValue: query["value"] ?? "") { AppSettings.shared.editorMode = mode }
        case "ui/new-note":
            store?.createNote(title: query["title"], body: query["body"])
        case "ui/type":
            if let editor = store?.editor, let text = query["text"] {
                editor.replaceText(editor.fullText + text, markSaved: false)
            }
        case "ui/tags":
            if let editor = store?.editor, let tags = query["value"] {
                editor.setTags(tags.split(separator: ",").map(String.init))
            }
        case "ui/sheet":
            guard let store else { return }
            let path = query["path"] ?? store.editor?.path ?? ""
            switch query["name"] {
            case "history": store.sheet = .history(path: path)
            case "form": store.sheet = .templateForm(path: path)
            case "params": store.sheet = .templateParameters(path: path)
            case "rename": store.sheet = .renameNote(path: path)
            case "folder-new": store.beginCreateFolder(in: query["parent"] ?? "")
            case "folder-edit": store.beginEditFolder(path)
            default: break
            }
        case "ui/close-sheet":
            store?.sheet = nil
        case "ui/folder-style":
            guard let store, let path = query["path"], let folder = store.root.find(path) else { return }
            var draft = FolderDraft(mode: .edit(path: path), name: folder.name, appearance: folder.appearance)
            draft.appearance.icon = query["icon"] ?? draft.appearance.icon
            draft.appearance.color = query["color"].flatMap(FolderColor.init(rawValue:)) ?? draft.appearance.color
            store.commitFolder(draft)
        case "ui/restore":
            guard let store, let path = query["path"], let revision = query["rev"] else { return }
            Task {
                do {
                    guard let git = store.git else { store.errorMessage = "restore: no git"; return }
                    guard let content = try await git.content(of: path, at: revision) else { store.errorMessage = "restore: no content"; return }
                    await store.restore(path: path, content: content, revision: revision)
                } catch {
                    store.errorMessage = "restore: \(error)"
                }
            }
        case "ui/move":
            if let store, let note = query["note"] { store.moveNote(note, toFolder: query["folder"] ?? "") }
        case "ui/move-folder":
            if let store, let path = query["path"] { store.moveFolder(path, into: query["parent"] ?? "") }
        case "ui/rename":
            if let store, let note = query["note"], let name = query["name"] { store.renameNote(note, to: name) }
        case "ui/trash":
            if let store, let path = query["note"] { store.trashNote(path) }
        case "ui/restore-deleted":
            guard let store, let path = query["path"] else { return }
            Task {
                await store.loadDeletedFiles()
                if let file = store.deletedFiles.first(where: { $0.path == path }) { await store.restoreDeleted(file) }
            }
        case "ui/commit-now":
            if let store { Task { await store.saveVersionNow() } }
        case "ui/window-size":
            if let width = Double(query["w"] ?? ""), let height = Double(query["h"] ?? "") {
                for window in NSApp.windows where window.isVisible && window.styleMask.contains(.titled) {
                    window.setContentSize(NSSize(width: width, height: height))
                }
            }
        case "ui/appearance":
            NSApp.appearance = query["value"] == "dark" ? NSAppearance(named: .darkAqua) : (query["value"] == "light" ? NSAppearance(named: .aqua) : nil)
        case "debug/state":
            if let path = safePath(query["out"]) { try? stateDump().write(toFile: path, atomically: true, encoding: .utf8) }
        default:
            break
        }
    }

    /// Only temp locations, after resolving symlinks, so a link can't touch user files.
    private static func safePath(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let absolute = raw.hasPrefix("/") ? raw : "/" + raw
        let resolved = URL(fileURLWithPath: absolute).canonical.path
        let allowed = ["/private/tmp/", "/private/var/folders/"]
        return allowed.contains { resolved.hasPrefix($0) } ? resolved : nil
    }

    private static func stateDump() -> String {
        var lines: [String] = []
        lines.append("windows: \(NSApp.windows.filter(\.isVisible).map(\.title))")
        lines.append("keyWindow: \(NSApp.keyWindow?.title ?? "-")")
        lines.append("repositories: \(windows.controllers.map { $0.store.displayPath })")
        lines.append("documents: \(NSDocumentController.shared.documents.compactMap { $0.fileURL?.path })")
        if let store {
            lines.append("store: \(store.displayPath)")
            lines.append("loaded: \(store.isLoaded)")
            lines.append("notes: \(store.notes.count)")
            lines.append("folders: \(store.root.descendants.map { "\($0.path)[\($0.appearance.icon ?? "-"),\($0.appearance.color?.rawValue ?? "-")]" })")
            lines.append("tags: \(store.tags.map { "\($0.tag)=\($0.count)" })")
            lines.append("sidebar: \(String(describing: store.sidebarSelection))")
            lines.append("search: \(store.searchText)")
            lines.append("visible: \(store.visibleNotes.map(\.id))")
            lines.append("selected: \(store.selectedNoteID ?? "-")")
            lines.append("sheet: \(store.sheet?.id ?? "-")")
            lines.append("git: \(store.gitState)")
            lines.append("error: \(store.errorMessage ?? "-")")
            if let editor = store.editor {
                lines.append("editor.path: \(editor.path)")
                lines.append("editor.title: \(editor.title)")
                lines.append("editor.dirty: \(editor.isDirty)")
                lines.append("editor.tags: \(editor.tags)")
                lines.append("editor.params: \(editor.parameters.map { "\($0.name):\($0.type.rawValue)" })")
            }
        }
        lines.append("mode: \(AppSettings.shared.editorMode.rawValue)")
        return lines.joined(separator: "\n") + "\n"
    }
}
#endif
