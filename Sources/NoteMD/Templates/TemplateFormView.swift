import AppKit
import NoteMDCore
import SwiftUI

/// Where a template comes from: a repository note or a standalone document.
enum TemplateSource {
    case note(NoteEditor)
    case document(title: String, markdown: String, fileURL: URL?)

    var markdown: MarkdownText {
        switch self {
        case .note(let editor): editor.markdown
        case .document(_, let markdown, _): MarkdownText(markdown)
        }
    }

    var title: String {
        switch self {
        case .note(let editor):
            // A heading full of placeholders reads badly; use the file name then.
            editor.title.contains("{{") ? (editor.url.lastPathComponent as NSString).deletingPathExtension : editor.title
        case .document(let title, _, _): title
        }
    }

    var storageKey: String {
        switch self {
        case .note(let editor): "templateValues:" + editor.url.path
        case .document(let title, _, let url): "templateValues:" + (url?.path ?? title)
        }
    }

    var directory: URL? {
        switch self {
        case .note(let editor): editor.url.deletingLastPathComponent()
        case .document(_, _, let url): url?.deletingLastPathComponent()
        }
    }
}

/// Fill in a template's parameters and get the rendered text to copy or save.
struct TemplateFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(RepositoryStore.self) private var store: RepositoryStore?
    let source: TemplateSource
    @State private var values: [String: TemplateValue] = [:]
    @State private var outputMode = OutputMode.text
    @State private var copied = false
    @State private var showSave = false
    @State private var showMissing = false
    @FocusState private var multilineFocus: String?

    enum OutputMode: String, CaseIterable, Identifiable {
        case text = "Text", preview = "Preview"
        var id: String { rawValue }
    }

    private var parameters: [TemplateParameter] { source.markdown.frontMatter?.parameters ?? [] }
    private var output: String {
        TemplateRenderer(parameters: parameters, values: values).render(source.markdown.body)
            .trimmingCharacters(in: .newlines) + "\n"
    }
    private var missing: [String] { TemplateValidation.missingRequired(parameters, values: values) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.orange.opacity(0.15)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.title).font(.title3.weight(.semibold)).lineLimit(1)
                    Text("Fill in the fields; the result updates as you type.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset Fields") { resetValues() }
                    .buttonStyle(.borderless)
            }
            .padding(20)
            Divider()
            HSplitView {
                fields
                    .frame(minWidth: 320, idealWidth: 380, maxWidth: 520)
                result
                    .frame(minWidth: 360, maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 900, idealWidth: 980, minHeight: 600, idealHeight: 680)
        .onAppear(perform: loadValues)
        .onChange(of: values) { saveValues() }
    }

    private var fields: some View {
        Form {
            if parameters.isEmpty {
                Text("This template has no parameters.").foregroundStyle(.secondary)
            }
            ForEach(parameters) { parameter in
                ParameterField(parameter: parameter, value: binding(for: parameter), baseDirectory: source.directory, highlightMissing: showMissing && missing.contains(parameter.name), multilineFocus: $multilineFocus)
            }
        }
        .formStyle(.grouped)
    }

    private var result: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Output", selection: $outputMode) {
                    ForEach(OutputMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Text("\(output.count) characters").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            switch outputMode {
            case .text:
                ScrollView {
                    Text(output)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(16)
                }
                .background(Color(nsColor: .textBackgroundColor))
            case .preview:
                MarkdownPreview(markdown: output, baseDirectory: source.directory ?? FileManager.default.homeDirectoryForCurrentUser, accessRoot: store?.rootURL ?? source.directory ?? FileManager.default.homeDirectoryForCurrentUser)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if showMissing && !missing.isEmpty {
                Label("Fill in: " + missing.map { name in parameters.first { $0.name == name }?.displayLabel ?? name }.joined(separator: ", "), systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .lineLimit(1)
            } else if copied {
                Label("Copied to the clipboard", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            if store != nil {
                Button("Save as Note…") {
                    guard validate() else { return }
                    showSave = true
                }
                .popover(isPresented: $showSave, arrowEdge: .top) {
                    if let store {
                        SaveAsNotePopover(defaultTitle: defaultNoteTitle, store: store) { title, folder in
                            store.createNote(in: folder, title: title, body: output)
                            dismiss()
                        }
                    }
                }
            }
            Button {
                guard validate() else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(output, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            // Return belongs to a focused multi-line field.
            .keyboardShortcut(multilineFocus == nil ? .defaultAction : KeyboardShortcut(.return, modifiers: .command))
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }

    private var defaultNoteTitle: String {
        let first = parameters.first { $0.type == .text }.flatMap { values[$0.name] }
        if case .text(let text) = first, !text.isEmpty { return "\(source.title) – \(text)" }
        return source.title
    }

    private func validate() -> Bool {
        showMissing = true
        return missing.isEmpty
    }

    private func binding(for parameter: TemplateParameter) -> Binding<TemplateValue> {
        Binding(
            get: { values[parameter.name] ?? parameter.initialValue() },
            set: { values[parameter.name] = $0 }
        )
    }

    private func resetValues() {
        values = Dictionary(uniqueKeysWithValues: parameters.map { ($0.name, $0.initialValue()) })
        showMissing = false
    }

    // MARK: Remembering the last values

    private func loadValues() {
        resetValues()
        guard let stored = UserDefaults.standard.dictionary(forKey: source.storageKey) else { return }
        for parameter in parameters {
            guard let raw = stored[parameter.name] else { continue }
            switch (parameter.type, raw) {
            case (.number, let number as Double): values[parameter.name] = .number(number)
            case (.toggle, let flag as Bool): values[parameter.name] = .bool(flag)
            case (.multichoice, let list as [String]), (.list, let list as [String]): values[parameter.name] = .list(list)
            case (.date, _): break  // dates start fresh (usually "today")
            case (_, let text as String): values[parameter.name] = .text(text)
            default: break
            }
        }
    }

    private func saveValues() {
        var stored: [String: Any] = [:]
        for (name, value) in values {
            switch value {
            case .text(let text): stored[name] = text
            case .number(let number): stored[name] = number
            case .bool(let flag): stored[name] = flag
            case .list(let list): stored[name] = list
            case .date: break
            }
        }
        UserDefaults.standard.set(stored, forKey: source.storageKey)
    }
}

/// The input control for one parameter.
private struct ParameterField: View {
    let parameter: TemplateParameter
    @Binding var value: TemplateValue
    let baseDirectory: URL?
    var highlightMissing: Bool
    var multilineFocus: FocusState<String?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            control
            if let help = parameter.help, !help.isEmpty {
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
        }
        .listRowBackground(highlightMissing ? Color.red.opacity(0.08) : nil)
    }

    private var label: some View {
        HStack(spacing: 2) {
            Text(parameter.displayLabel)
            if parameter.required {
                Text("*").foregroundStyle(.red).accessibilityLabel("required")
            }
        }
    }

    @ViewBuilder private var control: some View {
        switch parameter.type {
        case .text:
            TextField(text: text, prompt: Text(parameter.placeholder ?? "")) { label }
        case .textarea:
            VStack(alignment: .leading, spacing: 6) {
                label
                MultilineTextBox(text: text, prompt: parameter.placeholder ?? "", lines: 3...12, focus: multilineFocus, focusID: parameter.name)
            }
        case .number:
            TextField(value: Binding(get: { if case .number(let d) = value { d } else { 0 } }, set: { value = .number($0) }), format: .number) { label }
        case .toggle:
            Toggle(isOn: Binding(get: { value == .bool(true) }, set: { value = .bool($0) })) { label }
        case .choice:
            Picker(selection: text) {
                ForEach(parameter.options, id: \.self) { Text($0).tag($0) }
            } label: { label }
        case .multichoice:
            VStack(alignment: .leading, spacing: 6) {
                label
                ForEach(parameter.options, id: \.self) { option in
                    Toggle(option, isOn: Binding(
                        get: { list.contains(option) },
                        set: { on in
                            let selected = Set(list.filter { $0 != option } + (on ? [option] : []))
                            value = .list(parameter.options.filter(selected.contains))
                        }
                    ))
                    .toggleStyle(.checkbox)
                }
            }
        case .file, .folder:
            LabeledContent {
                HStack {
                    TextField("", text: text, prompt: Text(parameter.placeholder ?? (parameter.type == .file ? "/path/to/file" : "/path/to/folder")))
                        .labelsHidden()
                        .font(.callout.monospaced())
                    Button("Choose…", action: choosePath)
                }
            } label: { label }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                value = .text(url.path)
                return true
            }
        case .date:
            DatePicker(selection: Binding(get: { if case .date(let d) = value { d } else { Date() } }, set: { value = .date($0) }), displayedComponents: .date) { label }
        case .list:
            VStack(alignment: .leading, spacing: 6) {
                label
                ListTextBox(
                    items: Binding(get: { list }, set: { value = .list($0) }),
                    prompt: parameter.placeholder ?? "One item per line", lines: 3...10, focus: multilineFocus, focusID: parameter.name
                )
            }
        }
    }

    private var text: Binding<String> {
        Binding(get: { if case .text(let s) = value { s } else { "" } }, set: { value = .text($0) })
    }

    private var list: [String] {
        if case .list(let items) = value { return items.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
        return []
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = parameter.type == .file
        panel.canChooseDirectories = parameter.type == .folder
        panel.allowsMultipleSelection = false
        if case .text(let current) = value, !current.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (current as NSString).expandingTildeInPath).deletingLastPathComponent()
        } else if let baseDirectory {
            panel.directoryURL = baseDirectory
        }
        if panel.runModal() == .OK, let url = panel.url {
            value = .text(url.path)
        }
    }
}

private struct SaveAsNotePopover: View {
    @State var title: String
    let store: RepositoryStore
    let onSave: (String, String) -> Void
    @State private var folder: String

    init(defaultTitle: String, store: RepositoryStore, onSave: @escaping (String, String) -> Void) {
        _title = State(initialValue: defaultTitle)
        self.store = store
        self.onSave = onSave
        _folder = State(initialValue: store.targetFolderPath)
    }

    var body: some View {
        Form {
            TextField("Title", text: $title)
            Picker("Folder", selection: $folder) {
                Text("Notes (top level)").tag("")
                ForEach(store.root.descendants) { Text($0.path).tag($0.path) }
            }
            HStack {
                Spacer()
                Button("Save Note") { onSave(title, folder) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}
