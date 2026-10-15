import Foundation
import Testing
@testable import NoteMDCore

@Suite struct NotesTests {
    private func makeRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notemd-tests-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("Work/Projects"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try "# Groceries\n\nMilk and **eggs**".write(to: root.appendingPathComponent("Groceries.md"), atomically: true, encoding: .utf8)
        try "---\ntitle: Plan Q4\ntags: [work, Planning]\n---\nRoadmap café items".write(to: root.appendingPathComponent("Work/plan.md"), atomically: true, encoding: .utf8)
        try "---\nparams:\n  - name: topic\n---\nWrite about {{topic}}".write(to: root.appendingPathComponent("Work/Projects/Prompt.markdown"), atomically: true, encoding: .utf8)
        try "ignored".write(to: root.appendingPathComponent("Work/readme.txt"), atomically: true, encoding: .utf8)
        try "hidden".write(to: root.appendingPathComponent(".hidden.md"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent(".git/HEAD.md"), atomically: true, encoding: .utf8)
        try FolderAppearance(icon: "briefcase.fill", color: .green).save(to: root.appendingPathComponent("Work"))
        return root
    }

    @Test func scanBuildsTreeAndNotes() throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try RepositoryScanner.scan(rootURL: root)
        #expect(Set(snapshot.notes.map(\.path)) == ["Groceries.md", "Work/plan.md", "Work/Projects/Prompt.markdown"])
        #expect(snapshot.root.children.map(\.name) == ["Work"])
        let work = try #require(snapshot.root.find("Work"))
        #expect(work.appearance == FolderAppearance(icon: "briefcase.fill", color: .green))
        #expect(work.noteCount == 1 && work.totalNoteCount == 2)
        #expect(snapshot.root.find("Work/Projects")?.noteCount == 1)
        let plan = try #require(snapshot.notes.first { $0.path == "Work/plan.md" })
        #expect(plan.title == "Plan Q4")
        #expect(plan.tags == ["work", "Planning"])
        #expect(plan.folderPath == "Work")
        let prompt = try #require(snapshot.notes.first { $0.path.hasSuffix("Prompt.markdown") })
        #expect(prompt.isTemplate)
        #expect(snapshot.allTags.map(\.tag) == ["Planning", "work"])
    }

