import NoteMDCore
import SwiftUI

/// Create or edit a folder: name, icon and color with a live preview.
struct FolderSheet: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var draft: FolderDraft
    @State private var confirmDelete = false
    @FocusState private var nameFocused: Bool

    private var isCreating: Bool {
        if case .create = draft.mode { return true }
        return false
    }

    private var isRoot: Bool {
        if case .edit(let path) = draft.mode { return path.isEmpty }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                FolderTile(appearance: draft.appearance, size: 64)
                    .shadow(color: (draft.appearance.color?.color ?? .accentColor).opacity(0.35), radius: 10, y: 4)
                VStack(alignment: .leading, spacing: 4) {
                    Text(isCreating ? "New Folder" : (isRoot ? "Repository" : "Folder"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextField("Folder name", text: $draft.name)
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.semibold))
                        .focused($nameFocused)
                        .disabled(isRoot)
                        .onSubmit(save)
                }
            }
            .padding(24)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section("Color") {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 10), count: 9), alignment: .leading, spacing: 10) {
                            colorSwatch(nil)
                            ForEach(FolderColor.allCases) { colorSwatch($0) }
                        }
                    }
                    section("Icon") {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 8), count: 8), alignment: .leading, spacing: 8) {
                            ForEach(FolderIcons.all, id: \.self) { iconButton($0) }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 400)

            Divider()

            HStack {
                if !isCreating && !isRoot {
                    Button("Move to Trash…", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isCreating ? "Create" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 440)
        .fixedSize(horizontal: true, vertical: false)
        .onAppear { nameFocused = isCreating }
        .confirmationDialog("Move “\(draft.name)” and its notes to the Trash?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive) {
                if case .edit(let path) = draft.mode { store.trashFolder(path) }
                dismiss()
            }
        } message: {
            Text("You can restore the notes from the Trash or from Recently Deleted.")
        }
    }

    private func save() {
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        store.commitFolder(draft)
        dismiss()
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }

    private func colorSwatch(_ color: FolderColor?) -> some View {
        let selected = draft.appearance.color == color
        return Button {
            draft.appearance.color = color
        } label: {
            ZStack {
                Circle()
                    .fill(color?.color ?? Color.accentColor)
                    .frame(width: 22, height: 22)
                if color == nil {
                    Image(systemName: "circle.lefthalf.filled").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                }
                Circle()
                    .strokeBorder(selected ? Color.primary : .clear, lineWidth: 2)
                    .frame(width: 30, height: 30)
            }
            .frame(width: 30, height: 30)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(color?.displayName ?? "Accent color")
        .accessibilityLabel(color?.displayName ?? "Accent color")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func iconButton(_ icon: String) -> some View {
        let selected = (draft.appearance.icon ?? FolderIcons.defaultIcon) == icon
        let tint = draft.appearance.color?.color ?? .accentColor
        return Button {
            draft.appearance.icon = icon == FolderIcons.defaultIcon ? nil : icon
        } label: {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 40, height: 40)
                .foregroundStyle(selected ? .white : .primary)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selected ? AnyShapeStyle(tint) : AnyShapeStyle(.quaternary.opacity(0.6)))
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(icon)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
