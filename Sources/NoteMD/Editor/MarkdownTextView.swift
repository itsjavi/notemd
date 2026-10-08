import AppKit

/// NSTextView with Markdown editing conveniences: list continuation, list indentation and formatting commands.
final class MarkdownTextView: NSTextView {
    var isMarkdown = true
    var indentation = Indentation(usesTabs: false, width: 4)
    /// Maximum text width for comfortable reading; 0 = fill the view.
    var readableWidth: CGFloat = 0 {
        didSet { updateInsets() }
    }

    /// Turns dropped and pasted files into Markdown links; nil keeps NSTextView's behavior.
    var attachmentImporter: AttachmentImporter? {
        didSet { if (oldValue == nil) != (attachmentImporter == nil) { updateDragTypeRegistration() } }
    }

    /// Draws a line-number gutter in the left margin, right next to the text.
    var showsLineNumbers = false {
        didSet {
            guard showsLineNumbers != oldValue else { return }
            lineStarts = nil
            if showsLineNumbers {
                _ = currentLineStarts()  // sizes the gutter before the first draw
                addSubview(gutterView)
            } else {
                gutterView.removeFromSuperview()
            }
            updateInsets()
        }
    }

    private lazy var gutterView = LineNumberGutterView(textView: self)

    /// The text view keeps its own TextKit 1 storage alive (see `make(frame:)`).
    private var ownedStorage: NSTextStorage?

    /// A text view on an explicit TextKit 1 stack whose layout manager can draw invisible characters.
    static func make(frame: NSRect) -> MarkdownTextView {
        let storage = NSTextStorage()
        let layoutManager = EditorLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: frame.width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        let textView = MarkdownTextView(frame: frame, textContainer: container)
        textView.ownedStorage = storage
        return textView
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateInsets()
        updateGutterFrame()
    }

    override var font: NSFont? {
        didSet { if showsLineNumbers { updateInsets() } }
    }

    // MARK: Attachments

