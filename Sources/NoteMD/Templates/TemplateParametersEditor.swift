import NoteMDCore
import SwiftUI

extension ParameterType {
    var symbol: String {
        switch self {
        case .text: "character.cursor.ibeam"
        case .textarea: "text.alignleft"
        case .number: "number"
        case .toggle: "switch.2"
        case .choice: "filemenu.and.selection"
        case .multichoice: "checklist"
        case .file: "doc"
        case .folder: "folder"
        case .date: "calendar"
        case .list: "list.bullet"
        }
    }
}

/// Defines the parameters of a template note.
struct TemplateParametersEditor: View {
    @Environment(\.dismiss) private var dismiss
    let editor: NoteEditor
    @Binding var showsGuide: Bool
    @State private var parameters: [TemplateParameter]
    @State private var selection: TemplateParameter.ID?
    @FocusState private var multilineFocus: String?

    init(editor: NoteEditor, showsGuide: Binding<Bool>) {
        self.editor = editor
        _showsGuide = showsGuide
        let existing = editor.parameters
        _parameters = State(initialValue: existing)
        _selection = State(initialValue: existing.first?.id)
    }

    private var undefinedPlaceholders: [String] {
        let defined = Set(parameters.map(\.name))
        return TemplateRenderer.referencedNames(in: editor.markdown.body).filter { !defined.contains($0) && TemplateParameter.isValidName($0) }.sorted()
    }

    private var duplicateNames: Set<String> {
        var seen = Set<String>()
        var duplicates = Set<String>()
        for name in parameters.map(\.name) where !seen.insert(name).inserted { duplicates.insert(name) }
        return duplicates
    }

