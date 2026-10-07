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

    @Test func mediaEmbedsBecomePlayers() {
        let audio = render("+[Voice *note*](../assets/voice%201.m4a)")
        #expect(audio.contains("<span class=\"media-embed media-audio\"><audio controls preload=\"metadata\" src=\"../assets/voice%201.m4a\"></audio>"))
        #expect(audio.contains("<span class=\"media-caption\">Voice note</span>"))
        #expect(!audio.contains("+"))
        #expect(!audio.contains("Transcribe"))

        let video = render("Clip: +[demo](clip.MOV?t=1) end")
        #expect(video.contains("<p>Clip: <span class=\"media-embed media-video\"><video controls preload=\"metadata\" src=\"clip.MOV?t=1#t=0.001\"></video>"))
        #expect(video.contains("</span></span> end</p>"))
    }

    @Test func transcribeLinksOnlyForAudio() {
        let options = MarkdownRenderer.Options(sourcePositions: false, transcribeLinks: true)
        #expect(render("+[a](a b.m4a)", options) == "<p>+[a](a b.m4a)</p>\n")  // spaces need %20: not a link
        #expect(render("+[a](a%20b.m4a)", options).contains("href=\"notemd-action:transcribe?src=a%2520b%2Em4a\">Transcribe</a>"))
        #expect(!render("+[v](v.mp4)", options).contains("Transcribe"))
    }

    @Test func otherPlusLinksStayLinks() {
        #expect(render("+[doc](file.pdf)") == "<p><a href=\"file.pdf\">doc</a></p>\n")
        #expect(render("![img](a.png) [song](a.mp3)") == "<p><img src=\"a.png\" alt=\"img\" /> <a href=\"a.mp3\">song</a></p>\n")
        #expect(render("\\+[song](a.mp3)") == "<p>+<a href=\"a.mp3\">song</a></p>\n")
        #expect(render("1+[song](a.mp3)").contains("<p>1<span class=\"media-embed media-audio\">"))
    }

    @Test func linkDestinations() {
        let markdown = "---\ntitle: x\n---\n[a](/Users/me/a.pdf) ![b](assets/b.png) +[c](<c d.m4a>)"
        #expect(MarkdownRenderer.linkDestinations(in: markdown) == ["/Users/me/a.pdf", "c d.m4a", "assets/b.png"])
    }
}
