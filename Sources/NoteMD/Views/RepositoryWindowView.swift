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
            Group {
                if store.sidebarSelection == .assets { AssetsListView() } else { NoteListView() }
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 310, max: 480)
        } detail: {
            if store.sidebarSelection == .assets { AssetInspectorView() } else { NoteDetailView() }
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
        .confirmationDialog(trashTitle, isPresented: Binding(get: { store.assetsPendingTrash != nil }, set: { if !$0 { store.assetsPendingTrash = nil } })) {
            Button("Move to Bin", role: .destructive) {
                if let paths = store.assetsPendingTrash { store.trashAssets(paths) }
                store.assetsPendingTrash = nil
            }
        } message: {
            Text(trashMessage)
        }
        .alert(restoreTitle, isPresented: Binding(get: { store.pendingAssetRestore != nil }, set: { if !$0 { store.pendingAssetRestore = nil } })) {
            Button("Restore Attachments") {
                if let pending = store.pendingAssetRestore { Task { await store.restoreDeletedAssets(pending.files) } }
                store.pendingAssetRestore = nil
            }
            Button("Not Now", role: .cancel) { store.pendingAssetRestore = nil }
        } message: {
            Text((store.pendingAssetRestore?.files ?? []).map { ($0.path as NSString).lastPathComponent }.formatted(.list(type: .and)))
        }
        .alert("Something went wrong", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
        .frame(minWidth: 860, minHeight: 520)
    }

    private var trashTitle: String {
        let count = store.assetsPendingTrash?.count ?? 0
        return count == 1 ? "Move “\(((store.assetsPendingTrash?.first ?? "") as NSString).lastPathComponent)” to the Bin?" : "Move \(count) unused assets to the Bin?"
    }

    /// Warns that the files go to the macOS Bin and names the notes that will lose their links.
    private var trashMessage: String {
        let paths = store.assetsPendingTrash ?? []
        let users = Set(paths.flatMap { store.assetIndex.notes(referencing: $0) }).sorted().map { store.note(at: $0)?.title ?? $0 }
        let bin = paths.count == 1 ? "The file moves to the macOS Bin." : "The files move to the macOS Bin."
        guard !users.isEmpty else { return bin + " No note links " + (paths.count == 1 ? "it." : "them.") }
        return bin + " Its links are removed from " + users.formatted(.list(type: .and)) + "."
    }

    private var restoreTitle: String {
        let pending = store.pendingAssetRestore
        let title = pending.flatMap { store.note(at: $0.notePath)?.title } ?? "The note"
        let count = pending?.files.count ?? 0
        return "“\(title)” links \(count == 1 ? "an attachment" : "\(count) attachments") that \(count == 1 ? "was" : "were") deleted too. Restore \(count == 1 ? "it" : "them")?"
    }

    @ViewBuilder private func sheetContent(_ sheet: RepositorySheet) -> some View {
        switch sheet {
        case .renameAsset(let path):
            RenameAssetSheet(path: path, name: ((path as NSString).lastPathComponent as NSString).deletingPathExtension)
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
                TemplateParametersEditor(editor: editor, showsGuide: Bindable(store).showsTemplateGuide)
            } else {
                SheetUnavailable()
            }
        case .transcribe(let path, let source):
            if let audio = store.audioURL(forSource: source, inNoteAt: path) {
                TranscriptionSheet(audioURL: audio) { text in
                    store.insertTranscript(text, forSource: source, inNoteAt: path)
                }
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