    private var isValid: Bool {
        duplicateNames.isEmpty && parameters.allSatisfy { TemplateParameter.isValidName($0.name) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                parameterList
                    .frame(width: 240)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 780, height: 560)
        .onDisappear { showsGuide = false }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "wand.and.stars")
                .font(.title2)
                .foregroundStyle(.orange)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.orange.opacity(0.15)))
            VStack(alignment: .leading, spacing: 3) {
                Text("Template Parameters").font(.title3.weight(.semibold))
                Text("Each parameter becomes a field in the Use Template form.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showsGuide.toggle()
            } label: {
                Label("Syntax Guide", systemImage: "curlybraces")
            }
            .popover(isPresented: $showsGuide, arrowEdge: .bottom) {
                TemplateGuideView()
            }
            .help("How to write placeholders, conditions and loops")
        }
        .padding(20)
    }

    private var parameterList: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(parameters) { parameter in
                    HStack(spacing: 8) {
                        Image(systemName: parameter.type.symbol)
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(parameter.name.isEmpty ? "unnamed" : parameter.name)
                                .font(.body.monospaced())
                                .foregroundStyle(TemplateParameter.isValidName(parameter.name) && !duplicateNames.contains(parameter.name) ? Color.primary : Color.red)
                            Text(parameter.type.displayName + (parameter.required ? " · Required" : ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(parameter.id)
                }
                .onMove { parameters.move(fromOffsets: $0, toOffset: $1) }

                if !undefinedPlaceholders.isEmpty {
                    Section("Found in the note") {
                        ForEach(undefinedPlaceholders, id: \.self) { name in
                            Button {
                                add(TemplateParameter(name: name))
                            } label: {
                                Label("Add \(name)", systemImage: "plus.circle")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tint)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if parameters.isEmpty && undefinedPlaceholders.isEmpty {
                    Text("No parameters yet")
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack(spacing: 4) {
                Menu {
                    ForEach(ParameterType.allCases) { type in
                        Button {
                            add(TemplateParameter(name: uniqueName(), type: type))
                        } label: {
                            Label(type.displayName, systemImage: type.symbol)
                        }
                    }
                } label: {
                    Label("Add Parameter", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                Button {
                    guard let selection, let index = parameters.firstIndex(where: { $0.id == selection }) else { return }
                    parameters.remove(at: index)
                    self.selection = parameters.indices.contains(index) ? parameters[index].id : parameters.last?.id
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(selection == nil)
                .help("Remove parameter")
                .accessibilityLabel("Remove parameter")
            }
            .padding(8)
        }
    }

    @ViewBuilder private var detail: some View {
        if let selection, let index = parameters.firstIndex(where: { $0.id == selection }) {
            ParameterForm(parameter: $parameters[index], isDuplicate: duplicateNames.contains(parameters[index].name), multilineFocus: $multilineFocus)
                .id(selection)
        } else {
            ContentUnavailableView("No Parameter Selected", systemImage: "slider.horizontal.3", description: Text("Add a parameter for each value the template asks for."))
        }
    }

    private var footer: some View {
        HStack {
            if editor.isTemplate {
                Button("Stop Using as Template", role: .destructive) {
                    editor.setParameters([])
                    dismiss()
                }
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") {
                editor.setParameters(parameters)
                dismiss()
            }
            // Return belongs to a focused multi-line field.
            .keyboardShortcut(multilineFocus == nil ? .defaultAction : KeyboardShortcut(.return, modifiers: .command))
            .buttonStyle(.borderedProminent)
            .disabled(!isValid)
        }
        .padding(16)
    }

    private func add(_ parameter: TemplateParameter) {
        parameters.append(parameter)
        selection = parameter.id
    }

    private func uniqueName() -> String {
        var index = parameters.count + 1
        while parameters.contains(where: { $0.name == "field\(index)" }) { index += 1 }
        return "field\(index)"
    }
}

private struct ParameterForm: View {
    @Binding var parameter: TemplateParameter
    var isDuplicate: Bool
    var multilineFocus: FocusState<String?>.Binding
    @State private var newOption = ""

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $parameter.name, prompt: Text("snake_case"))
                    .font(.body.monospaced())
                if !TemplateParameter.isValidName(parameter.name) {
                    Text("Use letters, numbers, _ or -, starting with a letter.").font(.caption).foregroundStyle(.red)
                } else if isDuplicate {
                    Text("Another parameter already uses this name.").font(.caption).foregroundStyle(.red)
                } else {
                    LabeledContent("Use in note") {
                        Text("{{\(parameter.name)}}").font(.body.monospaced()).textSelection(.enabled)
                    }
                }
                TextField("Label", text: optional(\.label), prompt: Text(TemplateParameter.humanize(parameter.name)))
                Picker("Type", selection: $parameter.type) {
                    ForEach(ParameterType.allCases) { type in
                        Label(type.displayName, systemImage: type.symbol).tag(type)
                    }
                }
                .onChange(of: parameter.type) { _, _ in parameter.defaultValue = nil }
                Toggle("Required", isOn: $parameter.required)
            }

            Section("Guidance") {
                TextField("Help", text: optional(\.help), prompt: Text("Shown under the field"), axis: .vertical)
                    .lineLimit(1...3)
                if [.text, .textarea, .number, .file, .folder, .list].contains(parameter.type) {
                    TextField("Placeholder", text: optional(\.placeholder), prompt: Text("Example value"))
                }
            }

            if parameter.type.usesOptions {
                Section("Options") {
                    ForEach(Array(parameter.options.enumerated()), id: \.offset) { index, _ in
                        HStack {
                            TextField("Option", text: Binding(get: { parameter.options[safe: index] ?? "" }, set: { parameter.options[index] = $0 }))
                                .labelsHidden()
                            Button {
                                parameter.options.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove option")
                        }
                    }
                    HStack {
                        TextField("New option", text: $newOption)
                            .labelsHidden()
                            .onSubmit(addOption)
                        Button("Add", action: addOption).disabled(newOption.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }

            if parameter.type == .date {
                Section("Format") {
                    TextField("Date format", text: optional(\.format), prompt: Text("yyyy-MM-dd"))
                        .font(.body.monospaced())
                    Text("Unicode date pattern, e.g. `d MMMM yyyy` or `EEEE`.").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Default") {
                DefaultValueEditor(parameter: $parameter, multilineFocus: multilineFocus)
            }
        }
        .formStyle(.grouped)
    }

    private func addOption() {
        let value = newOption.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !parameter.options.contains(value) else { return }
        parameter.options.append(value)
        newOption = ""
    }

    private func optional(_ keyPath: WritableKeyPath<TemplateParameter, String?>) -> Binding<String> {
        Binding(
            get: { parameter[keyPath: keyPath] ?? "" },
            set: { parameter[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }
}

/// Edits a parameter's default value with the control matching its type.
private struct DefaultValueEditor: View {
    @Binding var parameter: TemplateParameter
    var multilineFocus: FocusState<String?>.Binding

    var body: some View {
        switch parameter.type {
        case .text, .file, .folder:
            TextField("Default", text: textBinding, prompt: Text("None"))
        case .textarea:
            MultilineTextBox(text: textBinding, prompt: "None", lines: 2...6, focus: multilineFocus, focusID: "default")
        case .number:
            TextField("Default", value: Binding(
                get: { if case .number(let d) = parameter.defaultValue { d } else { nil } },
                set: { parameter.defaultValue = $0.map(TemplateValue.number) }
            ), format: .number, prompt: Text("0"))
        case .toggle:
            Toggle("On by default", isOn: Binding(
                get: { parameter.defaultValue == .bool(true) },
                set: { parameter.defaultValue = $0 ? .bool(true) : nil }
            ))
        case .choice:
            Picker("Default", selection: Binding(
                get: { if case .text(let s) = parameter.defaultValue { s } else { "" } },
                set: { parameter.defaultValue = $0.isEmpty ? nil : .text($0) }
            )) {
                Text("First option").tag("")
                ForEach(parameter.options, id: \.self) { Text($0).tag($0) }
            }
        case .multichoice:
            ForEach(parameter.options, id: \.self) { option in
                Toggle(option, isOn: Binding(
                    get: { listDefault.contains(option) },
                    set: { on in
                        var list = listDefault.filter { $0 != option }
                        if on { list.append(option) }
                        parameter.defaultValue = list.isEmpty ? nil : .list(parameter.options.filter(list.contains))
                    }
                ))
            }
            if parameter.options.isEmpty {
                Text("Add options first.").foregroundStyle(.secondary)
            }
        case .list:
            ListTextBox(
                items: Binding(get: { listDefault }, set: { parameter.defaultValue = $0.isEmpty ? nil : .list($0) }),
                prompt: "One item per line", lines: 2...6, focus: multilineFocus, focusID: "default"
            )
        case .date:
            Toggle("Today", isOn: Binding(
                get: { parameter.defaultValue == nil },
                set: { parameter.defaultValue = $0 ? nil : .date(Date()) }
            ))
            if case .date(let date) = parameter.defaultValue {
                DatePicker("Date", selection: Binding(get: { date }, set: { parameter.defaultValue = .date($0) }), displayedComponents: .date)
            }
        }
    }

    private var listDefault: [String] {
        if case .list(let list) = parameter.defaultValue { return list }
        return []
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { if case .text(let s) = parameter.defaultValue { s } else { "" } },
            set: { parameter.defaultValue = $0.isEmpty ? nil : .text($0) }
        )
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
