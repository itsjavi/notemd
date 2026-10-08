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
}
