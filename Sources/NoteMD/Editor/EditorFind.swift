import AppKit

/// Edit > Find for the note and document editors. It drives the text view's own find bar (NSTextFinder), which brings
/// incremental highlighting, the match count, Replace / Replace All and undo.
@MainActor enum EditorFind {
    static func perform(_ action: NSTextFinder.Action, in window: NSWindow? = NSApp.keyWindow) {
        guard let window, window.sheetParent == nil else { return }
        if let textView = window.firstResponder as? MarkdownTextView ?? window.contentView.flatMap(editorTextView(in:)) {
            run(action, on: textView)
            return
        }
        // Preview mode hides the editor: show it next to the preview, then search it.
        if let document = NSDocumentController.shared.document(for: window) as? TextFileDocument, document.model.hasPreview {
            document.model.editorRequest += 1
        } else if WindowManager.shared.controllers.contains(where: { $0.window === window && $0.store.editor != nil }) {
            AppSettings.shared.editorMode = .split
        } else {
            return
        }
        Task {
            // SwiftUI builds the editor on a later run loop pass.
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(50))
                if let textView = window.contentView.flatMap(editorTextView(in:)) {
                    run(action, on: textView)
                    return
                }
            }
        }
    }

    private static func run(_ action: NSTextFinder.Action, on textView: MarkdownTextView) {
        textView.window?.makeFirstResponder(textView)
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        textView.performTextFinderAction(sender)
    }

    static func editorTextView(in view: NSView) -> MarkdownTextView? {
        if let textView = view as? MarkdownTextView { return textView }
        for subview in view.subviews {
            if let found = editorTextView(in: subview) { return found }
        }
        return nil
    }
}
