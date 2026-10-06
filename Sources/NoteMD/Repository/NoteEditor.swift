import Foundation
import NoteMDCore
import Observation

/// The note currently open in a repository window: its text, parsed front matter and debounced saving.
@Observable final class NoteEditor: Identifiable {
    let id = UUID()
    private(set) var path: String
    private(set) var url: URL
    /// The full document (front matter + body).
    private(set) var markdown: MarkdownText
    /// What the editor shows: the body, or the full text when front matter is visible.
    private(set) var editorText: String
    let showsFrontMatter: Bool
    private(set) var isDirty = false
    /// Bumped when the text is replaced from outside the editor (reload, restore), so the text view refreshes.
    private(set) var externalRevision = 0

    @ObservationIgnored private var lastSavedText: String
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored var onSave: ((NoteEditor) -> Void)?
    @ObservationIgnored var onSaveError: ((Error) -> Void)?

    init(path: String, url: URL, text: String, showsFrontMatter: Bool) {
        self.path = path
        self.url = url
        self.markdown = MarkdownText(text)
        self.showsFrontMatter = showsFrontMatter
        self.lastSavedText = text
        self.editorText = showsFrontMatter ? text : MarkdownText(text).body
    }

    var fullText: String { markdown.text }
    var tags: [String] { markdown.frontMatter?.tags ?? [] }
    var parameters: [TemplateParameter] { markdown.frontMatter?.parameters ?? [] }
    var isTemplate: Bool { markdown.frontMatter?.isTemplate ?? false }
    var frontMatterError: String? { markdown.frontMatter?.parseError }

    var title: String {
        NoteTitle.derive(
            frontMatterTitle: markdown.frontMatter?.title, body: markdown.body,
            fileName: (url.lastPathComponent as NSString).deletingPathExtension)
    }

    // MARK: Edits

    func editorTextChanged(_ text: String) {
        guard text != editorText else { return }
        editorText = text
        if showsFrontMatter {
            markdown = MarkdownText(text)
        } else {
            markdown.body = text
        }
        scheduleSave()
    }

    func setTags(_ tags: [String]) {
        updateFrontMatter { $0.setTags(tags) }
    }

    func setParameters(_ parameters: [TemplateParameter]) {
        updateFrontMatter { $0.setParameters(parameters) }
    }

    private func updateFrontMatter(_ change: (inout FrontMatter) -> Void) {
        var frontMatter = markdown.frontMatter ?? FrontMatter()
        change(&frontMatter)
        markdown.frontMatter = frontMatter.isEmpty ? nil : frontMatter
        if showsFrontMatter {
            editorText = markdown.text
            externalRevision += 1
        }
        scheduleSave(delay: 0.1)
    }

    /// Replaces the whole document (restore, external change) without going through the editor.
    func replaceText(_ text: String, markSaved: Bool) {
        markdown = MarkdownText(text)
        editorText = showsFrontMatter ? text : markdown.body
        externalRevision += 1
        if markSaved {
            lastSavedText = text
            isDirty = false
            saveWork?.cancel()
        } else {
            scheduleSave(delay: 0.1)
        }
    }

    /// Called when the file was renamed or moved by the app.
    func relocate(path: String, url: URL) {
        self.path = path
        self.url = url
    }

    // MARK: Saving

    private func scheduleSave(delay: TimeInterval = 0.5) {
        isDirty = fullText != lastSavedText
        saveWork?.cancel()
        guard isDirty else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.saveWork = nil
                self?.save()
            }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Writes pending changes now. Returns false when writing failed.
    @discardableResult func save() -> Bool {
        saveWork?.cancel()
        saveWork = nil
        let text = fullText
        guard text != lastSavedText else {
            isDirty = false
            return true
        }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            lastSavedText = text
            isDirty = false
            onSave?(self)
            return true
        } catch {
            onSaveError?(error)
            return false
        }
    }

    /// Whether `diskText` is just our own last write coming back from the file watcher.
    func isOwnWrite(_ diskText: String) -> Bool {
        diskText == lastSavedText
    }
}