    @Test func scanReusesUnchangedNotes() throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try RepositoryScanner.scan(rootURL: root)
        let cache = Dictionary(uniqueKeysWithValues: first.notes.map { ($0.path, $0) })
        let second = try RepositoryScanner.scan(rootURL: root, previous: cache)
        #expect(second.notes.count == first.notes.count)
    }

    @Test func folderAppearanceSaveMergesAndRemoves() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notemd-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(FolderAppearance.fileName)
        try #"{"custom": 1, "color": "nope"}"#.write(to: file, atomically: true, encoding: .utf8)
        #expect(FolderAppearance.load(from: folder) == FolderAppearance())
        try FolderAppearance(icon: "star.fill", color: .amber).save(to: folder)
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(saved == "{\n  \"color\" : \"amber\",\n  \"custom\" : 1,\n  \"icon\" : \"star.fill\"\n}\n")
        try FileManager.default.removeItem(at: file)
        try FolderAppearance().save(to: folder)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func hiddenFlagIsReadAndWrittenKeepingOtherKeys() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notemd-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(FolderAppearance.fileName)
        try #"{"custom": 1, "icon": "star.fill"}"#.write(to: file, atomically: true, encoding: .utf8)
        var appearance = FolderAppearance.load(from: folder)
        #expect(!appearance.hidden)
        appearance.hidden = true
        try appearance.save(to: folder)
        #expect(try String(contentsOf: file, encoding: .utf8) == "{\n  \"custom\" : 1,\n  \"hidden\" : true,\n  \"icon\" : \"star.fill\"\n}\n")
        #expect(FolderAppearance.load(from: folder) == FolderAppearance(icon: "star.fill", hidden: true))
        // A hidden folder without a style still has a file; showing it again drops the key.
        try FolderAppearance(hidden: true).save(to: folder)
        appearance = FolderAppearance.load(from: folder)
        #expect(appearance.hidden && appearance.isDefault)
        try FolderAppearance().save(to: folder)
        #expect(try String(contentsOf: file, encoding: .utf8) == "{\n  \"custom\" : 1\n}\n")
        try #"{"hidden": "yes"}"#.write(to: file, atomically: true, encoding: .utf8)
        #expect(!FolderAppearance.load(from: folder).hidden)
    }

    @Test func visibleTreeLeavesOutHiddenFoldersAndRecounts() throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try FolderAppearance(hidden: true).save(to: root.appendingPathComponent("Work/Projects"))
        let snapshot = try RepositoryScanner.scan(rootURL: root)
        #expect(snapshot.root.hiddenFolderPaths == ["Work/Projects"])
        #expect(Folder.path("Work/Projects/Prompt.markdown", isInside: snapshot.root.hiddenFolderPaths))
        #expect(Folder.path("Work/Projects", isInside: ["Work/Projects"]))
        #expect(!Folder.path("Work/Projects 2/a.md", isInside: ["Work/Projects"]))
        let shown = snapshot.notes.map(\.path).filter { !Folder.path($0, isInside: snapshot.root.hiddenFolderPaths) }
        let locked = snapshot.root.visibleTree(includingHidden: false, counting: shown)
        #expect(locked.find("Work/Projects") == nil)
        #expect(locked.find("Work")?.totalNoteCount == 1)
        #expect(locked.totalNoteCount == 2)
        let unlocked = snapshot.root.visibleTree(includingHidden: true, counting: snapshot.notes.map(\.path))
        #expect(unlocked.find("Work/Projects")?.isHidden == true)
        #expect(unlocked.find("Work")?.totalNoteCount == 2)
    }

    @Test func secretNotesAreListedByNameWithoutReading() throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        // Not valid age data: the scanner must not try to read it.
        try Data([0, 1, 2, 3]).write(to: root.appendingPathComponent("Work/Bank PINs.md.age"))
        let snapshot = try RepositoryScanner.scan(rootURL: root)
        let secret = try #require(snapshot.notes.first { $0.path == "Work/Bank PINs.md.age" })
        #expect(secret.isSecret && secret.title == "Bank PINs" && secret.baseName == "Bank PINs")
        #expect(secret.fileExtension == "md.age" && secret.body.isEmpty && secret.tags.isEmpty && !secret.isTemplate)
        #expect(snapshot.root.find("Work")?.noteCount == 2)
        #expect(NoteSearch.search(SearchQuery("bank"), in: snapshot.notes).map(\.note.path) == ["Work/Bank PINs.md.age"])
        #expect(NoteMDCore.isNotePath("a/B.MD.AGE") && NoteMDCore.isSecretNotePath("B.md.age") && !NoteMDCore.isSecretNotePath("B.age"))
        #expect(NoteFileName.baseName(of: "Plan.md") == "Plan" && NoteFileName.baseName(of: "x.md.age") == "x")
    }

    @Test func titles() {
        #expect(NoteTitle.derive(frontMatterTitle: nil, body: "```\n# not\n```\n# Real *one* #", fileName: "f") == "Real one")
        #expect(NoteTitle.derive(frontMatterTitle: " ", body: "no heading", fileName: "file") == "file")
        #expect(NoteTitle.excerpt(of: "# Title\n\n- [ ] Buy **milk**\n> quote [link](http://x)", skippingTitle: "Title") == "Buy milk quote link")
        #expect(NoteTitle.excerpt(of: "+[Voice note](assets/v.m4a) ![shot](a.png)", skippingTitle: "") == "Voice note shot")
    }

    @Test func fileNames() throws {
        #expect(NoteFileName.sanitized("  a/b: c  ") == "a-b- c")
        #expect(NoteFileName.sanitized("...") == "Untitled")
        #expect(NoteFileName.isUntitled("Untitled 3"))
        #expect(!NoteFileName.isUntitled("Untitled notes"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notemd-names-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "".write(to: dir.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)
        #expect(NoteFileName.uniqueURL(in: dir, base: "Note", pathExtension: "md").lastPathComponent == "Note 2.md")
    }

    @Test func search() throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = try RepositoryScanner.scan(rootURL: root).notes
        #expect(NoteSearch.search(SearchQuery("cafe"), in: notes).map(\.note.path) == ["Work/plan.md"])
        #expect(NoteSearch.search(SearchQuery("tag:planning"), in: notes).map(\.note.path) == ["Work/plan.md"])
        #expect(NoteSearch.search(SearchQuery("#work roadmap"), in: notes).count == 1)
        #expect(NoteSearch.search(SearchQuery("milk nope"), in: notes).isEmpty)
        let ranked = NoteSearch.search(SearchQuery("groceries"), in: notes)
        #expect(ranked.first?.note.path == "Groceries.md")
        let snippet = NoteSearch.search(SearchQuery("eggs"), in: notes).first?.snippet
        #expect(snippet?.contains("**eggs**") == true)
    }

    @Test func queryParsing() {
        let query = SearchQuery("\"exact phrase\" tag:Work #Ideas plain")
        #expect(query.terms == ["exact phrase", "plain"])
        #expect(query.tags == ["work", "ideas"])
    }

    @Test func tagNormalization() {
        #expect(Tag.normalizedList(["#a", " A ", "b  c", ""]) == ["a", "b c"])
    }
}