    private static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        // Lets Paste stay enabled for copied images and files.
        attachmentImporter == nil ? super.readablePasteboardTypes : super.readablePasteboardTypes + [.fileURL, .png, .tiff]
    }

    override func dragOperation(for dragInfo: any NSDraggingInfo, type: NSPasteboard.PasteboardType) -> NSDragOperation {
        if attachmentImporter != nil, isEditable, !Self.fileURLs(on: dragInfo.draggingPasteboard).isEmpty { return .copy }
        return super.dragOperation(for: dragInfo, type: type)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = Self.fileURLs(on: sender.draggingPasteboard)
        guard attachmentImporter != nil, isEditable, !urls.isEmpty else { return super.performDragOperation(sender) }
        let index = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        // Finish the drag session before a copy-or-link prompt can appear.
        DispatchQueue.main.async { [weak self] in
            self?.insertAttachments(urls, at: NSRange(location: index, length: 0))
        }
        return true
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if attachmentImporter != nil, isEditable {
            let urls = Self.fileURLs(on: pasteboard)
            // One copied file is attached; several keep the normal paste (their names).
            if urls.count == 1 {
                insertAttachments(urls, at: selectedRange())
                return
            }
            // Image data alone (e.g. a crop copied in Preview); text wins when both are there.
            if urls.isEmpty, pasteboard.string(forType: .string) == nil,
               let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
                pasteImageData(data)
                return
            }
        }
        super.paste(sender)
    }

    /// Copies or links `urls` and inserts their links at `range` as one undoable edit.
    func insertAttachments(_ urls: [URL], at range: NSRange) {
        guard let markdown = attachmentImporter?.markdown(forFiles: urls) else { return }
        insertMarkdown(markdown, at: range)
    }

    func pasteImageData(_ data: Data) {
        guard let markdown = attachmentImporter?.markdown(forImageData: data) else { return }
        insertMarkdown(markdown, at: selectedRange())
    }

    private func insertMarkdown(_ markdown: String, at range: NSRange) {
        let length = (string as NSString).length
        let location = min(range.location, length)
        insertText(markdown, replacementRange: NSRange(location: location, length: min(range.length, length - location)))
    }

    private func updateInsets() {
        let minimum: CGFloat = 28
        let margin = readableWidth > 0 ? max(minimum, (bounds.width - readableWidth) / 2) : minimum
        // The gutter sits in the left margin and widens it only when the margin is too narrow for it.
        let left = showsLineNumbers ? max(margin, minimum + gutterWidth) : margin
        let inset = NSSize(width: ((left + margin) / 2).rounded(), height: 22)
        let shift = ((left - margin) / 2).rounded()
        let shiftChanged = shift != gutterShift
        gutterShift = shift
        if textContainerInset != inset {
            textContainerInset = inset
        } else if shiftChanged {
            invalidateTextContainerOrigin()
        }
        updateGutterFrame()
    }

    private func updateGutterFrame() {
        guard showsLineNumbers else { return }
        let frame = NSRect(x: 0, y: 0, width: textContainerOrigin.x, height: bounds.height)
        if gutterView.frame != frame {
            gutterView.frame = frame
            gutterView.needsDisplay = true
        }
    }

    // MARK: Line numbers

    /// How far the text container moves right of its symmetric inset, making the left margin wider than the right.
    private var gutterShift: CGFloat = 0
    /// UTF-16 offsets where logical lines start; nil after an edit until recomputed.
    private var lineStarts: [Int]?
    private var gutterDigits = 2

    override var textContainerOrigin: NSPoint {
        let origin = super.textContainerOrigin
        return NSPoint(x: origin.x + gutterShift, y: origin.y)
    }

    private var lineNumberFont: NSFont {
        .monospacedDigitSystemFont(ofSize: max(9, ((font?.pointSize ?? 13) * 0.7).rounded()), weight: .regular)
    }

    private var gutterWidth: CGFloat {
        CGFloat(gutterDigits) * ("8" as NSString).size(withAttributes: [.font: lineNumberFont]).width + 16
    }

    /// The visible part of the left margin, where the numbers are drawn.

    /// Called for every character edit (from the text storage delegate).
    func textDidEdit() {
        lineStarts = nil
        guard showsLineNumbers else { return }
        // Not during the storage's edit processing: the gutter may need to widen, which changes layout.
        DispatchQueue.main.async { [weak self] in
            guard let self, showsLineNumbers else { return }
            _ = currentLineStarts()
            gutterView.setNeedsDisplay(gutterView.visibleRect)
        }
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if showsLineNumbers { gutterView.setNeedsDisplay(gutterView.visibleRect) }  // the current line's number is highlighted
    }

    private func currentLineStarts() -> [Int] {
        if let lineStarts { return lineStarts }
        let text = string as NSString
        var starts = [0]
        var index = 0
        while index < text.length {
            var end = 0
            var contentsEnd = 0
            text.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: index, length: 0))
            // A line break: the next line starts at `end`, even when that is the empty line at the very end.
            if end > contentsEnd { starts.append(end) }
            index = end
        }
        lineStarts = starts
        let digits = max(2, String(starts.count).count)
        if digits != gutterDigits {
            gutterDigits = digits
            updateInsets()
        }
        return starts
    }

    private static func lineIndex(of location: Int, in starts: [Int]) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// Numbers logical lines (a wrapped line gets one number) right-aligned against the text, on each line's baseline.
    /// Drawn by the gutter subview: what the text view draws itself after `super.draw` never reaches the screen.
    fileprivate func drawLineNumbers(in dirtyRect: NSRect) {
        guard let layoutManager, let container = textContainer else { return }
        let origin = textContainerOrigin
        let right = origin.x - 10
        guard dirtyRect.minX < right else { return }
        let starts = currentLineStarts()
        let current = Self.lineIndex(of: selectedRange().location, in: starts)
        let numberFont = lineNumberFont
        let area = NSRect(x: 0, y: dirtyRect.minY - origin.y, width: container.size.width, height: dirtyRect.height)

        func drawNumber(_ line: Int, baseline: CGFloat) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: numberFont,
                .foregroundColor: line == current ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor,
            ]
            let label = String(line + 1) as NSString
            let width = label.size(withAttributes: attributes).width
            label.draw(at: NSPoint(x: right - width, y: baseline - numberFont.ascender), withAttributes: attributes)
        }

        let glyphs = layoutManager.glyphRange(forBoundingRect: area, in: container)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, range, _ in
            let character = layoutManager.characterIndexForGlyph(at: range.location)
            let line = Self.lineIndex(of: character, in: starts)
            guard starts[line] == character else { return }  // the continuation of a wrapped line
            drawNumber(line, baseline: origin.y + fragment.minY + layoutManager.location(forGlyphAt: range.location).y)
        }
        // The empty line after a final line break has no glyphs.
        if layoutManager.extraLineFragmentTextContainer != nil, layoutManager.extraLineFragmentRect.intersects(area) {
            drawNumber(starts.count - 1, baseline: origin.y + layoutManager.extraLineFragmentRect.minY + (font?.ascender ?? numberFont.ascender))
        }
    }

    // MARK: Lists

    private static let listPattern = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+]|(\d{1,9})([.)]))([ \t]+)(\[[ xX]\][ \t]+)?"#)
    private static let quotePattern = try! NSRegularExpression(pattern: #"^([ \t]*>[ \t]?)+"#)

    override func insertNewline(_ sender: Any?) {
        guard selectedRanges.count == 1, let range = selectedRanges.first?.rangeValue else {
            super.insertNewline(sender)
            return
        }
        guard isMarkdown else {
            // Code and text files keep the current line's indentation.
            let ns = string as NSString
            let lineStart = ns.lineRange(for: NSRange(location: range.location, length: 0)).location
            let before = ns.substring(with: NSRange(location: lineStart, length: range.location - lineStart))
            let indent = before.prefix { $0 == " " || $0 == "\t" }
            insertText("\n" + indent, replacementRange: range)
            return
        }
        let ns = string as NSString
        let lineRange = ns.lineRange(for: NSRange(location: range.location, length: 0))
        let lineStart = lineRange.location
        let lineText = ns.substring(with: NSRange(location: lineStart, length: range.location - lineStart))

        if let match = Self.listPattern.firstMatch(in: lineText, range: NSRange(location: 0, length: (lineText as NSString).length)) {
            let marker = (lineText as NSString).substring(with: match.range)
            if marker.count == lineText.count && range.length == 0 && restOfLineIsEmpty(after: range.location) {
                // Empty item: end the list.
                insertText("", replacementRange: NSRange(location: lineStart, length: (lineText as NSString).length))
                super.insertNewline(sender)
                return
            }
            let line = lineText as NSString
            let indent = line.substring(with: match.range(at: 1))
            var bullet = line.substring(with: match.range(at: 2))
            if match.range(at: 3).location != NSNotFound, let number = Int(line.substring(with: match.range(at: 3))) {
                bullet = "\(number + 1)" + line.substring(with: match.range(at: 4))
            }
            let spacing = line.substring(with: match.range(at: 5))
            let task = match.range(at: 6).location != NSNotFound ? "[ ] " : ""
            insertText("\n" + indent + bullet + spacing + task, replacementRange: range)
            return
        }
        if let match = Self.quotePattern.firstMatch(in: lineText, range: NSRange(location: 0, length: (lineText as NSString).length)) {
            let prefix = (lineText as NSString).substring(with: match.range)
            if prefix.count == lineText.count && restOfLineIsEmpty(after: range.location) {
                insertText("", replacementRange: NSRange(location: lineStart, length: (lineText as NSString).length))
                super.insertNewline(sender)
                return
            }
            insertText("\n" + prefix, replacementRange: range)
            return
        }
        super.insertNewline(sender)
    }

    private func restOfLineIsEmpty(after location: Int) -> Bool {
        let ns = string as NSString
        let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
        let rest = ns.substring(with: NSRange(location: location, length: NSMaxRange(lineRange) - location))
        return rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    override func insertTab(_ sender: Any?) {
        let selection = selectedRange()
        let ns = string as NSString
        let spansLines = selection.length > 0 && ns.substring(with: selection).contains(where: \.isNewline)
        if spansLines || (isMarkdown && selectedLinesAreListItems()) {
            let unit = indentation.unit
            transformSelectedLines { $0.isEmpty ? $0 : unit + $0 }
            return
        }
        if indentation.usesTabs {
            insertText("\t", replacementRange: selection)
            return
        }
        // Spaces up to the next indent stop, counting tabs at their display width.
        let lineStart = ns.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let before = ns.substring(with: NSRange(location: lineStart, length: selection.location - lineStart))
        let width = max(indentation.width, 1)
        let column = before.reduce(0) { column, character in character == "\t" ? column + width - column % width : column + 1 }
        insertText(String(repeating: " ", count: width - column % width), replacementRange: selection)
    }

    override func insertBacktab(_ sender: Any?) {
        let width = max(indentation.width, 1)
        transformSelectedLines { line in
            if line.first == "\t" { return String(line.dropFirst()) }
            let spaces = line.prefix { $0 == " " }.count
            return String(line.dropFirst(min(spaces, width)))
        }
    }

    private func selectedLinesAreListItems() -> Bool {
        let ns = string as NSString
        let lines = ns.lineRange(for: selectedRange())
        let text = ns.substring(with: lines)
        return text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.allSatisfy { line in
            Self.listPattern.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
        }
    }

    // MARK: Formatting commands (sent through the responder chain from the Format menu)

    @objc func toggleBold(_ sender: Any?) { wrapSelection("**") }
    @objc func toggleItalic(_ sender: Any?) { wrapSelection("_") }
    @objc func toggleStrikethrough(_ sender: Any?) { wrapSelection("~~") }
    @objc func toggleInlineCode(_ sender: Any?) { wrapSelection("`") }
    @objc func makeHeading1(_ sender: Any?) { setHeading(1) }
    @objc func makeHeading2(_ sender: Any?) { setHeading(2) }
    @objc func makeHeading3(_ sender: Any?) { setHeading(3) }
    @objc func makeBodyText(_ sender: Any?) { setHeading(0) }
    @objc func toggleBulletList(_ sender: Any?) { toggleLinePrefix("- ") }
    @objc func toggleTaskList(_ sender: Any?) { toggleTask() }
    @objc func toggleNumberedList(_ sender: Any?) { toggleLinePrefix("1. ") }
    @objc func toggleQuote(_ sender: Any?) { toggleLinePrefix("> ") }

    @objc func insertLink(_ sender: Any?) {
        let range = selectedRange()
        let selected = (string as NSString).substring(with: range)
        let pasteboardURL = NSPasteboard.general.string(forType: .string).flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") ? trimmed : nil
        }
        if selected.hasPrefix("http://") || selected.hasPrefix("https://") {
            insertText("[](\(selected))", replacementRange: range)
            setSelectedRange(NSRange(location: range.location + 1, length: 0))
        } else {
            let url = pasteboardURL ?? "https://"
            insertText("[\(selected)](\(url))", replacementRange: range)
            if selected.isEmpty {
                setSelectedRange(NSRange(location: range.location + 1, length: 0))
            } else {
                let urlStart = range.location + (selected as NSString).length + 3
                setSelectedRange(NSRange(location: urlStart, length: (url as NSString).length))
            }
        }
    }

    @objc func insertCodeBlock(_ sender: Any?) {
        let range = selectedRange()
        let selected = (string as NSString).substring(with: range)
        insertText("```\n\(selected)\n```", replacementRange: range)
        setSelectedRange(NSRange(location: range.location + 3, length: 0))
    }

    @objc func insertTable(_ sender: Any?) {
        insertText("| Column | Column |\n| ------ | ------ |\n|        |        |\n", replacementRange: selectedRange())
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let markdownActions: Set<Selector> = [
            #selector(toggleBold(_:)), #selector(toggleItalic(_:)), #selector(toggleStrikethrough(_:)), #selector(toggleInlineCode(_:)),
            #selector(makeHeading1(_:)), #selector(makeHeading2(_:)), #selector(makeHeading3(_:)), #selector(makeBodyText(_:)),
            #selector(toggleBulletList(_:)), #selector(toggleTaskList(_:)), #selector(toggleNumberedList(_:)), #selector(toggleQuote(_:)),
            #selector(insertLink(_:)), #selector(insertCodeBlock(_:)), #selector(insertTable(_:)),
        ]
        if let action = menuItem.action, markdownActions.contains(action) { return isMarkdown && isEditable }
        return super.validateMenuItem(menuItem)
    }

    private func wrapSelection(_ marker: String) {
        let range = selectedRange()
        let ns = string as NSString
        let markerLength = (marker as NSString).length
        let selected = ns.substring(with: range)
        // Unwrap when the selection is already wrapped (inside or including the markers).
        if selected.hasPrefix(marker), selected.hasSuffix(marker), (selected as NSString).length >= markerLength * 2 {
            let inner = (selected as NSString).substring(with: NSRange(location: markerLength, length: (selected as NSString).length - markerLength * 2))
            insertText(inner, replacementRange: range)
            setSelectedRange(NSRange(location: range.location, length: (inner as NSString).length))
            return
        }
        if range.location >= markerLength, NSMaxRange(range) + markerLength <= ns.length,
           ns.substring(with: NSRange(location: range.location - markerLength, length: markerLength)) == marker,
           ns.substring(with: NSRange(location: NSMaxRange(range), length: markerLength)) == marker {
            let outer = NSRange(location: range.location - markerLength, length: range.length + markerLength * 2)
            insertText(selected, replacementRange: outer)
            setSelectedRange(NSRange(location: outer.location, length: range.length))
            return
        }
        insertText(marker + selected + marker, replacementRange: range)
        setSelectedRange(NSRange(location: range.location + markerLength, length: range.length))
    }

    private func setHeading(_ level: Int) {
        transformSelectedLines { line in
            let stripped = line.replacingOccurrences(of: #"^#{1,6}[ \t]+"#, with: "", options: .regularExpression)
            return level == 0 ? stripped : String(repeating: "#", count: level) + " " + stripped
        }
    }

    private func toggleLinePrefix(_ prefix: String) {
        let ns = string as NSString
        let lines = ns.substring(with: ns.lineRange(for: selectedRange())).components(separatedBy: "\n")
        let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let numbered = prefix == "1. "
        let allPrefixed = !content.isEmpty && content.allSatisfy { line in
            numbered ? line.range(of: #"^\s*\d+[.)] "#, options: .regularExpression) != nil : line.trimmingCharacters(in: .whitespaces).hasPrefix(prefix.trimmingCharacters(in: .whitespaces))
        }
        var counter = 0
        transformSelectedLines { line in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
            if allPrefixed {
                let pattern = numbered ? #"^(\s*)\d+[.)] "# : "^(\\s*)" + NSRegularExpression.escapedPattern(for: prefix.trimmingCharacters(in: .whitespaces)) + " ?"
                return line.replacingOccurrences(of: pattern, with: "$1", options: .regularExpression)
            }
            counter += 1
            return (numbered ? "\(counter). " : prefix) + line
        }
    }

    private func toggleTask() {
        transformSelectedLines { line in
            if let range = line.range(of: #"^(\s*)[-*+] \[[ xX]\] "#, options: .regularExpression) {
                // Toggle checked state.
                let marker = String(line[range])
                let toggled = marker.contains("[ ]") ? marker.replacingOccurrences(of: "[ ]", with: "[x]") : marker.replacingOccurrences(of: #"\[[xX]\]"#, with: "[ ]", options: .regularExpression)
                return toggled + line[range.upperBound...]
            }
            if let range = line.range(of: #"^(\s*)[-*+] "#, options: .regularExpression) {
                return String(line[range]) + "[ ] " + line[range.upperBound...]
            }
            return line.trimmingCharacters(in: .whitespaces).isEmpty ? "- [ ] " : "- [ ] " + line
        }
    }

    /// Rewrites every line touched by the selection as one undoable change.
    private func transformSelectedLines(_ transform: (String) -> String) {
        let ns = string as NSString
        let selection = selectedRange()
        let lineRange = ns.lineRange(for: selection)
        // NSString line handling: "\r\n" is one Character in Swift, so String.split would miss it.
        var text = ns.substring(with: lineRange) as NSString
        let hadTrailingNewline = text.hasSuffix("\n")
        if hadTrailingNewline { text = text.substring(to: text.length - 1) as NSString }
        let lines = (text as String).components(separatedBy: "\n").map { line in
            line.hasSuffix("\r") ? transform(String(line.dropLast())) + "\r" : transform(line)
        }
        let replacement = lines.joined(separator: "\n") + (hadTrailingNewline ? "\n" : "")
        insertText(replacement, replacementRange: lineRange)
        let newLength = (replacement as NSString).length - (hadTrailingNewline ? 1 : 0)
        if selection.length == 0 && lines.count == 1 {
            setSelectedRange(NSRange(location: lineRange.location + newLength, length: 0))
        } else {
            setSelectedRange(NSRange(location: lineRange.location, length: newLength))
        }
    }
}

/// The line-number gutter: a transparent subview over the text view's left margin that scrolls with the text.
/// Clicks pass through to the text view.
private final class LineNumberGutterView: NSView {
    weak var textView: MarkdownTextView?

    init(textView: MarkdownTextView) {
        self.textView = textView
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        textView?.drawLineNumbers(in: dirtyRect)
    }
}
