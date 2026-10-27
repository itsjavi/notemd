import Foundation

/// The `[ ]` / `[x]` marker of a GFM task list item, found by the source line the preview reports for it.
public enum TaskCheckbox {
    /// A list item marker (in block quotes, indented or not) followed by `[ ]`, `[x]` or `[X]` and a space or the
    /// line's end. Group 1 is the state character.
    private static let pattern = try! NSRegularExpression(
        pattern: #"^(?:[ \t]*>)*[ \t]*(?:[-+*]|[0-9]{1,9}[.)])[ \t]+\[([ xX])\](?=[ \t\r]|$)"#)

    /// The UTF-16 range of the state character of the task item that starts on 1-based `line` of `text`, and what
    /// toggles it (`x` for an open task, a space for a done one); nil when that line doesn't start a task item.
    public static func toggle(in text: String, line: Int) -> (range: NSRange, replacement: String)? {
        guard let lineRange = lineRange(line, in: text as NSString),
              let match = pattern.firstMatch(in: text, range: lineRange)
        else { return nil }
        let state = match.range(at: 1)
        return (state, (text as NSString).substring(with: state) == " " ? "x" : " ")
    }

    /// The UTF-16 range of 1-based `line`, without its line ending. Lines end at `\n`, `\r\n` or `\r`, as in cmark.
    static func lineRange(_ line: Int, in text: NSString) -> NSRange? {
        guard line >= 1 else { return nil }
        var current = 1
        var start = 0
        var index = 0
        let length = text.length
        while index < length {
            let unit = text.character(at: index)
            if unit == 0x0A || unit == 0x0D {
                if current == line { return NSRange(location: start, length: index - start) }
                if unit == 0x0D, index + 1 < length, text.character(at: index + 1) == 0x0A { index += 1 }
                current += 1
                start = index + 1
            }
            index += 1
        }
        return current == line ? NSRange(location: start, length: length - start) : nil
    }
}
