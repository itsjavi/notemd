import NoteMDCore
import SwiftUI

/// Browse a note's versions, see what changed, and restore one.
struct VersionHistoryView: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let path: String

    @State private var commits: [GitCommit] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var selection: String?
    @State private var mode = Mode.changes
    @State private var contents: [String: String] = [:]
    @State private var isRestoring = false

    private static let currentID = "current"

    enum Mode: String, CaseIterable, Identifiable {
        case changes = "Changes", restore = "Compare with Current", preview = "Preview"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                timeline
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
                detail
                    .frame(minWidth: 480, maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 960, idealWidth: 1080, minHeight: 600, idealHeight: 720)
        .task { await load() }
        .task(id: selection) { await loadContents(for: selection) }
    }

    // MARK: Timeline

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Version History").font(.title3.weight(.semibold))
                Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .padding(16)
            Divider()
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                ContentUnavailableView("History Unavailable", systemImage: "clock.badge.exclamationmark", description: Text(loadError))
            } else {
                List(selection: $selection) {
                    Section {
                        HStack(spacing: 10) {
                            Image(systemName: "pencil.circle.fill").foregroundStyle(.tint).font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Current Version").font(.body.weight(.semibold))
                                Text(store.editor?.path == path && store.editor?.isDirty == true ? "Unsaved edits" : "What's on disk now")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                        .tag(Self.currentID)
                    }
                    ForEach(groupedCommits, id: \.day) { group in
                        Section(group.title) {
                            ForEach(group.commits) { commit in
                                VersionRow(commit: commit, notePath: path).tag(commit.id)
                            }
                        }
                    }
                    if commits.isEmpty {
                        Text("No saved versions yet. Versions are saved automatically a few seconds after you stop typing.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private struct DayGroup {
        let day: Date
        let title: String
        let commits: [GitCommit]
    }

    private var groupedCommits: [DayGroup] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: commits) { calendar.startOfDay(for: $0.date) }
        return groups.keys.sorted(by: >).map { day in
            let title: String
            if calendar.isDateInToday(day) { title = "Today" }
            else if calendar.isDateInYesterday(day) { title = "Yesterday" }
            else { title = day.formatted(.dateTime.weekday(.wide).day().month(.wide).year()) }
            return DayGroup(day: day, title: title, commits: groups[day]!.sorted { $0.date > $1.date })
        }
    }

    // MARK: Detail

    private var selectedCommit: GitCommit? { commits.first { $0.id == selection } }

    @ViewBuilder private var detail: some View {
        if selection == nil || isLoading {
            ContentUnavailableView("Select a Version", systemImage: "clock", description: Text("Pick a version on the left to see what changed."))
        } else {
            VStack(spacing: 0) {
                detailHeader
                Divider()
                detailBody
            }
        }
    }

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if let commit = selectedCommit {
                    Text(commit.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year().hour().minute()))
                        .font(.headline)
                    HStack(spacing: 6) {
                        Text(commit.authorName)
                        Text("·")
                        Text(commit.shortID).font(.caption.monospaced())
                        if let original = commit.path, original != path {
                            Text("·")
                            Text("was \(original)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                } else {
                    Text("Current Version").font(.headline)
                    Text("Compare earlier versions against this one.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if selectedCommit != nil {
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var detailBody: some View {
        if let selection {
            if selection == Self.currentID {
                MarkdownPreview(markdown: currentText, baseDirectory: noteDirectory, accessRoot: store.rootURL)
            } else if let version = contents[selection] {
                switch mode {
                case .preview:
                    MarkdownPreview(markdown: version, baseDirectory: noteDirectory, accessRoot: store.rootURL)
                case .changes:
                    if let previous = previousContent(of: selection) {
                        DiffView(diff: LineDiff(old: previous, new: version), emptyMessage: "No text changes in this version (it may be a rename).", legend: ("Removed in this version", "Added in this version"))
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                case .restore:
                    DiffView(diff: LineDiff(old: currentText, new: version), emptyMessage: "This version is identical to the current one.", legend: ("Removed if you restore", "Brought back if you restore"))
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let commit = selectedCommit, let version = contents[commit.id] {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(version, forType: .string)
                } label: {
                    Label("Copy This Version", systemImage: "doc.on.doc")
                }
            }
            Spacer()
            Text("Restoring keeps every version: it saves the old text as a new version.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button {
                Task { await restore() }
            } label: {
                if isRestoring { ProgressView().controlSize(.small) } else { Text("Restore This Version") }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(selectedCommit == nil || contents[selection ?? ""] == nil || contents[selection ?? ""] == currentText || isRestoring)
        }
        .padding(16)
    }

    // MARK: Data

    private var noteDirectory: URL { store.rootURL.appendingPathComponent(path).deletingLastPathComponent() }

    private var currentText: String {
        if let editor = store.editor, editor.path == path { return editor.fullText }
        return RepositoryScanner.readText(store.rootURL.appendingPathComponent(path)) ?? ""
    }

    private func previousContent(of id: String) -> String? {
        guard let index = commits.firstIndex(where: { $0.id == id }) else { return nil }
        let olderIndex = commits.index(after: index)
        guard olderIndex < commits.endIndex else { return "" }
        return contents[commits[olderIndex].id]
    }

    private func load() async {
        guard let git = store.git else {
            loadError = "This notes folder isn't versioned."
            isLoading = false
            return
        }
        store.editor?.save()
        do {
            commits = try await git.history(for: path)
            selection = commits.first?.id ?? Self.currentID
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func loadContents(for id: String?) async {
        guard let id, id != Self.currentID, let git = store.git, let index = commits.firstIndex(where: { $0.id == id }) else { return }
        var needed = [commits[index]]
        if index + 1 < commits.count { needed.append(commits[index + 1]) }
        for commit in needed where contents[commit.id] == nil {
            let filePath = commit.path ?? path
            let text = (try? await git.content(of: filePath, at: commit.id)) ?? ""
            contents[commit.id] = text
        }
    }

    private func restore() async {
        guard let commit = selectedCommit, let version = contents[commit.id] else { return }
        isRestoring = true
        await store.restore(path: path, content: version, revision: commit.id)
        isRestoring = false
        dismiss()
    }
}

private struct VersionRow: View {
    let commit: GitCommit
    let notePath: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(commit.date, format: .dateTime.hour().minute())
                .font(.callout.monospacedDigit().weight(.medium))
                .frame(width: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(summary).lineLimit(2)
                HStack(spacing: 6) {
                    if let additions = commit.additions, additions > 0 {
                        Text("+\(additions)").foregroundStyle(.green)
                    }
                    if let deletions = commit.deletions, deletions > 0 {
                        Text("−\(deletions)").foregroundStyle(.red)
                    }
                    Text(commit.shortID).foregroundStyle(.tertiary)
                }
                .font(.caption.monospacedDigit())
            }
        }
        .padding(.vertical, 3)
    }

    /// A friendly description instead of the raw commit subject.
    private var summary: String {
        if commit.subject.hasPrefix("Restore ") { return "Restored an earlier version" }
        switch commit.changeKind {
        case .added: return "Created"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed or moved"
        case .modified: return "Edited"
        default: return commit.subject
        }
    }
}

/// A readable unified diff: line numbers, colored lines and collapsed unchanged regions.
struct DiffView: View {
    let diff: LineDiff
    let emptyMessage: String
    let legend: (removed: String, added: String)

    var body: some View {
        if diff.isEmpty {
            ContentUnavailableView("No Differences", systemImage: "equal.circle", description: Text(emptyMessage))
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Label(legend.removed + " (\(diff.deletions))", systemImage: "minus.square.fill").foregroundStyle(.red)
                    Label(legend.added + " (\(diff.additions))", systemImage: "plus.square.fill").foregroundStyle(.green)
                    Spacer()
                }
                .font(.caption)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(diff.hunks) { hunk in
                            HunkHeader(hunk: hunk)
                            ForEach(hunk.lines) { line in
                                DiffLineRow(line: line)
                            }
                        }
                    }
                    .padding(.bottom, 16)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }
}

private struct HunkHeader: View {
    let hunk: DiffHunk

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "ellipsis")
            Text(hunk.newCount > 0 ? "Lines \(hunk.newStart)–\(hunk.newStart + max(hunk.newCount, 1) - 1)" : "Near line \(hunk.newStart)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08))
    }
}

private struct DiffLineRow: View {
    let line: DiffLine

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(line.oldNumber.map(String.init) ?? "")
                .frame(width: 40, alignment: .trailing)
            Text(line.newNumber.map(String.init) ?? "")
                .frame(width: 40, alignment: .trailing)
            Text(marker)
                .frame(width: 22)
                .foregroundStyle(color)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .context ? Color.secondary : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 1.5)
        .padding(.trailing, 12)
        .background(background)
        .foregroundStyle(.tertiary)
    }

    private var marker: String {
        switch line.kind {
        case .added: "+"
        case .removed: "−"
        case .context: ""
        }
    }

    private var color: Color {
        switch line.kind {
        case .added: .green
        case .removed: .red
        case .context: .secondary
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: .green.opacity(0.13)
        case .removed: .red.opacity(0.12)
        case .context: .clear
        }
    }
}
