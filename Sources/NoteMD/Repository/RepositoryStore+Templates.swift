import Foundation
import NoteMDCore

extension RepositoryStore {
    /// Templates sorted by title, for New Note from Template menus.
    var templatesByTitle: [Note] {
        notes.filter(\.isTemplate).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Creates an example template and opens its parameters sheet.
    func createTemplate() {
        let body = "# New Template\n\nWrite about **{{topic}}** in a {{tone}} tone.\n"
        guard let path = createNote(title: "New Template", body: body) else { return }
        if let editor, editor.path == path {
            editor.setParameters([
                TemplateParameter(name: "topic", type: .text, required: true, placeholder: "What should it be about?"),
                TemplateParameter(name: "tone", type: .choice, defaultValue: .text("friendly"), options: ["friendly", "formal", "playful"]),
            ])
        }
        sheet = .templateParameters(path: path)
    }

    // MARK: Converting

    /// Convert to Note on a template: asks first when the conversion would drop its parameters.
    func requestConvertToNote(_ path: String) {
        guard let text = currentText(ofNoteAt: path) else { return }
        if MarkdownText(text).frontMatter?.parameters.isEmpty == false {
            templatePendingConversion = path
        } else {
            convertNote(path, toTemplate: false, copy: false)
        }
    }

    /// Makes the note at `path` a template (`template: true`) or a plain note (no `template` or `params`), leaving
    /// the body and other front matter as they are. With `copy`, the converted version is a new note next to it
    /// and the original stays unchanged.
    func convertNote(_ path: String, toTemplate: Bool, copy: Bool) {
        if templatePendingConversion == path { templatePendingConversion = nil }
        guard let note = note(at: path), let text = currentText(ofNoteAt: path) else { return }
        guard copy || note.isTemplate != toTemplate else { return }
        var markdown = MarkdownText(text)
        markdown.setTemplate(toTemplate)
        if copy {
            let base = note.baseName + (toTemplate ? " template" : " note")
            let target = NoteFileName.uniqueURL(in: note.url.deletingLastPathComponent(), base: base, pathExtension: note.url.pathExtension)
            do {
                try Data(markdown.text.utf8).write(to: target, options: .withoutOverwriting)
            } catch {
                errorMessage = "Couldn't create the copy: \(error.localizedDescription)"
                return
            }
            let newPath = relativePath(of: target)
            _ = scanSingle(newPath)
            showConverted(newPath, isTemplate: toTemplate)
        } else if let editor, editor.path == path {
            // Through the editor, so the change is undoable and the open text stays in sync.
            editor.setTemplate(toTemplate)
            editor.save()
            showConverted(path, isTemplate: toTemplate)
            return
        } else {
            do {
                try SafeFileWriter.write(Data(markdown.text.utf8), to: note.url)
            } catch {
                errorMessage = "Couldn't convert “\(note.title)”: \(error.localizedDescription)"
                return
            }
            _ = scanSingle(path)
            showConverted(path, isTemplate: toTemplate)
        }
        if !RepositoryLayout.isIncognitoPath(path) { autoCommitter?.markDirty() }
    }

    /// Selects a converted note, leaving the Templates list when it's no longer a template.
    private func showConverted(_ path: String, isTemplate: Bool) {
        if sidebarSelection == .templates && !isTemplate { sidebarSelection = .allNotes }
        refreshVisibleNotes()
        selectedNoteID = path
    }
}
