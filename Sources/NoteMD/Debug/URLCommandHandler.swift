import AVFoundation
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
        case "ui/settings":
            // Same path as the app menu's Settings… item.
            if let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.keyEquivalent == "," }), let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item)
            }
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
            case "transcribe": store.sheet = .transcribe(path: path, source: query["src"] ?? "")
            case "recorder": store.showsVoiceRecorder = true
            case "history": store.sheet = .history(path: path)
            case "form": store.sheet = .templateForm(path: path)
            case "params": store.sheet = .templateParameters(path: path)
            case "guide": store.showsTemplateGuide = true
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
        case "ui/editor-command":
            // Runs a text command in the first editor of the repository (or document) window.
            let windowsToSearch: [NSWindow] = query["target"] == "document"
                ? NSDocumentController.shared.documents.flatMap { $0.windowControllers.compactMap(\.window) }
                : (store.flatMap { s in windows.controllers.first { $0.store === s }?.window }.map { [$0] } ?? [])
            guard let textView = windowsToSearch.lazy.compactMap({ $0.contentView.flatMap(findTextView) }).first else { return }
            switch query["select"] {
            case "all": textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
            case "end": textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            default: break
            }
            switch query["name"] {
            case "tab": textView.insertTab(nil)
            case "backtab": textView.insertBacktab(nil)
            case "newline": textView.insertNewline(nil)
            case "text": textView.insertText(query["text"] ?? "", replacementRange: textView.selectedRange())
            default: break
            }
        case "ui/attachment-mode":
            if let mode = AttachmentImportMode(rawValue: query["value"] ?? "") { AppSettings.shared.attachmentImportMode = mode }
        case "ui/drop-files", "ui/paste-file", "ui/paste-image":
            // Same entry points as a real drop or ⌘V, without touching the user's pasteboard.
            guard let textView = editorTextView(query) else { return }
            let paths = (query["paths"] ?? query["path"] ?? "").split(separator: ",").map(String.init)
            let urls = paths.compactMap { safePath($0) }.map { URL(fileURLWithPath: $0) }
            guard urls.count == paths.count, !urls.isEmpty else { return }
            if query["select"] == "end" { textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0)) }
            switch verb {
            case "ui/paste-image": if let data = try? Data(contentsOf: urls[0]) { textView.pasteImageData(data) }
            case "ui/paste-file": textView.insertAttachments([urls[0]], at: textView.selectedRange())
            default: textView.insertAttachments(urls, at: textView.selectedRange())
            }
        case "ui/voice-start":
            // The recorder's real start/stop path, with the microphone replaced by a clip copied from
            // `from` or a generated tone of `seconds`.
            let source = query["from"].flatMap { safePath($0) }.map { URL(fileURLWithPath: $0) }
            let recorder = query["target"] == "document" ? debugDocument?.model.voiceRecorder : store?.voiceRecorder
            recorder?.simulatedClip = { url in makeClip(at: url, from: source, query: query) }
            if query["target"] == "document" { debugDocument?.model.startVoiceNote() } else { store?.startVoiceNote() }
        case "ui/voice-stop", "ui/voice-cancel":
            let recorder = query["target"] == "document" ? debugDocument?.model.voiceRecorder : store?.voiceRecorder
            if verb == "ui/voice-stop" { recorder?.stop() } else { recorder?.cancel() }
        case "ui/transcribe":
            guard let store, let editor = store.editor, let source = query["src"],
                  let audio = store.audioURL(forSource: source, inNoteAt: editor.path)
            else { return }
            let path = editor.path
            let locale = Locale(identifier: query["lang"] ?? "en-US")
            Task {
                do {
                    let text = try await Transcriber.transcribe(audio, locale: locale)
                    store.insertTranscript(text, forSource: source, inNoteAt: path)
                } catch {
                    store.errorMessage = "transcribe: \(error.localizedDescription)"
                }
            }
        case "ui/service-note":
            // A private pasteboard stands in for the Services selection.
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("NoteMDTestServices"))
            pasteboard.clearContents()
            if let text = query["text"] { pasteboard.setString(text, forType: .string) }
            if let file = query["file"].flatMap({ safePath($0) }) { pasteboard.writeObjects([URL(fileURLWithPath: file) as NSURL]) }
            windows.addNoteFromService(pasteboard)
        case "ui/lfs-check":
            if let store { Task { await store.configureAssetVersioning() } }
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

    private static var debugDocument: TextFileDocument? {
        NSDocumentController.shared.documents.first as? TextFileDocument
    }

    /// The editor of the repository window, or of the first document with `target=document`.
    private static func editorTextView(_ query: [String: String]) -> MarkdownTextView? {
        let windowsToSearch: [NSWindow] = query["target"] == "document"
            ? NSDocumentController.shared.documents.flatMap { $0.windowControllers.compactMap(\.window) }
            : (store.flatMap { s in windows.controllers.first { $0.store === s }?.window }.map { [$0] } ?? [])
        return windowsToSearch.lazy.compactMap { $0.contentView.flatMap(findTextView) }.first
    }

    /// Copies `source` to `url`, or writes a short 440 Hz tone (`seconds`, default 1).
    private static func makeClip(at url: URL, from source: URL?, query: [String: String]) -> Bool {
        if let source { return (try? FileManager.default.copyItem(at: source, to: url)) != nil }
        let seconds = Double(query["seconds"] ?? "") ?? 1
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 44_100)),
              let samples = buffer.floatChannelData?[0]
        else { return false }
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) { samples[index] = 0.3 * sin(2 * .pi * 440 * Float(index) / 44_100) }
        do {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1]
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
            return true
        } catch {
            return false
        }
    }

    private static func findTextView(in view: NSView) -> MarkdownTextView? {
        if let textView = view as? MarkdownTextView { return textView }
        for subview in view.subviews {
            if let found = findTextView(in: subview) { return found }
        }
        return nil
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
            lines.append("lfsMissing: \(store.lfsMissing)")
            lines.append("recording: \(store.voiceRecorder.isRecording)")
            lines.append("error: \(store.errorMessage ?? "-")")
            if let editor = store.editor {
                lines.append("editor.path: \(editor.path)")
                lines.append("editor.title: \(editor.title)")
                lines.append("editor.dirty: \(editor.isDirty)")
                lines.append("editor.tags: \(editor.tags)")
                lines.append("editor.params: \(editor.parameters.map { "\($0.name):\($0.type.rawValue)" })")
                lines.append("editor.text: \(editor.fullText.prefix(4000).debugDescription)")
            }
        }
        if let document = NSDocumentController.shared.documents.first as? TextFileDocument {
            lines.append("document.text: \(document.model.text.prefix(4000).debugDescription)")
        }
        lines.append("attachmentMode: \(AppSettings.shared.attachmentImportMode.rawValue)")
        lines.append("mode: \(AppSettings.shared.editorMode.rawValue)")
        return lines.joined(separator: "\n") + "\n"
    }
}
#endif
