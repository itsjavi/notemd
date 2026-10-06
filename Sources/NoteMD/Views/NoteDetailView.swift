import NoteMDCore
import SwiftUI

struct NoteDetailView: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        if store.sidebarSelection == .recentlyDeleted {
            DeletedNoteDetail()
        } else if let editor = store.editor {
            NoteEditorPane(editor: editor)
                .id(editor.id)
        } else {
            ContentUnavailableView {
                Label("No Note Selected", systemImage: "note.text")
            } description: {
                Text("Pick a note from the list, or create one with ⌘N.")
            }
        }
    }
}

/// Editor, preview or both for the open note, with tags and template controls above.
struct NoteEditorPane: View {
    @Environment(RepositoryStore.self) private var store
    let editor: NoteEditor
    private let settings = AppSettings.shared
    @State private var scrollLine: Int?

    var body: some View {
        VStack(spacing: 0) {
            NoteHeaderBar(editor: editor)
            Divider()
            content
        }
        .navigationSubtitle(editor.title)
        .toolbar { NoteToolbar(editor: editor) }
    }

    @ViewBuilder private var content: some View {
        switch settings.editorMode {
        case .edit:
            editorView(syncScroll: false)
        case .preview:
            preview
        case .split:
            HSplitView {
                editorView(syncScroll: true).frame(minWidth: 260, maxWidth: .infinity)
                preview.frame(minWidth: 260, maxWidth: .infinity)
            }
        }
    }

    private func editorView(syncScroll: Bool) -> some View {
        MarkdownEditor(
            text: editor.editorText,
            revision: editor.externalRevision,
            font: settings.editorFont(),
            indentation: settings.indentation,
            readableWidth: settings.readableLineWidth && settings.editorMode != .split ? 740 : 0,
            spellChecking: settings.spellChecking,
            focusOnAppear: consumeFocus(),
            onChange: { editor.editorTextChanged($0) },
            onScroll: syncScroll ? { line in
                // Body line numbers are offset by the hidden front matter.
                scrollLine = line + (editor.showsFrontMatter ? 0 : frontMatterLineCount)
            } : nil
        )
    }

    private var frontMatterLineCount: Int {
        guard let frontMatter = editor.markdown.frontMatter else { return 0 }
        return frontMatter.lineCount + 2
    }

    /// New notes put the caret in the editor once.
    private func consumeFocus() -> Bool {
        guard editor.wantsFocus else { return false }
        DispatchQueue.main.async { editor.wantsFocus = false }
        return true
    }

    private var preview: some View {
        MarkdownPreview(
            markdown: editor.fullText,
            baseDirectory: editor.url.deletingLastPathComponent(),
            accessRoot: store.rootURL,
            scrollLine: settings.editorMode == .split ? scrollLine : nil,
            onOpenNote: { url in
                let path = store.relativePath(of: url)
                if store.note(at: path) != nil { store.selectedNoteID = path }
            }
        )
    }
}

/// Tags and template controls for the open note.
private struct NoteHeaderBar: View {
    @Environment(RepositoryStore.self) private var store
    let editor: NoteEditor
    @State private var newTag = ""
    @FocusState private var tagFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "number")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                ForEach(editor.tags, id: \.self) { tag in
                    TagChip(tag: tag) {
                        editor.setTags(editor.tags.filter { $0 != tag })
                    }
                }
                TextField(editor.tags.isEmpty ? "Add tags" : "Add tag", text: $newTag)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 70, maxWidth: 160)
                    .focused($tagFieldFocused)
                    .textInputSuggestions {
                        ForEach(suggestions, id: \.self) { Text($0).textInputCompletion($0) }
                    }
                    .onSubmit(addTag)
                    .accessibilityLabel("Add tag")
                Spacer(minLength: 8)
                if editor.isTemplate {
                    TemplateBadge(editor: editor)
                }
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if let error = editor.frontMatterError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text("The front matter isn't valid YAML, so tags and parameters are ignored.")
                        .help(error)
                    Spacer()
                    if !editor.showsFrontMatter {
                        Button("Show Front Matter") {
                            AppSettings.shared.showFrontMatter = true
                            store.reopenCurrentNote()
                        }
                        .buttonStyle(.link)
                    }
                }
                .font(.caption)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
    }

    private var suggestions: [String] {
        let query = newTag.trimmingCharacters(in: .whitespaces).lowercased()
        let current = Set(editor.tags.map { $0.lowercased() })
        return store.tags.map(\.tag).filter { !current.contains($0.lowercased()) && (query.isEmpty || $0.lowercased().contains(query)) }.prefix(8).map { $0 }
    }

    private func addTag() {
        let tags = newTag.split(separator: ",").map { Tag.normalized(String($0)) }.filter { !$0.isEmpty }
        guard !tags.isEmpty else { return }
        editor.setTags(editor.tags + tags)
        newTag = ""
        tagFieldFocused = true
    }
}

