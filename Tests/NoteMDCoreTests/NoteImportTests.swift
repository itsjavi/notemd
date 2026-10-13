import Foundation
import Testing
@testable import NoteMDCore

@Suite struct NoteImportTests {
    private func makeFolders() throws -> (outside: URL, notes: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "notemd-import-\(UUID().uuidString)")
        let outside = root.appending(path: "Downloads")
        let notes = root.appending(path: "Vault/files")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        return (outside, notes)
    }

    @Test func recognizesMarkdownByExtension() {
        #expect(NoteImport.isMarkdown(URL(fileURLWithPath: "/tmp/a.md")))
        #expect(NoteImport.isMarkdown(URL(fileURLWithPath: "/tmp/b.MARKDOWN")))
        #expect(!NoteImport.isMarkdown(URL(fileURLWithPath: "/tmp/c.txt")))
    }

    @Test func copyKeepsTheOriginal() throws {
        let (outside, notes) = try makeFolders()
        defer { try? FileManager.default.removeItem(at: outside.deletingLastPathComponent()) }
        let source = outside.appending(path: "Plan.md")
        try "# Plan".write(to: source, atomically: true, encoding: .utf8)
        let target = try NoteImport.importFile(source, into: notes, move: false)
        #expect(target.lastPathComponent == "Plan.md")
        #expect(try String(contentsOf: target, encoding: .utf8) == "# Plan")
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func moveTakesTheFileAndNumbersClashes() throws {
        let (outside, notes) = try makeFolders()
        defer { try? FileManager.default.removeItem(at: outside.deletingLastPathComponent()) }
        try "existing".write(to: notes.appending(path: "Plan.md"), atomically: true, encoding: .utf8)
        let source = outside.appending(path: "Plan.md")
        try "# Plan".write(to: source, atomically: true, encoding: .utf8)
        let target = try NoteImport.importFile(source, into: notes, move: true)
        #expect(target.lastPathComponent == "Plan 2.md")
        #expect(try String(contentsOf: target, encoding: .utf8) == "# Plan")
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try String(contentsOf: notes.appending(path: "Plan.md"), encoding: .utf8) == "existing")
    }
}
