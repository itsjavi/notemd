import SwiftUI

struct SettingsView: View {
    private let settings = AppSettings.shared

    private let delays: [(String, Double)] = [("10 seconds", 10), ("30 seconds", 30), ("1 minute", 60), ("2 minutes", 120), ("5 minutes", 300)]

    var body: some View {
        @Bindable var settings = settings
        TabView {
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
                }
                Section("Layout") {
                    Picker("Default view", selection: $settings.editorMode) {
                        ForEach(EditorMode.allCases) { Text($0.title).tag($0) }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Editor", systemImage: "character.cursor.ibeam") }
        }
        .frame(width: 520, height: 400)
    }
}
