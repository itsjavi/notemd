import AppKit
import SwiftUI

/// SwiftUI wrapper around `MarkdownTextView`.
///
/// Text flows out through `onChange`; text flows in only on creation or when
/// `revision` changes (external reloads), so typing never round-trips through SwiftUI.
struct MarkdownEditor: NSViewRepresentable {
    var text: String
    var revision: Int
    var isMarkdown = true
    var isEditable = true
    var font: NSFont
    var readableWidth: CGFloat
    var spellChecking: Bool
    var focusOnAppear = false
    var onChange: (String) -> Void
    /// Reports the first visible source line (1-based) while scrolling.
    var onScroll: ((Int) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = MarkdownTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        let textView = MarkdownTextView(frame: scrollView.contentView.bounds)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesAdaptiveColorMappingForDarkAppearance = true
        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator
        scrollView.documentView = textView

        context.coordinator.textView = textView
        configure(textView, coordinator: context.coordinator)
        textView.string = text
        context.coordinator.revision = revision
        context.coordinator.rehighlight()

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.didScroll(_:)), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        if focusOnAppear {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        let needsRestyle = configure(textView, coordinator: coordinator)
        if coordinator.revision != revision {
            coordinator.revision = revision
            if textView.string != text {
                let selection = textView.selectedRange()
                coordinator.isApplyingExternalText = true
                textView.string = text
                coordinator.isApplyingExternalText = false
                textView.undoManager?.removeAllActions(withTarget: textView.textStorage as Any)
                let length = (text as NSString).length
                textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
                coordinator.rehighlight()
                return
            }
        }
        if needsRestyle { coordinator.rehighlight() }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
        // The window's undo manager outlives this view: drop its actions so ⌘Z can't edit a discarded note.
        if let textView = coordinator.textView {
            textView.undoManager?.removeAllActions(withTarget: textView)
            if let storage = textView.textStorage { textView.undoManager?.removeAllActions(withTarget: storage) }
        }
    }

    /// Applies settings; returns true when styling needs a refresh.
    @discardableResult
    private func configure(_ textView: MarkdownTextView, coordinator: Coordinator) -> Bool {
        textView.isEditable = isEditable
        textView.isContinuousSpellCheckingEnabled = spellChecking && isMarkdown
        textView.readableWidth = readableWidth
        let changed = coordinator.styledFont != font || textView.isMarkdown != isMarkdown
        textView.isMarkdown = isMarkdown
        if changed {
            coordinator.styledFont = font
            let highlighter = MarkdownHighlighter(baseFont: font, isMarkdown: isMarkdown)
            textView.typingAttributes = highlighter.baseAttributes
            textView.font = font
        }
        return changed
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: MarkdownEditor
        weak var textView: MarkdownTextView?
        var revision = 0
        var styledFont: NSFont?
        var isApplyingExternalText = false
        private var isHighlighting = false
        private var lastReportedLine = 0

        init(_ parent: MarkdownEditor) {
            self.parent = parent
        }

        func rehighlight() {
            guard let storage = textView?.textStorage, let font = styledFont else { return }
            isHighlighting = true
            MarkdownHighlighter(baseFont: font, isMarkdown: parent.isMarkdown).highlight(storage)
            isHighlighting = false
        }

        nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            MainActor.assumeIsolated {
                guard !isHighlighting else { return }
                // Restyle after the edit settles (attributes can't change layout mid-processing safely).
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.rehighlightPreservingTyping() }
                }
            }
        }

        private func rehighlightPreservingTyping() {
            guard let textView else { return }
            let typing = textView.typingAttributes
            rehighlight()
            textView.typingAttributes = typing
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalText, let textView else { return }
            parent.onChange(textView.string)
        }

        @objc func didScroll(_ notification: Notification) {
            guard let onScroll = parent.onScroll, let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
            let visible = textView.visibleRect
            let point = NSPoint(x: visible.minX, y: visible.minY - textView.textContainerInset.height)
            let glyph = layoutManager.glyphIndex(for: point, in: container)
            let characterIndex = layoutManager.characterIndexForGlyph(at: glyph)
            let line = lineNumber(at: characterIndex, in: textView.string)
            guard line != lastReportedLine else { return }
            lastReportedLine = line
            onScroll(line)
        }

        private func lineNumber(at index: Int, in string: String) -> Int {
            var line = 1
            var count = 0
            for unit in string.utf16 {
                if count >= index { break }
                if unit == 10 { line += 1 }
                count += 1
            }
            return line
        }
    }
}
