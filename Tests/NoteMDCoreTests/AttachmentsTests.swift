import Foundation
import Testing

@testable import NoteMDCore

@Suite struct AttachmentsTests {
    @Test func kindsFromExtensions() {
        #expect(AttachmentKind(pathExtension: "PNG") == .image)
        #expect(AttachmentKind(pathExtension: "m4a") == .audio)
        #expect(AttachmentKind(pathExtension: "mov") == .video)
        #expect(AttachmentKind(pathExtension: "pdf") == .file)
        #expect(AttachmentKind(destination: "clip.mp4#t=3") == .video)
    }

    @Test func markdownLinks() {
        let destination = Attachments.encodeDestination("../assets/My shot (1).png")
        #expect(destination == "../assets/My%20shot%20%281%29.png")
        #expect(Attachments.markdownLink(name: "My [shot]", destination: destination, kind: .image) == "![My \\[shot\\]](\(destination))")
        #expect(Attachments.markdownLink(name: "Voice", destination: "assets/v.m4a", kind: .audio) == "+[Voice](assets/v.m4a)")
        #expect(Attachments.markdownLink(name: "Doc", destination: "assets/d.pdf", kind: .file) == "[Doc](assets/d.pdf)")
    }

    @Test func relativePaths() {
        #expect(Attachments.relativePath(fromDirectory: "", to: "assets/a.png") == "assets/a.png")
        #expect(Attachments.relativePath(fromDirectory: "Work/Projects", to: "assets/a.png") == "../../assets/a.png")
        #expect(Attachments.relativePath(fromDirectory: "assets", to: "assets/a.png") == "a.png")
        #expect(Attachments.relativePath(fromDirectory: "Work", to: "Work/notes/a.png") == "notes/a.png")
    }

    @Test func uniqueNamesAddSuffixBeforeExtension() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "notemd-attachments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(Attachments.uniqueURL(in: directory, fileName: "shot.png").lastPathComponent == "shot.png")
        try Data().write(to: directory.appending(path: "shot.png"))
        try Data().write(to: directory.appending(path: "shot-2.png"))
        #expect(Attachments.uniqueURL(in: directory, fileName: "shot.png").lastPathComponent == "shot-3.png")
    }

    @Test func rootAssetsFolderIsNotANoteFolder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "notemd-assets-scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["assets/readme.md", "Work/assets/kept.md", "note.md"] {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("# x".utf8).write(to: url)
        }
        let snapshot = try RepositoryScanner.scan(rootURL: root)
        #expect(snapshot.root.children.map(\.name) == ["Work"])
        #expect(Set(snapshot.notes.map(\.path)) == ["note.md", "Work/assets/kept.md"])
    }

    @Test func textDetection() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "notemd-text-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files: [(String, Data, Bool)] = [
            (".env.example", Data("KEY=value\n".utf8), true),
            ("Makefile", Data("all:\n".utf8), true),
            ("blob.example", Data([0x00, 0x01, 0x02]), false),
            ("utf16.txt", Data([0xFF, 0xFE, 0x41, 0x00]), true),
            ("shot.png", Data("not really a png".utf8), false),
            ("notes.md", Data("# x".utf8), true),
        ]
        for (name, data, isText) in files {
            let url = directory.appending(path: name)
            try data.write(to: url)
            #expect(TextDetection.isText(at: url) == isText, "\(name)")
        }
    }

    @Test func insertionHelpers() {
        let text = "Intro\n+[Clip](../assets/my%20clip.m4a)\nAfter"
        #expect(Attachments.ownLine("X", in: text, at: 0) == "X\n")
        #expect(Attachments.ownLine("X", in: text, at: 2) == "\nX\n")
        #expect(Attachments.ownLine("X", in: text, at: 5) == "\nX")
        #expect(Attachments.ownLine("X", in: "", at: 0) == "X\n")
        let end = Attachments.endOfLine(linking: "../assets/my%20clip.m4a", in: text)
        #expect((text as NSString).substring(to: end) == "Intro\n+[Clip](../assets/my%20clip.m4a)")
        #expect(Attachments.endOfLine(linking: "missing.m4a", in: text) == (text as NSString).length)
        #expect(Attachments.quote("one\ntwo") == "> one\n> two")
        let directory = URL(fileURLWithPath: "/repo/Work")
        #expect(Attachments.fileURL(forDestination: "../assets/my%20clip.m4a", relativeTo: directory)?.path == "/repo/assets/my clip.m4a")
        #expect(Attachments.fileURL(forDestination: "/Users/me/a.m4a", relativeTo: directory)?.path == "/Users/me/a.m4a")
        #expect(Attachments.fileURL(forDestination: "https://x.com/a.m4a", relativeTo: directory) == nil)
    }

    @Test func findsEmbedsByFileName() throws {
        let text = "# T\n\nSee +[Recording…](../assets/voice-1.m4a) here\n+[Rec \\[x\\]](<assets/voice 2.m4a>)\nend"
        let ns = text as NSString
        let first = try #require(Attachments.embedRanges(linkingFileNamed: "voice-1.m4a", in: text))
        #expect(ns.substring(with: first.label) == "Recording…")
        #expect(ns.substring(with: Attachments.removalRange(of: first.embed, in: text)) == "+[Recording…](../assets/voice-1.m4a)")
        let second = try #require(Attachments.embedRanges(linkingFileNamed: "voice 2.m4a", in: text))
        #expect(ns.substring(with: second.label) == "Rec \\[x\\]")
        #expect(ns.substring(with: Attachments.removalRange(of: second.embed, in: text)) == "+[Rec \\[x\\]](<assets/voice 2.m4a>)\n")
        #expect(Attachments.embedRanges(linkingFileNamed: "voice-3.m4a", in: text) == nil)
    }

    @Test func timestampedNames() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 9, minute: 5, second: 3))!
        #expect(Attachments.timestampedName(prefix: "voice", pathExtension: "m4a", date: date) == "voice-2026-10-07-090503.m4a")
    }

    @Test func movingNotesRewritesAssetLinksOnly() {
        let text = """
        ![a](assets/a%20b.png) +[v](<assets/my clip.m4a>) [doc](../other.md)
        [web](https://example.com/assets/x.png) [abs](/Users/me/assets/x.png) [up](../assets/escape.png)
        """
        let moved = Attachments.rewritingAssetLinks(in: text, fromDirectory: "", toDirectory: "Work/Projects")
        #expect(moved == """
        ![a](../../assets/a%20b.png) +[v](<../../assets/my clip.m4a>) [doc](../other.md)
        [web](https://example.com/assets/x.png) [abs](/Users/me/assets/x.png) [up](../assets/escape.png)
        """)
        #expect(Attachments.rewritingAssetLinks(in: moved, fromDirectory: "Work/Projects", toDirectory: "") == """
        ![a](assets/a%20b.png) +[v](<assets/my clip.m4a>) [doc](../other.md)
        [web](https://example.com/assets/x.png) [abs](/Users/me/assets/x.png) [up](../assets/escape.png)
        """)
        #expect(Attachments.rewritingAssetLinks(in: "[a](assets/a.png)", fromDirectory: "A", toDirectory: "B") == "[a](assets/a.png)")
    }
}
