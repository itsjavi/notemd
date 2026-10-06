import NoteMDCore
import SwiftUI

struct NoteListView: View {
    @Environment(RepositoryStore.self) private var store
    private let settings = AppSettings.shared

    var body: some View {
        @Bindable var store = store
        Group {
            if store.sidebarSelection == .recentlyDeleted {
                DeletedNotesList()
            } else if store.visibleNotes.isEmpty && store.isLoaded {
                emptyState
            } else {
                List(selection: $store.selectedNoteID) {
                    ForEach(store.visibleNotes) { row in
                        NoteRowView(row: row, showsFolder: showsFolders)
                            .tag(row.id)
                            .draggable(SidebarDrop.notePayload(row.id))
                            .contextMenu { NoteContextMenu(path: row.id) }
                    }
                }
                .listStyle(.inset)
                .onDeleteCommand {
                    if let path = store.selectedNoteID { store.trashNote(path) }
                }
            }
        }
        .navigationTitle(store.selectionTitle)
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Picker("Sort By", selection: Bindable(settings).sortOrder) {
                        ForEach(NoteSortOrder.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Toggle("Include Subfolders", isOn: Bindable(settings).includeSubfolders)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .onChange(of: settings.sortOrder) { store.refreshVisibleNotes() }
                .onChange(of: settings.includeSubfolders) { store.refreshVisibleNotes() }
                .help("Sort and filter notes")

                Button {
                    store.createNote()
                } label: {
                    Label("New Note", systemImage: "square.and.pencil")
                }
                .help("New Note (⌘N)")
            }
        }
    }

    private var showsFolders: Bool {
        if case .folder(let path) = store.sidebarSelection { return settings.includeSubfolders && !path.isEmpty ? true : false }
        return true
    }

    @ViewBuilder private var emptyState: some View {
        if !store.searchText.isEmpty {
            ContentUnavailableView.search(text: store.searchText)
        } else if store.sidebarSelection == .templates {
            ContentUnavailableView {
                Label("No Templates", systemImage: "wand.and.stars")
            } description: {
                Text("Turn any note into a template from its ⋯ menu, then add parameters like `{{topic}}` to fill in later.")
            } actions: {
                Button("New Template") { createTemplate() }
            }
        } else {
            ContentUnavailableView {
                Label("No Notes", systemImage: "note.text")
            } description: {
                Text("Create a note to get started.")
            } actions: {
                Button("New Note") { store.createNote() }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
    }

    private func createTemplate() {
        let body = "# New Template\n\nWrite about **{{topic}}** in a {{tone}} tone.\n"
        guard let path = store.createNote(title: "New Template", body: body) else { return }
        if let editor = store.editor, editor.path == path {
            editor.setParameters([
                TemplateParameter(name: "topic", type: .text, required: true, placeholder: "What should it be about?"),
                TemplateParameter(name: "tone", type: .choice, defaultValue: .text("friendly"), options: ["friendly", "formal", "playful"]),
            ])
        }
        store.sheet = .templateParameters(path: path)
    }
}

struct NoteRowView: View {
    let row: NoteRow
    var showsFolder: Bool

    var body: some View {
        let note = row.note
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if note.isTemplate {
                    Image(systemName: "wand.and.stars")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Template")
                }
                Text(note.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
            }
            let preview = row.snippet ?? note.excerpt
            if !preview.isEmpty {
                Text(preview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                Text(note.modified, format: .dateTime.day().month(.abbreviated).year(.twoDigits))
                    .monospacedDigit()
                if showsFolder && !note.folderPath.isEmpty {
                    Label((note.folderPath as NSString).lastPathComponent, systemImage: "folder")
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                }
                ForEach(note.tags.prefix(3), id: \.self) { tag in
                    Text("#" + tag).foregroundStyle(.tint)
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

struct NoteContextMenu: View {
    @Environment(RepositoryStore.self) private var store
    let path: String

    var body: some View {
        let note = store.note(at: path)
        if note?.isTemplate == true {
            Button("Use Template…") { store.selectedNoteID = path; store.sheet = .templateForm(path: path) }
            Divider()
        }
        Button("Rename…") { store.sheet = .renameNote(path: path) }
        Button("Duplicate") { store.duplicateNote(path) }
        Menu("Move To") {
            Button("Notes (top level)") { store.moveNote(path, toFolder: "") }
            ForEach(store.root.descendants) { folder in
                Button(folder.path) { store.moveNote(path, toFolder: folder.path) }
            }
        }
        Divider()
        if store.isVersioned {
            Button("Version History…") { store.selectedNoteID = path; store.sheet = .history(path: path) }
        }
        Button("Show in Finder") { store.reveal(path) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(store.rootURL.appendingPathComponent(path).path, forType: .string)
        }
        Divider()
        Button("Move to Trash", role: .destructive) { store.trashNote(path) }
    }
}

private struct DeletedNotesList: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        @Bindable var store = store
        if store.deletedFiles.isEmpty {
            ContentUnavailableView("No Deleted Notes", systemImage: "trash", description: Text("Notes you delete can be restored here from their history."))
        } else {
            List(selection: $store.selectedDeletedPath) {
                ForEach(store.deletedFiles) { file in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(((file.path as NSString).lastPathComponent as NSString).deletingPathExtension)
                            .font(.body.weight(.semibold))
                        Text(file.path).font(.caption).foregroundStyle(.secondary)
                        Text("Deleted \(file.deletedIn.date, format: .relative(presentation: .named))")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                    .tag(file.path)
                    .contextMenu {
                        Button("Restore") { Task { await store.restoreDeleted(file) } }
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}
