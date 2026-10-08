import SwiftUI

/// Reference for the template syntax, shown from the Template Parameters sheet.
struct TemplateGuideView: View {
    private struct Topic: Identifiable {
        var title: String
        var code: String
        var detail: String
        var id: String { title }
    }

    private let topics = [
        Topic(
            title: "Placeholders",
            code: "{{name}}  {{@today}}  {{@now}}",
            detail: "Inserts a parameter's value. Lists join with commas, dates use the parameter's format."
        ),
        Topic(
            title: "Conditions",
            code: "{{#if name}}…{{else}}…{{/if}}\n{{#unless name}}…{{/unless}}",
            detail: "#if shows its content when the value is set: text that isn't empty, a toggle that is on, a list with items. #unless is the opposite."
        ),
        Topic(
            title: "Comparisons",
            code: "{{#if status == \"done\"}}…{{/if}}\n{{#if status != draft}}…{{/if}}\n{{#if max >= 10}}…{{/if}}",
            detail: "Compare with a value: == and !=, plus <, <=, > and >= for numbers. Quotes are only needed for values with spaces. For a multiple choice, == checks whether that option is picked."
        ),
        Topic(
            title: "Else if",
            code: "{{#if size == S}}small\n{{#elseif size == M}}medium\n{{else}}large{{/if}}",
            detail: "Chain more conditions in one block. The first one that matches wins."
        ),
        Topic(
            title: "Loops",
            code: "{{#each files}}{{@index}}. {{.}}\n{{else}}No files{{/each}}",
            detail: "Repeats for each list item. {{.}} is the item and {{@index}} its position, starting at 1."
        ),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Template Syntax").font(.headline)
                ForEach(topics) { topic in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(topic.title).font(.subheadline.weight(.semibold))
                        Text(topic.code)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.6)))
                        Text(topic.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("A block tag alone on its line leaves no blank line behind.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .frame(width: 400, height: 520)
    }
}
