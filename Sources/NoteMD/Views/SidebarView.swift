import NoteMDCore
import SwiftUI

struct SidebarView: View {
    @Environment(RepositoryStore.self) private var store
    @State private var confirmEmptyDeleted = false

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            List(selection: $store.sidebarSelection) {
                Section {
                    Label("All Notes", systemImage: "note.text")
                        .badge(store.notes.count)
                        .tag(SidebarItem.allNotes)
                        .dropDestination(for: String.self) { items, _ in _ = drop(items, into: "") }
                        .contextMenu {
                            Button("New Note") { store.sidebarSelection = .allNotes; store.createNote() }
                            NewNoteFromTemplateMenu()
                        }
                    Label("Templates", systemImage: "wand.and.stars")
                        .badge(store.notes.filter(\.isTemplate).count)
                        .tag(SidebarItem.templates)
                        .contextMenu {
                            Button("New Template") { store.createTemplate() }
                        }
                    Label("Incognito", systemImage: "eye.slash")
                        .badge(store.incognitoNotes.count)
                        .tag(SidebarItem.incognito)
                        .help("Notes that are never versioned and are deleted when this window closes")
                        .contextMenu {
                            Button("New Incognito Note") { store.createIncognitoNote() }
                        }
                    if !store.assetFiles.isEmpty || !store.assetIndex.referencedPaths.isEmpty {
                        Label("Assets", systemImage: "paperclip")
                            .badge(store.assetFiles.count)
                            .tag(SidebarItem.assets)
                    }
                    if store.isVersioned {
                        Label("Recently Deleted", systemImage: "trash")
                            .tag(SidebarItem.recentlyDeleted)
                            .contextMenu {
                                Button("Empty Recently Deleted…") { confirmEmptyDeleted = true }
                            }
                    }
                }

                Section {
                    OutlineGroup(store.root.children, children: \.outlineChildren) { folder in
                        FolderRow(folder: folder)
                    }
                } header: {
                    HStack {
                        Text("Folders")
                        Spacer()
                        Button {
                            store.beginCreateFolder(in: "")
                        } label: {
                            Image(systemName: "plus").contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("New Folder")
                        .accessibilityLabel("New Folder")
                    }
                }

                if !store.tags.isEmpty {
                    Section("Tags") {
                        ForEach(store.tags) { tag in
                            Label(tag.tag, systemImage: "number")
                                .badge(tag.count)
                                .tag(SidebarItem.tag(tag.tag))
                                .contextMenu {
                                    // In the tag's view, new notes get the tag (and stay visible).
                                    Button("New Note Tagged #\(tag.tag)") { store.sidebarSelection = .tag(tag.tag); store.createNote() }
                                }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .confirmationDialog("Empty Recently Deleted?", isPresented: $confirmEmptyDeleted) {
                Button("Empty Recently Deleted", role: .destructive) { Task { await store.emptyRecentlyDeleted() } }
            } message: {
                Text("This only clears the list. The notes stay in the repository's git history, so they can still be recovered with git.")
            }

            SidebarFooter()
        }
    }

    private func drop(_ items: [String], into folder: String) -> Bool {
        SidebarDrop.perform(items, into: folder, store: store)
    }
}

/// Drag payloads between the note list and sidebar. A per-launch token keeps text dragged
/// from other apps from being treated as a move request; the store also validates paths.
enum SidebarDrop {
    private static let token = UUID().uuidString
    private static var notePrefix: String { "notemd:\(token):note:" }
    private static var folderPrefix: String { "notemd:\(token):folder:" }

    static func notePayload(_ path: String) -> String { notePrefix + path }
    static func folderPayload(_ path: String) -> String { folderPrefix + path }

    @MainActor static func perform(_ items: [String], into folder: String, store: RepositoryStore) -> Bool {
        var handled = false
        for item in items {
            if item.hasPrefix(notePrefix) {
                store.moveNote(String(item.dropFirst(notePrefix.count)), toFolder: folder)
                handled = true
            } else if item.hasPrefix(folderPrefix) {
                store.moveFolder(String(item.dropFirst(folderPrefix.count)), into: folder)
                handled = true
            }
        }
        return handled
    }
}

private struct FolderRow: View {
    @Environment(RepositoryStore.self) private var store
    let folder: Folder

    var body: some View {
        Label {
            Text(folder.name)
        } icon: {
            FolderIcon(appearance: folder.appearance)
        }
        .badge(folder.totalNoteCount)
        .tag(SidebarItem.folder(folder.path))
        .draggable(SidebarDrop.folderPayload(folder.path))
        .dropDestination(for: String.self) { items, _ in
            _ = SidebarDrop.perform(items, into: folder.path, store: store)
        }
        .contextMenu {
            Button("New Note") { store.createNote(in: folder.path) }
            Button("New Folder Inside…") { store.beginCreateFolder(in: folder.path) }
            Divider()
            Button("Edit Folder…") { store.beginEditFolder(folder.path) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.url(forFolder: folder.path)]) }
            Divider()
            Button("Move to Trash", role: .destructive) { store.trashFolder(folder.path) }
        }
    }
}

/// Repository switcher and versioning status.
private struct SidebarFooter: View {
    @Environment(RepositoryStore.self) private var store
    private let settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Menu {
                Section("Recent") {
                    ForEach(settings.recentRepositories, id: \.self) { path in
                        Button {
                            WindowManager.shared.switchRepository(of: store, to: PathDisplay.expand(path))
                        } label: {
                            Text((path as NSString).lastPathComponent)
                            Text(path)
                        }
                        .disabled(path == store.displayPath)
                    }
                }
                Divider()
                Button("Open Notes Folder…") { WindowManager.shared.chooseRepository(replacing: store) }
                Button("New Notes Folder…") { WindowManager.shared.createRepository(replacing: store) }
                Button("Open in New Window…") { WindowManager.shared.chooseRepository(replacing: nil) }
                Divider()
                Button("Edit Repository Appearance…") { store.beginEditFolder("") }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.rootURL]) }
            } label: {
                HStack(spacing: 8) {
                    FolderTile(appearance: store.root.appearance.isDefault ? FolderAppearance(icon: "books.vertical.fill", color: .teal) : store.root.appearance, size: 22)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(store.name).font(.callout.weight(.semibold)).lineLimit(1)
                        Text(store.displayPath).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("Switch notes folder")

            GitStatusLine()
            if store.lfsMissing {
                LFSWarning()
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }
}

private struct GitStatusLine: View {
    @Environment(RepositoryStore.self) private var store
    @State private var confirmEnable = false

    var body: some View {
        HStack(spacing: 6) {
            switch store.gitState {
            case .starting:
                ProgressView().controlSize(.mini)
                Text("Preparing history…")
            case .disabled(let reason):
                Image(systemName: "clock.badge.xmark").foregroundStyle(.secondary)
                Text("History off").help(reason)
            case .needsConsent(let reason):
                Image(systemName: "clock.badge.questionmark").foregroundStyle(.orange)
                Text("History off").help(reason)
                Spacer(minLength: 4)
                Button("Turn On…") { confirmEnable = true }
                    .buttonStyle(.link)
                    .confirmationDialog("Version everything in “\(store.name)” with git?", isPresented: $confirmEnable) {
                        Button("Turn On History") { Task { await store.enableVersioning() } }
                    } message: {
                        Text(reason + " Files matching .gitignore are skipped.")
                    }
            case .clean(let date):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                if let date {
                    Text("Versioned \(date, format: .relative(presentation: .named))")
                } else {
                    Text("All changes versioned")
                }
            case .pending:
                Image(systemName: "circle.dotted").foregroundStyle(.orange)
                Text("Changes pending")
                Spacer(minLength: 4)
                Button("Commit Now") { Task { await store.saveVersionNow() } }
                    .buttonStyle(.link)
                    .help("Save a version now (⌘S)")
            case .committing:
                ProgressView().controlSize(.mini)
                Text("Saving version…")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text("Versioning failed").help(message)
                Spacer(minLength: 4)
                Button("Retry") { Task { await store.saveVersionNow() } }.buttonStyle(.link)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// Attachments wait outside git history until Git LFS is installed (decision-5).
private struct LFSWarning: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text("Assets not versioned")
                Spacer(minLength: 4)
                Button("Check Again") { Task { await store.configureAssetVersioning() } }
                    .buttonStyle(.link)
            }
            Text("Install Git LFS: brew install git-lfs")
                .textSelection(.enabled)
                .padding(.leading, 20)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .help("Files in the assets folder are only versioned with Git LFS. Install it, then click Check Again.")
    }
}