private struct TagChip: View {
    let tag: String
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 3) {
            Text(tag)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0.45)
            .accessibilityLabel("Remove tag \(tag)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
        .foregroundStyle(Color.accentColor)
        .onHover { hovering = $0 }
    }
}

private struct TemplateBadge: View {
    @Environment(RepositoryStore.self) private var store
    let editor: NoteEditor

    var body: some View {
        HStack(spacing: 8) {
            Button {
                store.sheet = .templateParameters(path: editor.path)
            } label: {
                Label("\(editor.parameters.count) parameter\(editor.parameters.count == 1 ? "" : "s")", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help("Edit template parameters")
            Button {
                store.sheet = .templateForm(path: editor.path)
            } label: {
                Label("Use Template", systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.small)
            .help("Fill in the parameters and get the finished text (⌘↩)")
        }
    }
}

private struct NoteToolbar: ToolbarContent {
    @Environment(RepositoryStore.self) private var store
    let editor: NoteEditor
    private let settings = AppSettings.shared

    var body: some ToolbarContent {
        ToolbarItem {
            Picker("Mode", selection: Bindable(settings).editorMode) {
                ForEach(EditorMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Editor ⌘1 · Split ⌘2 · Preview ⌘3")
        }
        ToolbarItem {
            Button {
                store.sheet = .history(path: editor.path)
            } label: {
                Label("Version History", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
            }
            .disabled(!store.isVersioned && store.git == nil)
            .help("Browse and restore earlier versions (⌥⌘Y)")
        }
        ToolbarItem {
            Menu {
                if editor.isTemplate {
                    Button("Use Template…") { store.sheet = .templateForm(path: editor.path) }
                    Button("Edit Parameters…") { store.sheet = .templateParameters(path: editor.path) }
                } else {
                    Button("Make Template…") { store.sheet = .templateParameters(path: editor.path) }
                }
                Divider()
                Button("Rename…") { store.sheet = .renameNote(path: editor.path) }
                Button("Duplicate") { store.duplicateNote(editor.path) }
                Button("Show in Finder") { store.reveal(editor.path) }
                Button("Copy Markdown") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(editor.fullText, forType: .string)
                }
                Divider()
                Button("Move to Trash", role: .destructive) { store.trashNote(editor.path) }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .help("More actions")
        }
    }
}

private struct DeletedNoteDetail: View {
    @Environment(RepositoryStore.self) private var store
    @State private var content: String?

    var body: some View {
        if let path = store.selectedDeletedPath, let file = store.deletedFiles.first(where: { $0.path == path }) {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(path).font(.headline)
                        Text("Deleted \(file.deletedIn.date, format: .dateTime) · \(file.deletedIn.subject)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restore Note") { Task { await store.restoreDeleted(file) } }
                        .buttonStyle(.borderedProminent)
                }
                .padding(16)
                Divider()
                if let content {
                    MarkdownPreview(markdown: content, baseDirectory: store.rootURL.appendingPathComponent(path).deletingLastPathComponent(), accessRoot: store.rootURL)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .task(id: path) {
                content = nil
                content = (try? await store.git?.content(of: file.path, at: file.lastRevision)) ?? ""
            }
        } else {
            ContentUnavailableView("Select a Deleted Note", systemImage: "trash", description: Text("Preview it and restore it to its folder."))
        }
    }
}
