import NoteMDCore
import QuickLook
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// The middle column for the sidebar's Assets item: the files in `assets/` and the links to files that are gone.
struct AssetsListView: View {
    @Environment(RepositoryStore.self) private var store
    @State private var quickLookURL: URL?

    var body: some View {
        @Bindable var store = store
        let rows = store.assetRows(store.assetFilter)
        Group {
            if rows.isEmpty {
                emptyState
            } else {
                List(selection: $store.selectedAssetPath) {
                    ForEach(rows) { row in
                        AssetRowView(row: row).tag(row.path)
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: String.self) { paths in
                    if let row = rows.first(where: { paths.contains($0.path) }) {
                        AssetActions(row: row, quickLook: { quickLookURL = $0 })
                    }
                }
            }
        }
        .navigationTitle("Assets")
        .toolbar {
            ToolbarItemGroup {
                Picker("Show", selection: $store.assetFilter) {
                    ForEach(AssetFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Show all assets, the ones no note uses, or links to files that are gone")
                let unused = store.assetRows(.unused)
                Button {
                    store.assetsPendingTrash = unused.map(\.path)
                } label: {
                    Label("Clean Up Unused…", systemImage: "trash")
                }
                .disabled(unused.isEmpty)
                .help("Move every asset no note uses to the Bin")
            }
        }
        .quickLookPreview($quickLookURL)
    }

    @ViewBuilder private var emptyState: some View {
        switch store.assetFilter {
        case .all:
            ContentUnavailableView("No Assets", systemImage: "paperclip", description: Text("Images, recordings and files you drop or paste into notes are kept in the assets folder."))
        case .unused:
            ContentUnavailableView("No Unused Assets", systemImage: "checkmark.circle", description: Text("Every asset is used by at least one note."))
        case .missing:
            ContentUnavailableView("No Missing Files", systemImage: "checkmark.circle", description: Text("Every file the notes link is there."))
        }
    }
}

struct AssetRowView: View {
    let row: AssetRow

    var body: some View {
        HStack(spacing: 10) {
            AssetThumbnail(url: row.file?.url, path: row.path, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.body.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(AssetDescription.kindAndSize(path: row.path, size: row.file?.size))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            AssetUsageLabel(row: row)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// "Used in 2 notes", "Unused" or "Missing".
struct AssetUsageLabel: View {
    let row: AssetRow

    var body: some View {
        if row.isMissing {
            Label("Missing", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        } else if row.notes.isEmpty {
            Text("Unused").font(.caption).foregroundStyle(.secondary)
        } else {
            Text(row.notes.count == 1 ? "Used in 1 note" : "Used in \(row.notes.count) notes")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Quick Look, Show in Finder, Rename… and Move to Bin… for an asset.
struct AssetActions: View {
    @Environment(RepositoryStore.self) private var store
    let row: AssetRow
    var quickLook: (URL) -> Void

    var body: some View {
        if let file = row.file {
            Button("Quick Look") { quickLook(file.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
            Divider()
            Button("Rename…") { store.sheet = .renameAsset(path: row.path) }
            Button("Move to Bin…", role: .destructive) { store.assetsPendingTrash = [row.path] }
        } else {
            ForEach(row.notes, id: \.self) { note in
                Button("Open “\(store.note(at: note)?.title ?? note)”") { store.openNote(note) }
            }
        }
    }
}

/// The detail column for the selected asset: preview, details, actions and the notes that use it.
struct AssetInspectorView: View {
    @Environment(RepositoryStore.self) private var store
    @State private var quickLookURL: URL?

    var body: some View {
        if let path = store.selectedAssetPath, let row = store.assetRows(.all).first(where: { $0.path == path }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    AssetThumbnail(url: row.file?.url, path: row.path, size: 220)
                        .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                        Text(row.path).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        if let file = row.file {
                            Text(AssetDescription.kindAndSize(path: row.path, size: file.size) + " · modified " + file.modified.formatted(date: .abbreviated, time: .shortened))
                                .font(.callout).foregroundStyle(.secondary)
                        } else {
                            Label("This file doesn't exist. Restore it, or unlink it from the notes below.", systemImage: "exclamationmark.triangle.fill")
                                .font(.callout).foregroundStyle(.orange)
                        }
                    }
                    if let file = row.file {
                        HStack {
                            Button("Quick Look") { quickLookURL = file.url }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                            Button("Rename…") { store.sheet = .renameAsset(path: row.path) }
                            Spacer()
                            Button("Move to Bin…", role: .destructive) { store.assetsPendingTrash = [row.path] }
                        }
                    }
                    usedIn(row)
                }
                .padding(24)
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .quickLookPreview($quickLookURL)
        } else {
            ContentUnavailableView("Select an Asset", systemImage: "paperclip", description: Text("See where it's used, preview it, rename it or move it to the Bin."))
        }
    }

    @ViewBuilder private func usedIn(_ row: AssetRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Used In").font(.headline)
            if row.notes.isEmpty {
                Text("No note links this file.").foregroundStyle(.secondary)
            }
            ForEach(row.notes, id: \.self) { note in
                HStack {
                    Button {
                        store.openNote(note)
                    } label: {
                        Label(store.note(at: note)?.title ?? note, systemImage: "note.text")
                    }
                    .buttonStyle(.link)
                    Spacer()
                    Button("Unlink") { store.unlinkAsset(row.path, fromNoteAt: note) }
                        .help("Remove the links to this file from the note; the file stays")
                }
            }
        }
    }
}

/// A Quick Look thumbnail of `url`, or a symbol for the file kind while it loads or when the file is gone.
struct AssetThumbnail: View {
    let url: URL?
    let path: String
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size > 60 ? 10 : 6).fill(.quaternary.opacity(0.5))
            if let image {
                Image(nsImage: image).resizable().scaledToFit().padding(size > 60 ? 6 : 2)
            } else {
                Image(systemName: url == nil ? "questionmark.square.dashed" : AssetDescription.symbol(for: path))
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            image = nil
            guard let url else { return }
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size), scale: 2, representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
    }
}

enum AssetDescription {
    static func symbol(for path: String) -> String {
        switch AttachmentKind(pathExtension: (path as NSString).pathExtension) {
        case .image: "photo"
        case .audio: "waveform"
        case .video: "film"
        case .file: "doc"
        }
    }

    static func kindAndSize(path: String, size: Int?) -> String {
        let ext = (path as NSString).pathExtension
        let kind = UTType(filenameExtension: ext)?.localizedDescription ?? (ext.isEmpty ? "File" : ext.uppercased() + " file")
        guard let size else { return kind }
        return kind + " · " + ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

/// The paperclip popover of a note-list row: the note's attachments and what can be done with each.
struct AttachmentsPopover: View {
    @Environment(RepositoryStore.self) private var store
    let notePath: String
    @State private var quickLookURL: URL?

    var body: some View {
        let attachments = store.attachments(ofNoteAt: notePath)
        VStack(alignment: .leading, spacing: 0) {
            Text(attachments.count == 1 ? "1 Attachment" : "\(attachments.count) Attachments")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(attachments, id: \.link) { attachment in
                        row(attachment)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 400)
        .frame(maxHeight: 460)
        .fixedSize(horizontal: false, vertical: true)
        .quickLookPreview($quickLookURL)
    }

    private func row(_ attachment: NoteAttachment) -> some View {
        let url = store.fileURL(for: attachment.link)
        let path = attachment.link.repositoryPath
        let others = path.map { store.assetIndex.notes(referencing: $0).filter { $0 != notePath } } ?? []
        return HStack(alignment: .top, spacing: 10) {
            AssetThumbnail(url: attachment.status == .missing ? nil : url, path: url.path, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent).font(.body.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                switch attachment.status {
                case .missing:
                    Label("Missing: the link points at a file that isn't there", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                case .external:
                    Text("Linked where it is, outside the notes folder").font(.caption).foregroundStyle(.secondary)
                case .found:
                    if others.isEmpty {
                        Text("Only used here").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Also in " + others.map { store.note(at: $0)?.title ?? $0 }.formatted(.list(type: .and)))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                Button { quickLookURL = url } label: { Image(systemName: "eye") }
                    .help("Quick Look")
                    .accessibilityLabel("Quick Look")
                    .disabled(attachment.status == .missing)
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }
                    .help("Show in Finder")
                    .accessibilityLabel("Show in Finder")
                    .disabled(attachment.status == .missing)
                if let path {
                    Button("Unlink") { store.unlinkAsset(path, fromNoteAt: notePath) }
                        .help("Remove the links to this file from the note; the file stays")
                }
            }
            .buttonStyle(.borderless)
        }
    }
}

struct RenameAssetSheet: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let path: String
    @State var name: String
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Asset").font(.headline)
            TextField("File name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(rename)
            let users = store.assetIndex.notes(referencing: path).count
            Text(users == 0 ? "No note links this file." : "The links in \(users == 1 ? "1 note" : "\(users) notes") are updated to the new name.")
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
        store.renameAsset(path, to: name)
        dismiss()
    }
}
