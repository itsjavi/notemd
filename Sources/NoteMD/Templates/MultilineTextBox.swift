import AppKit
import SwiftUI

/// A text box for multi-line values. Return inserts a line break (a vertical `TextField` submits instead),
/// the box grows with its lines up to `lines.upperBound` and shows `prompt` while empty.
///
/// Sheets that give Return to a default button should move it to ⌘↩ while `focus` is set.
struct MultilineTextBox: View {
    @Binding var text: String
    var prompt: String
    var lines: ClosedRange<Int>
    var focus: FocusState<String?>.Binding
    var focusID: String

    private static let lineHeight = NSLayoutManager().defaultLineHeight(for: .preferredFont(forTextStyle: .body))

    var body: some View {
        let count = min(max(text.components(separatedBy: "\n").count, lines.lowerBound), lines.upperBound)
        let isFocused = focus.wrappedValue == focusID
        TextEditor(text: $text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .focused(focus, equals: focusID)
            .padding(.vertical, 5)
            .padding(.horizontal, 3)
            .frame(height: CGFloat(count) * Self.lineHeight + 10)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isFocused ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isFocused ? 2 : 1)
            }
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(prompt)
                        .foregroundStyle(.placeholder)
                        .padding(.leading, 8)
                        .padding(.top, 5)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// Edits a list as one item per line. The typed text is kept while editing, so blank lines and the line Return
/// just started survive; the bound items are the trimmed, non-blank lines.
struct ListTextBox: View {
    @Binding var items: [String]
    var prompt: String
    var lines: ClosedRange<Int>
    var focus: FocusState<String?>.Binding
    var focusID: String
    @State private var text: String?

    var body: some View {
        MultilineTextBox(
            text: Binding(
                get: { text ?? items.joined(separator: "\n") },
                set: { text = $0; items = Self.items(in: $0) }
            ),
            prompt: prompt, lines: lines, focus: focus, focusID: focusID
        )
        .onChange(of: items) { _, newItems in
            // A reset or restored value replaces what was typed.
            if let text, Self.items(in: text) != newItems { self.text = nil }
        }
    }

    static func items(in text: String) -> [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
