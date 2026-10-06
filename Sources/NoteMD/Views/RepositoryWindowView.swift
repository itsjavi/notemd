import NoteMDCore
import SwiftUI

struct RepositoryWindowView: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 236, max: 360)
        } content: {
            NoteListView()
                .navigationSplitViewColumnWidth(min: 250, ideal: 310, max: 480)
        } detail: {
            NoteDetailView()
        }
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search notes")
        .searchScopes($store.searchScope, activation: .onSearchPresentation) {
            Text("All Notes").tag(SearchScope.everywhere)
            if store.sidebarSelection != .allNotes {
                Text(store.selectionTitle).tag(SearchScope.selection)
            }
        }
        .navigationTitle(store.name)
        .sheet(item: $store.sheet) { sheet in
            sheetContent(sheet)
                .environment(store)
        }
        .alert("Something went wrong", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
        .frame(minWidth: 860, minHeight: 520)
    }

    @ViewBuilder private func sheetContent(_ sheet: RepositorySheet) -> some View {
        switch sheet {
        case .folder(let draft):
            FolderSheet(draft: draft)
        case .renameNote(let path):
            RenameNoteSheet(path: path, name: store.note(at: path)?.baseName ?? "")
        case .history(let path):
            VersionHistoryView(path: path)
        case .templateForm(let path):
            if let editor = store.editor, editor.path == path {
                TemplateFormView(source: .note(editor))
            } else {
                SheetUnavailable()
            }
        case .templateParameters(let path):
            if let editor = store.editor, editor.path == path {
                TemplateParametersEditor(editor: editor)
            } else {
                SheetUnavailable()
            }
        }
    }
}

/// Shown if a sheet's note closed before it appeared.
private struct SheetUnavailable: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ContentUnavailableView {
            Label("Note Not Open", systemImage: "note.text")
        } description: {
            Text("Select the note first, then try again.")
        } actions: {
            Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .frame(width: 360, height: 240)
    }
}

private struct RenameNoteSheet: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let path: String
    @State var name: String
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Note").font(.headline)
            TextField("File name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(rename)
            Text("The file name on disk. The note title comes from its first heading.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename", action: rename)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { focused = true }
    }

    private func rename() {
        store.renameNote(path, to: name)
        dismiss()
    }
}
