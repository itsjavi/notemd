import Foundation
import Testing

@testable import NoteMDCore

@Suite struct AssetReferencesTests {
    private let root = "/Users/me/Notes"

    private func links(_ body: String, note: String = "Note.md", root: String? = nil) -> [AssetLink] {
        AssetReferences.links(in: body, notePath: note, rootPath: root ?? self.root)
    }

    private func locations(_ body: String, note: String = "Note.md", root: String? = nil) -> [AssetLink.Location] {
        links(body, note: note, root: root).map(\.location)
    }

    private func unlink(_ asset: String, _ body: String, note: String = "Note.md") -> String {
        AssetReferences.unlinking(asset, in: body, notePath: note, rootPath: root)
    }

    private func rename(_ old: String, _ new: String, _ body: String, note: String = "Note.md") -> String {
        AssetReferences.renaming(old, to: new, in: body, notePath: note, rootPath: root)
    }

    // MARK: Links

    @Test func relativePathVariants() {
        #expect(locations("![a](assets/a.png) ![b](./assets/b.png) ![c](../assets/c.png) ![d](sub/../d.png)", note: "Work/Plan.md") == [
            .repository(path: "Work/assets/a.png"), .repository(path: "Work/assets/b.png"),
            .repository(path: "assets/c.png"), .repository(path: "Work/d.png"),
        ])
        #expect(locations("![x](../../assets/x.png)", note: "Work/Deep/n.md") == [.repository(path: "assets/x.png")])
        #expect(locations("![x](assets/x.png)") == [.repository(path: "assets/x.png")])
        // Climbing above the root leaves the repository.
        #expect(locations("[o](../outside.pdf)") == [.external(path: "/Users/me/outside.pdf")])
        #expect(locations("[o](../Notes/assets/back.pdf)") == [.repository(path: "assets/back.pdf")])
    }

    @Test func encodedBracketedAndEscapedDestinations() {
        let body = """
            ![s](../assets/My%20shot%20%281%29.png)
            +[v](<../assets/voice memo.m4a>)
            [doc](../assets/d.pdf#page=2) ![i](../assets/i.png?v=1 "Title")
            ![e](../assets/a\\_b.png) ![amp](../assets/a&amp;b.png)
            """
        let found = links(body, note: "Work/n.md")
        #expect(found.map(\.location) == [
            .repository(path: "assets/My shot (1).png"), .repository(path: "assets/voice memo.m4a"),
            .repository(path: "assets/d.pdf"), .repository(path: "assets/i.png"),
            .repository(path: "assets/a_b.png"), .repository(path: "assets/a&b.png"),
        ])
        #expect(found.map(\.destination).prefix(3) == ["../assets/My%20shot%20%281%29.png", "../assets/voice memo.m4a", "../assets/d.pdf#page=2"])
    }

    @Test func codeHtmlAndEscapesAreIgnored() {
        let body = """
            `![x](assets/inline.png)` and ``[y](assets/double.pdf)``

            ```
            ![y](assets/fenced.png)
            ```

                ![z](assets/indented.png)

            ~~~md
            [w](assets/tilde.pdf)
            ~~~

            <div>
            ![h](assets/html.png)
            </div>

            \\[not a link](assets/escaped.png)

            ![real](assets/real.png) and `![real](assets/real.png)`
            """
        #expect(locations(body) == [.repository(path: "assets/real.png")])
    }

    @Test func referenceDefinitionsAndUses() {
        let body = """
            ![Logo][logo] and [the report][r] and [Spec][] and [spec]

            [logo]: ../assets/logo.png "Logo"
            [r]: <../assets/q3 report.pdf>
            [spec]:
              ../assets/spec.pdf
            > [quoted]: ../assets/quoted.png
            [unused]: ../assets/unused.zip
            [logo]: ../assets/second-definition-is-ignored.png
            [^1]: ../assets/footnote.png
            [web]: https://example.com

            ```
            [code]: ../assets/code.png
            ```
            """
        #expect(locations(body, note: "Work/n.md") == [
            .repository(path: "assets/logo.png"), .repository(path: "assets/q3 report.pdf"),
            .repository(path: "assets/spec.pdf"), .repository(path: "assets/quoted.png"),
            .repository(path: "assets/unused.zip"),
        ])
    }

    @Test func embeds() {
        #expect(links("Listen: +[Voice](assets/voice.m4a)\n\n+[Clip](<assets/my clip.mov>)") == [
            AssetLink(destination: "assets/voice.m4a", location: .repository(path: "assets/voice.m4a")),
            AssetLink(destination: "assets/my clip.mov", location: .repository(path: "assets/my clip.mov")),
        ])
    }

    @Test func absolutePathsAndFileURLs() {
        let body = """
            ![a](/Users/me/Notes/assets/a.png)
            [b](/Users/me/Documents/b.pdf)
            ![c](file:///Users/me/Notes/assets/c%20d.png)
            [e](file:///tmp/e.pdf)
            [f](file://localhost/Users/me/Notes/f.txt)
            [g](file://server/share/g.pdf)
            [h](~/Downloads/h.zip)
            [i](/Users/me/Notes/../Other/i.pdf)
            [root](/Users/me/Notes)
            """
        #expect(locations(body) == [
            .repository(path: "assets/a.png"), .external(path: "/Users/me/Documents/b.pdf"),
            .repository(path: "assets/c d.png"), .external(path: "/tmp/e.pdf"), .repository(path: "f.txt"),
            .external(path: NSHomeDirectory() + "/Downloads/h.zip"), .external(path: "/Users/me/Other/i.pdf"),
        ])
        // /tmp and /private/tmp name the same folder.
        #expect(locations("![a](/tmp/repo/assets/a.png)", root: "/private/tmp/repo") == [.repository(path: "assets/a.png")])
        #expect(locations("![a](/private/tmp/repo/assets/a.png)", root: "/tmp/repo/") == [.repository(path: "assets/a.png")])
    }

    @Test func webURLsAnchorsFoldersAndNotesAreNotAttachments() {
        let body = """
            [a](https://x.com/a.png) ![b](http://x/b.png) [m](mailto:me@x.com) ![d](data:image/png;base64,AAA)
            [h](#heading) ![cdn](//cdn.x/c.png) [act](notemd-action:transcribe?src=x) [folder](assets/)
            [Plan](Plan.md) [Other](../Other/Note.markdown#h) [Index](/Users/me/Notes/Index.MD) [Ext](/Users/me/x.md)
            """
        #expect(links(body, note: "Work/n.md").isEmpty)
        #expect(locations("[t](notes.txt)") == [.repository(path: "notes.txt")])
        #expect(AssetReferences.location(of: "<../assets/a b.png>", notePath: "Work/n.md", rootPath: root) == .repository(path: "assets/a b.png"))
        #expect(AssetReferences.location(of: "https://x.com", notePath: "n.md", rootPath: root) == nil)
    }

    @Test func frontMatterIsSkipped() {
        #expect(locations("---\ntitle: x\n---\n![a](assets/a.png)") == [.repository(path: "assets/a.png")])
    }

    @Test func identicalLinksAreListedOnce() {
        #expect(links("![a](assets/a.png) ![b](assets/a.png) ![c](./assets/a.png)").map(\.destination) == ["assets/a.png", "./assets/a.png"])
    }

    // MARK: Index

    @Test func indexSkipsUnchangedBodies() {
        var index = AssetReferenceIndex()
        let body = "![x](assets/x.png) [y](assets/y.pdf)"
        index.update(notePath: "a.md", body: body, rootPath: root)
        index.update(notePath: "a.md", body: body, rootPath: root)
        #expect(index.parseCount == 1)
        index.update(notePath: "a.md", body: body + " more", rootPath: root)
        #expect(index.parseCount == 2)
        index.update(notePath: "a.md", body: body + " more", rootPath: "/Users/me/Other")
        #expect(index.parseCount == 3)
        #expect(index.links(of: "a.md").map(\.location) == [.repository(path: "assets/x.png"), .repository(path: "assets/y.pdf")])
    }

    @Test func indexMapsAssetsToNotesAndAttachments() {
        var index = AssetReferenceIndex()
        index.update(notePath: "a.md", body: "![x](assets/x.png) [y](assets/y.pdf)", rootPath: root)
        index.update(
            notePath: "Work/b.md",
            body: "![x](../assets/x.png) ![m](../assets/missing.png) [e](/tmp/e.pdf) ![again](./../assets/x.png)",
            rootPath: root)
        index.update(notePath: "Templates/t.md", body: "Plain text", rootPath: root)
        #expect(index.notes(referencing: "assets/x.png") == ["Work/b.md", "a.md"])
        #expect(index.notes(referencing: "assets/nothing.png").isEmpty)
        #expect(index.referencedPaths == ["assets/x.png", "assets/y.pdf", "assets/missing.png"])
        #expect(index.links(of: "Work/b.md").count == 4)
        let attachments = index.attachments(of: "Work/b.md") { $0 != "assets/missing.png" }
        #expect(attachments.map(\.status) == [.found, .missing, .external])
        #expect(attachments.map(\.link.destination) == ["../assets/x.png", "../assets/missing.png", "/tmp/e.pdf"])

        index.update(notePath: "a.md", body: "![x](assets/x.png)", rootPath: root)
        #expect(index.notes(referencing: "assets/y.pdf").isEmpty)
        #expect(!index.referencedPaths.contains("assets/y.pdf"))

        index.remove(notePath: "Work/b.md")
        #expect(index.notes(referencing: "assets/x.png") == ["a.md"])
        #expect(index.attachments(of: "Work/b.md") { _ in true }.isEmpty)

        index.update(notePath: "c.md", body: "![x](assets/x.png)", rootPath: root)
        index.retain(notePaths: ["c.md"])
        #expect(index.notes(referencing: "assets/x.png") == ["c.md"])
        #expect(index.links(of: "a.md").isEmpty)
        index.retain(notePaths: [])
        #expect(index.referencedPaths.isEmpty)
    }

    // MARK: Unlinking

    @Test func unlinkRemovesStandaloneLines() {
        #expect(unlink("assets/shot.png", "# Title\n\nIntro\n\n![Shot](assets/shot.png)\n\nMore text\n") == "# Title\n\nIntro\n\nMore text\n")
        #expect(unlink("assets/v.m4a", "Notes\n+[Voice](assets/v.m4a)\nAfter") == "Notes\nAfter")
        #expect(unlink("assets/v.m4a", "Text\n\n+[Voice](<assets/v.m4a>)") == "Text\n")
        #expect(unlink("assets/a.png", "- ![a](assets/a.png)\n- Item\n") == "- Item\n")
        #expect(unlink("assets/a.png", "> Quote\n> ![a](assets/a.png)\n") == "> Quote\n")
        #expect(unlink("assets/a.png", "![a](assets/a.png)") == "")
    }

    @Test func unlinkRemovesInlineImagesAndKeepsLinkLabels() {
        #expect(unlink("assets/a.png", "See ![a](assets/a.png) here.") == "See here.")
        #expect(unlink("assets/a.png", "Trailing ![a](assets/a.png)\nNext") == "Trailing\nNext")
        #expect(unlink("assets/a.png", "![a](assets/a.png) leading") == "leading")
        #expect(unlink("assets/r.pdf", "Read [the **report**](assets/r.pdf \"T\") today.") == "Read the **report** today.")
        #expect(unlink("assets/r.pdf", "[Report](assets/r.pdf)\n") == "Report\n")
        // A badge: the image is the link's whole label.
        #expect(unlink("assets/badge.svg", "[![build](assets/badge.svg)](https://ci.example.com) Project") == "Project")
        // A link kept as its label still loses the image inside it.
        #expect(unlink("assets/a.png", "[![a](assets/a.png) caption](assets/a.png)") == "caption")
    }

    @Test func unlinkHandlesEveryOccurrenceAndStyle() {
        let body = "![a](../assets/a.png) ![b](<../assets/a.png>)\nText [a](/Users/me/Notes/assets/a.png) and [b](https://x.com)"
        #expect(unlink("assets/a.png", body, note: "Work/n.md") == "Text a and [b](https://x.com)")
    }

    @Test func unlinkReferenceDefinitions() {
        let body = """
            ![Logo][logo]
            See [the spec][s], [s][] and [s].

            [logo]: assets/logo.png
            [s]: assets/spec.pdf "Spec"
            [keep]: assets/keep.pdf
            """
        #expect(unlink("assets/spec.pdf", body) == """
            ![Logo][logo]
            See the spec, s and s.

            [logo]: assets/logo.png
            [keep]: assets/keep.pdf
            """)
        #expect(unlink("assets/logo.png", body) == """
            See [the spec][s], [s][] and [s].

            [s]: assets/spec.pdf "Spec"
            [keep]: assets/keep.pdf
            """)
    }

    @Test func unlinkNeverEditsCode() {
        let body = "![a](assets/a.png)\n\n`![a](assets/a.png)`\n\n```\n![a](assets/a.png)\n[a]: assets/a.png\n```\n"
        #expect(unlink("assets/a.png", body) == "`![a](assets/a.png)`\n\n```\n![a](assets/a.png)\n[a]: assets/a.png\n```\n")
        #expect(unlink("assets/a.png", "`![a](assets/a.png)`") == "`![a](assets/a.png)`")
    }

    @Test func unlinkEdgeLayouts() {
        // The code span keeps its copy; only the real link goes.
        #expect(unlink("assets/a.png", "`![a](assets/a.png)` ![a](assets/a.png)") == "`![a](assets/a.png)`")
        #expect(unlink("assets/a.png", "Intro\r\n![a](assets/a.png)\r\nEnd\r\n") == "Intro\r\nEnd\r\n")
        #expect(unlink("assets/a.png", "| A | B |\n|---|---|\n| ![a](assets/a.png) | x |\n") == "| A | B |\n|---|---|\n| | x |\n")
        #expect(unlink("assets/a.png", "- item\n  more ![a](assets/a.png) text\n  ![a](assets/a.png)\n- next") == "- item\n  more text\n- next")
    }

    @Test func unlinkKeepsFrontMatterAndUnrelatedText() {
        #expect(unlink("assets/a.png", "---\nimage: assets/a.png\n---\n![a](assets/a.png)\nBody") == "---\nimage: assets/a.png\n---\nBody")
        let untouched = "![b](assets/b.png) [c](assets/c.pdf)"
        #expect(unlink("assets/a.png", untouched) == untouched)
    }

    // MARK: Renaming

    @Test func renameRewritesRelativeLinksFromSubfolders() {
        let note = "Work/Deep/n.md"
        #expect(rename("assets/old.png", "assets/new name.png", "![a](../../assets/old.png)", note: note) == "![a](../../assets/new%20name.png)")
        #expect(rename("assets/old.png", "assets/new name.png", "+[v](<../../assets/old.png>)", note: note) == "+[v](<../../assets/new name.png>)")
        #expect(rename("assets/old.pdf", "assets/new.pdf", "[d](../../assets/old.pdf#page=2)", note: note) == "[d](../../assets/new.pdf#page=2)")
        #expect(rename("assets/old.png", "Work/img/old.png", "![a](../assets/old.png)", note: "Work/n.md") == "![a](img/old.png)")
        #expect(rename("assets/old.png", "assets/new.png", "![a](./assets/old.png)") == "![a](./assets/new.png)")
    }

    @Test func renameKeepsEncodingStyle() {
        let note = "Work/n.md"
        #expect(rename("assets/old one.png", "assets/café.png", "![a](../assets/old%20one.png)", note: note) == "![a](../assets/caf%C3%A9.png)")
        #expect(rename("assets/naïve.png", "assets/über (2).png", "![a](../assets/naïve.png)", note: note) == "![a](../assets/über%20%282%29.png)")
    }

    @Test func renameAbsoluteLinksDefinitionsAndEveryOccurrence() {
        let body = """
            [d](/Users/me/Notes/assets/old.pdf) [f](file:///Users/me/Notes/assets/old.pdf) [r][r] [w](https://x.com/old.pdf)
            `[c](assets/old.pdf)`

            [r]: assets/old.pdf "T"
            """
        #expect(rename("assets/old.pdf", "assets/sub/new file.pdf", body) == """
            [d](/Users/me/Notes/assets/sub/new%20file.pdf) [f](file:///Users/me/Notes/assets/sub/new%20file.pdf) [r][r] [w](https://x.com/old.pdf)
            `[c](assets/old.pdf)`

            [r]: assets/sub/new%20file.pdf "T"
            """)
        let untouched = "![b](assets/b.png)"
        #expect(rename("assets/old.png", "assets/new.png", untouched) == untouched)
    }
}