@Suite struct RoundTripAndFileTests {
    @Test func unchangedFrontMatterRoundTripsExactly() {
        for source in ["---\r\ntitle: A\r\n---\r\nBody\r\n", "---\ntitle: A\n...\nBody", "---\n---\nBody", "---\ntitle: A\n---  \nBody", "\u{FEFF}---\na: 1\n---\nx", "\u{FEFF}# Plain"] {
            #expect(MarkdownText(source).text == source)
        }
    }

    @Test func editedFrontMatterKeepsDelimiterStyle() {
        var text = MarkdownText("---\r\ntitle: A\r\n...\r\nBody")
        text.frontMatter?.setTags(["x"])
        #expect(text.text.hasPrefix("---\r\ntitle: A\r\n"))
        #expect(text.text.hasSuffix("...\r\nBody"))
        #expect(!text.text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    @Test func aliasKeysAreReplaced() {
        var frontMatter = FrontMatter(yaml: "tag: [old]\nparameters:\n  - name: a\n")
        frontMatter.setTags([])
        frontMatter.setParameters([])
        #expect(frontMatter.tags.isEmpty)
        #expect(frontMatter.parameters.isEmpty)
        #expect(frontMatter.yaml.isEmpty)
    }

    @Test func datesAreNotShifted() {
        let frontMatter = FrontMatter(yaml: "title: 2024-03-15\nparams:\n  - {name: d, type: date, default: 2024-03-15}\n")
        #expect(frontMatter.title == "2024-03-15")
        guard case .date(let date) = frontMatter.parameters.first?.defaultValue else {
            Issue.record("expected a date default")
            return
        }
        #expect(ISO8601DateFormatter.dateOnly.string(from: date) == "2024-03-15")
    }

    @Test func crlfTitlesAndTemplates() {
        #expect(NoteTitle.firstHeading(in: "# Title\r\n\r\nBody") == "Title")
        let renderer = TemplateRenderer(values: ["a": .bool(true)])
        #expect(renderer.render("x\r\n{{#if a}}\r\ny\r\n{{/if}}\r\nz") == "x\r\ny\r\nz")
    }

    @Test func safeWriterKeepsCreationDate() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notemd-write-\(UUID().uuidString).md")
        try Data("one".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: url.path)
        try SafeFileWriter.write(Data("two".utf8), to: url)
        let values = try url.resourceValues(forKeys: [.creationDateKey])
        #expect(values.creationDate == Date(timeIntervalSince1970: 1_000_000))
        #expect(try String(contentsOf: url, encoding: .utf8) == "two")
    }

    @Test func safeWriterCreatesNewFiles() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notemd-new-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        try SafeFileWriter.write(Data("new".utf8), to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "new")
    }

    @Test func safeRelativePaths() {
        #expect(SafeFileWriter.isSafeRelativePath("Work/Plan.md"))
        #expect(SafeFileWriter.isSafeRelativePath(""))
        #expect(!SafeFileWriter.isSafeRelativePath("../x"))
        #expect(!SafeFileWriter.isSafeRelativePath("a/../../b"))
        #expect(!SafeFileWriter.isSafeRelativePath("/etc"))
        #expect(!SafeFileWriter.isSafeRelativePath(".git/config"))
    }

    @Test func canonicalKeepsPrivatePrefix() {
        #expect(URL(fileURLWithPath: "/tmp").canonical.path == "/private/tmp")
        #expect(URL(fileURLWithPath: "/tmp/notemd-missing-\(UUID().uuidString)").canonical.path.hasPrefix("/private/tmp/"))
    }
}
