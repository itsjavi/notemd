import Testing
@testable import NoteMDCore

@Suite struct MarkdownRendererTests {
    private func render(_ markdown: String, _ options: MarkdownRenderer.Options = .init(sourcePositions: false)) -> String {
        MarkdownRenderer.html(from: markdown, options: options)
    }

    @Test func gfmExtensions() {
        let html = render("""
        | a | b |
        |---|---|
        | 1 | 2 |

        - [x] done
        - [ ] todo

        ~~gone~~ https://example.com
        """)
        #expect(html.contains("<table>"))
        #expect(html.contains("checked=\"\" disabled=\"\""))
        #expect(html.contains("<del>gone</del>"))
        #expect(html.contains("<a href=\"https://example.com\">"))
    }

    @Test func footnotes() {
        let html = render("Text[^1]\n\n[^1]: Note")
        #expect(html.contains("footnote"))
    }

    @Test func dangerousTagsFiltered() {
        let html = render("<script>alert(1)</script>\n\n<details><summary>S</summary>ok</details>")
        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;script>"))
        #expect(html.contains("<details>"))
    }

    @Test func alerts() {
        let html = render("> [!WARNING]\n> Be careful\n\n> [!NOTE] inline is not an alert\n\n> plain quote")
        #expect(html.contains("<div class=\"markdown-alert markdown-alert-warning\"><p class=\"markdown-alert-title\">Warning</p>"))
        #expect(html.contains("Be careful"))
        #expect(!html.contains("[!WARNING]"))
        #expect(html.contains("<blockquote>\n<p>[!NOTE] inline"))
        #expect(html.contains("<blockquote>\n<p>plain quote"))
    }

    @Test func frontMatterHiddenOrTable() {
        let source = "---\ntitle: T\ntags: [a, b]\n---\n# Body"
        #expect(!render(source).contains("title"))
        let table = render(source, .init(frontMatter: .table, sourcePositions: false))
        #expect(table.contains("<th>title</th>"))
        #expect(table.contains("<td>a, b</td>"))
    }

    @Test func sourcePositionsAccountForFrontMatter() {
        let html = MarkdownRenderer.html(from: "---\na: 1\n---\n# Heading", options: .init(sourcePositions: true))
        #expect(html.contains("data-sourcepos=\"4:1-4:9\""))
    }

    @Test func codeLanguage() {
        #expect(render("```swift\nlet x = 1\n```").contains("<pre lang=\"swift\"><code>"))
    }
}
