import AppKit

/// NSTextView with Markdown editing conveniences: list continuation, list indentation and formatting commands.
final class MarkdownTextView: NSTextView {
    var isMarkdown = true
    /// Maximum text width for comfortable reading; 0 = fill the view.
    var readableWidth: CGFloat = 0 {
        didSet { updateInsets() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateInsets()
    }

    private func updateInsets() {
        let minimum: CGFloat = 28
        let horizontal = readableWidth > 0 ? max(minimum, (bounds.width - readableWidth) / 2) : minimum
        let inset = NSSize(width: horizontal.rounded(), height: 22)
        if textContainerInset != inset { textContainerInset = inset }
    }

    // MARK: Lists

    private static let listPattern = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+]|(\d{1,9})([.)]))([ \t]+)(\[[ xX]\][ \t]+)?"#)
    private static let quotePattern = try! NSRegularExpression(pattern: #"^([ \t]*>[ \t]?)+"#)

    override func insertNewline(_ sender: Any?) {
        guard isMarkdown, selectedRanges.count == 1, let range = selectedRanges.first?.rangeValue else {
            super.insertNewline(sender)
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
        guard isMarkdown, selectedLinesAreListItems() else {
            super.insertTab(sender)
            return
        }
        transformSelectedLines { "    " + $0 }
    }

    override func insertBacktab(_ sender: Any?) {
        guard isMarkdown else {
            super.insertBacktab(sender)
            return
        }
        transformSelectedLines { line in
            var line = line
            var removed = 0
            while removed < 4, line.first == " " { line.removeFirst(); removed += 1 }
            if removed == 0, line.first == "\t" { line.removeFirst() }
            return line
        }
    }

    private func selectedLinesAreListItems() -> Bool {
        let ns = string as NSString
        let lines = ns.lineRange(for: selectedRange())
        let text = ns.substring(with: lines)
        return text.split(separator: "\n").allSatisfy { line in
            Self.listPattern.firstMatch(in: String(line), range: NSRange(location: 0, length: (String(line) as NSString).length)) != nil
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
        let lines = ns.substring(with: ns.lineRange(for: selectedRange())).split(separator: "\n", omittingEmptySubsequences: false)
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
        var lineRange = ns.lineRange(for: selection)
        var text = ns.substring(with: lineRange)
        let hadTrailingNewline = text.hasSuffix("\n")
        if hadTrailingNewline { text.removeLast() }
        if text.isEmpty && lineRange.length == 0 { lineRange = NSRange(location: selection.location, length: 0) }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { transform(String($0)) }
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
