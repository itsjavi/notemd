import SwiftUI

struct SettingsView: View {
    private let settings = AppSettings.shared
    @AppStorage("settingsTab") private var tab = "general"

    private let delays: [(String, Double)] = [("10 seconds", 10), ("30 seconds", 30), ("1 minute", 60), ("2 minutes", 120), ("5 minutes", 300)]

    var body: some View {
        @Bindable var settings = settings
        TabView(selection: $tab) {
            Form {
                Section {
                    Picker("Save a version after", selection: $settings.commitDelay) {
                        ForEach(delays, id: \.1) { Text($0.0).tag($0.1) }
                    }
                } header: {
                    Text("Version History")
                } footer: {
                    Text("Edits are saved to disk as you type. NoteMD records a git version once you've stopped editing for this long (and at least every 5 minutes while you keep typing), when you close a window, quit, or press ⌘S.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Notes") {
                    Toggle("Show notes from subfolders in folders", isOn: $settings.includeSubfolders)
                    Toggle("Show front matter in the editor", isOn: $settings.showFrontMatter)
                }
                Section {
                    Picker("Dropped or pasted files", selection: $settings.attachmentImportMode) {
                        ForEach(AttachmentImportMode.allCases) { Text($0.title).tag($0) }
                    }
                    TranscriptionLanguagePicker()
                } header: {
                    Text("Attachments & Voice Notes")
                } footer: {
                    Text("Files from outside the notes folder are copied into its assets folder, or linked where they are (links aren't versioned). Voice notes are transcribed on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Load remote images in previews", isOn: $settings.loadRemoteImages)
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Images from the web can tell their server when you open a file. Applies to previews opened after the change.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }
            .tag("general")

            Form {
                Section("Text") {
                    Picker("Font", selection: $settings.editorFontStyle) {
                        ForEach(EditorFontStyle.allCases) { Text($0.title).tag($0) }
                    }
                    Stepper(value: $settings.editorFontSize, in: 11...28, step: 1) {
                        LabeledContent("Size", value: "\(Int(settings.editorFontSize)) pt")
                    }
                    Toggle("Limit line width for comfortable reading", isOn: $settings.readableLineWidth)
                    Toggle("Check spelling while typing", isOn: $settings.spellChecking)
                    Toggle("Show line numbers", isOn: $settings.showLineNumbers)
                    Toggle("Show invisible characters", isOn: $settings.showInvisibles)
                }
                Section {
                    Picker("Indent using", selection: $settings.indentWithTabs) {
                        Text("Spaces").tag(false)
                        Text("Tabs").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Picker(settings.indentWithTabs ? "Tab width" : "Indent width", selection: $settings.indentWidth) {
                        ForEach([2, 4, 8], id: \.self) { Text("\($0) spaces").tag($0) }
                    }
                } header: {
                    Text("Indentation")
                } footer: {
                    Text("What the Tab key inserts in notes and text files. Shift-Tab removes one level. Existing text isn't changed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Layout") {
                    Picker("Default view", selection: $settings.editorMode) {
                        ForEach(EditorMode.allCases) { Text($0.title).tag($0) }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Editor", systemImage: "character.cursor.ibeam") }
            .tag("editor")
        }
        .frame(width: 520, height: 500)
    }
}
