import AppKit
import NoteMDCore
import SwiftUI

@main
struct NoteMDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
        .commands {
            NoteMDCommands()
        }
    }
}

struct NoteMDCommands: Commands {
    private var windows: WindowManager { .shared }
    private var store: RepositoryStore? { windows.activeStore }
    private var settings: AppSettings { .shared }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") { store?.createNote() }
                .keyboardShortcut("n")
                .disabled(store == nil)
            Button("New Incognito Note") { store?.createIncognitoNote() }
                .keyboardShortcut("n", modifiers: [.command, .control])
                .disabled(store == nil)
            Button("New Folder…") { store?.beginCreateFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(store == nil)
            Button("New Markdown File") { NSDocumentController.shared.newDocument(nil) }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Divider()
            Button("Open…") { windows.showOpenPanel() }
                .keyboardShortcut("o")
            Button("Open Notes Folder in New Window…") { windows.chooseRepository(replacing: nil) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("New Notes Folder…") { windows.createRepository(replacing: nil) }
            Menu("Open Recent") {
                Section("Notes Folders") {
                    ForEach(settings.recentRepositories, id: \.self) { path in
                        Button(path) { windows.openRepository(PathDisplay.expand(path)) }
                    }
                }
                Section("Files") {
                    ForEach(NSDocumentController.shared.recentDocumentURLs, id: \.self) { url in
                        Button(PathDisplay.abbreviate(url)) { windows.openFile(url) }
                    }
                }
                Divider()
                Button("Clear Menu") {
                    settings.recentRepositories = []
                    NSDocumentController.shared.clearRecentDocuments(nil)
                }
            }
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Version") {
                if let store, NSApp.keyWindow?.windowController is RepositoryWindowController {
                    Task { await store.saveVersionNow() }
                } else {
                    NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil)
                }
            }
            .keyboardShortcut("s")
            Button("Rename Note…") {
                if let store, let path = store.editor?.path { store.sheet = .renameNote(path: path) }
            }
            .disabled(store?.editor == nil)
            Button("Move Note to Trash") {
                if let store, let path = store.editor?.path { store.trashNote(path) }
            }
            .disabled(store?.editor == nil)
        }
        CommandMenu("Note") {
            Button("Use Template…") {
                if let store, let editor = store.editor, editor.isTemplate { store.sheet = .templateForm(path: editor.path) }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(store?.editor?.isTemplate != true)
            Button("Edit Template Parameters…") {
                if let store, let path = store.editor?.path { store.sheet = .templateParameters(path: path) }
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(store?.editor?.isTemplate != true)
            Divider()
            Button(store?.editor?.isTemplate == true ? "Convert to Note…" : "Convert to Template") {
                guard let store, let editor = store.editor else { return }
                if editor.isTemplate { store.requestConvertToNote(editor.path) } else { store.convertNote(editor.path, toTemplate: true, copy: false) }
            }
            .disabled(store?.editor == nil)
            Button(store?.editor?.isTemplate == true ? "Duplicate as Note" : "Duplicate as Template") {
                guard let store, let editor = store.editor else { return }
                store.convertNote(editor.path, toTemplate: !editor.isTemplate, copy: true)
            }
            .disabled(store?.editor == nil)
            Divider()
            Button("Version History…") {
                if let store, let path = store.editor?.path { store.sheet = .history(path: path) }
            }
            .keyboardShortcut("y", modifiers: [.command, .option])
            .disabled(store?.editor == nil || store?.git == nil || RepositoryLayout.isIncognitoPath(store?.editor?.path ?? ""))
            Button("Show in Finder") {
                if let store, let path = store.editor?.path { store.reveal(path) }
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(store?.editor == nil)
            Divider()
            Button("Record Voice Note") {
                if let document = NSApp.keyWindow?.windowController?.document as? TextFileDocument {
                    document.model.startVoiceNote()
                } else {
                    store?.startVoiceNote()
                }
            }
            .keyboardShortcut("r", modifiers: [.command, .control])
        }
        CommandMenu("Format") {
            formatButton("Bold", #selector(MarkdownTextView.toggleBold(_:)), "b")
            formatButton("Italic", #selector(MarkdownTextView.toggleItalic(_:)), "i")
            formatButton("Strikethrough", #selector(MarkdownTextView.toggleStrikethrough(_:)), "x", [.command, .shift])
            formatButton("Inline Code", #selector(MarkdownTextView.toggleInlineCode(_:)), "c", [.command, .option])
            formatButton("Link", #selector(MarkdownTextView.insertLink(_:)), "k")
            Divider()
            formatButton("Heading 1", #selector(MarkdownTextView.makeHeading1(_:)), "1", [.command, .option])
            formatButton("Heading 2", #selector(MarkdownTextView.makeHeading2(_:)), "2", [.command, .option])
            formatButton("Heading 3", #selector(MarkdownTextView.makeHeading3(_:)), "3", [.command, .option])
            formatButton("Body Text", #selector(MarkdownTextView.makeBodyText(_:)), "0", [.command, .option])
            Divider()
            formatButton("Bulleted List", #selector(MarkdownTextView.toggleBulletList(_:)), "l", [.command, .shift])
            formatButton("Numbered List", #selector(MarkdownTextView.toggleNumberedList(_:)), "o", [.command, .option])
            formatButton("Checklist", #selector(MarkdownTextView.toggleTaskList(_:)), "t", [.command, .option])
            formatButton("Quote", #selector(MarkdownTextView.toggleQuote(_:)), "'", [.command, .option])
            Divider()
            formatButton("Code Block", #selector(MarkdownTextView.insertCodeBlock(_:)), "k", [.command, .option])
            formatButton("Table", #selector(MarkdownTextView.insertTable(_:)), nil)
        }
        CommandGroup(after: .sidebar) {
            Picker("Editor Mode", selection: Bindable(settings).editorMode) {
                Text("Editor").tag(EditorMode.edit).keyboardShortcut("1")
                Text("Split").tag(EditorMode.split).keyboardShortcut("2")
                Text("Preview").tag(EditorMode.preview).keyboardShortcut("3")
            }
            .pickerStyle(.inline)
            Toggle("Show Front Matter", isOn: Binding(
                get: { settings.showFrontMatter },
                set: { value in
                    settings.showFrontMatter = value
                    for controller in windows.controllers { controller.store.reopenCurrentNote() }
                }
            ))
            Toggle("Show Line Numbers", isOn: Bindable(settings).showLineNumbers)
            Toggle("Show Invisible Characters", isOn: Bindable(settings).showInvisibles)
            Divider()
        }
        CommandGroup(after: .textEditing) {
            Menu("Find") {
                Button("Find…") { EditorFind.perform(.showFindInterface) }
                    .keyboardShortcut("f")
                Button("Find and Replace…") { EditorFind.perform(.showReplaceInterface) }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Button("Find Next") { EditorFind.perform(.nextMatch) }
                    .keyboardShortcut("g")
                Button("Find Previous") { EditorFind.perform(.previousMatch) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Use Selection for Find") { EditorFind.perform(.setSearchString) }
                    .keyboardShortcut("e")
                Button("Jump to Selection") { NSApp.sendAction(#selector(NSTextView.centerSelectionInVisibleArea(_:)), to: nil, from: nil) }
                    .keyboardShortcut("j")
            }
            // ⇧⌘F, as "find in all files" elsewhere; ⌥⌘F is Find and Replace.
            Button("Search Notes") {
                NSApp.keyWindow?.toolbar?.items.first { $0 is NSSearchToolbarItem }.map { item in
                    (item as? NSSearchToolbarItem)?.beginSearchInteraction()
                }
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
        }
    }

    private func formatButton(_ title: String, _ action: Selector, _ key: Character?, _ modifiers: EventModifiers = .command) -> some View {
        let button = Button(title) { NSApp.sendAction(action, to: nil, from: nil) }
        return Group {
            if let key {
                button.keyboardShortcut(KeyEquivalent(key), modifiers: modifiers)
            } else {
                button
            }
        }
    }
}
