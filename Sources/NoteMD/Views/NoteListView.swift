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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .contextMenu { NoteListBackgroundMenu() }
            } else {
                List(selection: $store.selectedNoteID) {
                    ForEach(store.visibleNotes) { row in
                        NoteRowView(row: row, showsFolder: showsFolders)
                            .tag(row.id)
                            .draggable(SidebarDrop.notePayload(row.id))
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: String.self) { paths in
                    if let path = paths.first { NoteContextMenu(path: path) }
                }
                .listBackgroundContextMenu { NoteListBackgroundMenu().environment(store) }
                .onDeleteCommand {
                    if let path = store.selectedNoteID { store.trashNote(path) }
                }
            }
        }
        .confirmationDialog(
            "Delete “\(store.incognitoNotePendingDelete.flatMap { store.note(at: $0)?.title } ?? "")”?",
            isPresented: Binding(get: { store.incognitoNotePendingDelete != nil }, set: { if !$0 { store.incognitoNotePendingDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let path = store.incognitoNotePendingDelete { store.deleteIncognitoNote(path) }
                store.incognitoNotePendingDelete = nil
            }
        } message: {
            Text("Incognito notes aren't versioned or moved to the Bin. This can't be undone.")
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
        return store.sidebarSelection != .incognito
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
                Button("New Template") { store.createTemplate() }
            }
        } else if store.sidebarSelection == .incognito {
            ContentUnavailableView {
                Label("No Incognito Notes", systemImage: "eye.slash")
            } description: {
                Text("Incognito notes are never versioned and are deleted when this window closes. Move one into a folder to keep it.")
            } actions: {
                Button("New Incognito Note") { store.createIncognitoNote() }
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
}

/// The menu for empty space in the note list: the actions of the current sidebar view.
struct NoteListBackgroundMenu: View {
    @Environment(RepositoryStore.self) private var store
    private let settings = AppSettings.shared

    var body: some View {
        switch store.sidebarSelection {
        case .folder(let path):
            Button("New Note") { store.createNote(in: path) }
            Button("New Folder Inside…") { store.beginCreateFolder(in: path) }
            Divider()
            Button("Edit Folder…") { store.beginEditFolder(path) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.url(forFolder: path)]) }
            Divider()
            sortPicker
            Toggle("Include Subfolders", isOn: Bindable(settings).includeSubfolders)
        case .tag:
            Button("New Note") { store.createNote() }  // tagged with the selected tag
            Divider()
            sortPicker
        case .templates:
            Button("New Template") { store.createTemplate() }
            Divider()
            sortPicker
        case .incognito:
            Button("New Incognito Note") { store.createIncognitoNote() }
            Divider()
            sortPicker
        case .recentlyDeleted, .assets:
            EmptyView()
        case .allNotes, .none:
            Button("New Note") { store.createNote() }
            NewNoteFromTemplateMenu()
            Divider()
            sortPicker
        }
    }

    private var sortPicker: some View {
        Picker("Sort By", selection: Bindable(settings).sortOrder) {
            ForEach(NoteSortOrder.allCases) { Text($0.title).tag($0) }
        }
    }
}

/// Lists the templates; each opens its fill form, whose Save as Note… creates the note.
struct NewNoteFromTemplateMenu: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        let templates = store.templatesByTitle
        Menu("New Note from Template") {
            ForEach(templates) { note in
                Button(note.title.contains("{{") ? (note.path as NSString).lastPathComponent : note.title) {
                    store.selectedNoteID = note.id
                    store.sheet = .templateForm(path: note.id)
                }
            }
        }
        .disabled(templates.isEmpty)
    }
}

struct NoteRowView: View {
    @Environment(RepositoryStore.self) private var store
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
                Spacer(minLength: 0)
                attachmentsButton(for: note)
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

    /// A paperclip when the note links files, with a warning when a link is broken; opens the attachments popover.
    @ViewBuilder private func attachmentsButton(for note: Note) -> some View {
        let attachments = store.attachments(ofNoteAt: note.path)
        if !attachments.isEmpty {
            let broken = attachments.filter { $0.status == .missing }.count
            Button {
                store.attachmentsPopoverNote = note.path
            } label: {
                HStack(spacing: 1) {
                    Image(systemName: "paperclip")
                    if broken > 0 {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(broken > 0 ? "\(attachments.count) attachments, \(broken) missing" : (attachments.count == 1 ? "1 attachment" : "\(attachments.count) attachments"))
            .accessibilityLabel(broken > 0 ? "Attachments, \(broken) missing" : "Attachments")
            .popover(isPresented: Binding(
                get: { store.attachmentsPopoverNote == note.path },
                set: { if !$0, store.attachmentsPopoverNote == note.path { store.attachmentsPopoverNote = nil } }
            ), arrowEdge: .trailing) {
                AttachmentsPopover(notePath: note.path).environment(store)
            }
        }
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
        let isIncognito = RepositoryLayout.isIncognitoPath(path)
        Button("Rename…") { store.sheet = .renameNote(path: path) }
        Button("Duplicate") { store.duplicateNote(path) }
        // Moving an incognito note into the notes keeps it (versioned from then on).
        Menu(isIncognito ? "Keep In" : "Move To") {
            Button("Notes (top level)") { store.moveNote(path, toFolder: "") }
            ForEach(store.root.descendants) { folder in
                Button(folder.path) { store.moveNote(path, toFolder: folder.path) }
            }
        }
        Divider()
        if store.isVersioned && !isIncognito {
            Button("Version History…") { store.selectedNoteID = path; store.sheet = .history(path: path) }
        }
        Button("Show in Finder") { store.reveal(path) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(store.fileURL(for: path).path, forType: .string)
        }
        Divider()
        Button(isIncognito ? "Delete…" : "Move to Trash", role: .destructive) { store.trashNote(path) }
    }
}

private struct DeletedNotesList: View {
    @Environment(RepositoryStore.self) private var store
    @State private var confirmEmpty = false

    var body: some View {
        @Bindable var store = store
        if store.deletedFiles.isEmpty {
            ContentUnavailableView("No Deleted Notes", systemImage: "trash", description: Text("Notes and attachments you delete can be restored here from their history."))
        } else {
            List(selection: $store.selectedDeletedPath) {
                ForEach(store.deletedFiles) { file in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(RecentlyDeleted.isAsset(file.path) ? (file.path as NSString).lastPathComponent : ((file.path as NSString).lastPathComponent as NSString).deletingPathExtension)
                            .font(.body.weight(.semibold))
                        Text(file.path).font(.caption).foregroundStyle(.secondary)
                        Text("Deleted \(file.deletedIn.date, format: .relative(presentation: .named))")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                    .tag(file.path)
                }
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: String.self) { paths in
                let files = store.deletedFiles.filter { paths.contains($0.path) }
                if !files.isEmpty {
                    Button("Restore") { Task { for file in files { await store.restoreDeleted(file) } } }
                    Button("Remove from List") { store.removeFromRecentlyDeleted(files) }
                }
            }
            .listBackgroundContextMenu {
                Button("Empty Recently Deleted…") { confirmEmpty = true }
            }
            .confirmationDialog("Empty Recently Deleted?", isPresented: $confirmEmpty) {
                Button("Empty Recently Deleted", role: .destructive) { store.removeFromRecentlyDeleted(store.deletedFiles) }
            } message: {
                Text("This only clears the list. The notes stay in the repository's git history, so they can still be recovered with git.")
            }
        }
    }
}
