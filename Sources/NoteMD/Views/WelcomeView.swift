import SwiftUI

struct WelcomeView: View {
    private let settings = AppSettings.shared
    private var windows: WindowManager { .shared }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 18) {
                Spacer()
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 112, height: 112)
                    .accessibilityHidden(true)
                VStack(spacing: 4) {
                    Text("Welcome to NoteMD").font(.largeTitle.weight(.semibold))
                    Text("Markdown notes, versioned automatically.").foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    WelcomeAction(icon: "plus.rectangle.on.folder", title: "Create a Notes Folder", subtitle: "Start fresh with a few example notes") {
                        windows.createRepository(replacing: nil)
                    }
                    WelcomeAction(icon: "folder", title: "Open a Folder…", subtitle: "Use existing Markdown files as notes") {
                        windows.chooseRepository(replacing: nil)
                    }
                    WelcomeAction(icon: "doc.text", title: "Open a File…", subtitle: "Edit a single Markdown or text file") {
                        windows.showOpenPanel()
                    }
                }
                .padding(.top, 8)
                Spacer()
            }
            .padding(32)
            .frame(width: 420)

            if !settings.recentRepositories.isEmpty {
                Divider()
                List {
                    Section("Recent") {
                        ForEach(settings.recentRepositories, id: \.self) { path in
                            Button {
                                windows.openRepository(PathDisplay.expand(path))
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "books.vertical.fill").foregroundStyle(.teal)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text((path as NSString).lastPathComponent).font(.body.weight(.medium))
                                        Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Remove from Recents") { settings.forgetRecentRepository(path) }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 280)
            }
        }
        .frame(height: 460)
    }
}

private struct WelcomeAction: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Color.secondary.opacity(0.12) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .frame(width: 320)
    }
}
