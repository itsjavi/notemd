import Foundation
import Testing

@testable import NoteMDCore

@Suite struct RepositoryLayoutTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "notemd-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func mapsPathsBetweenNotesAndGit() {
        let files = RepositoryLayout(contentFolder: "files")
        #expect(files.repositoryPath(forContentPath: "Work/a.md") == "files/Work/a.md")
        #expect(files.repositoryPath(forContentPath: "") == "files")
        #expect(files.contentPath(forRepositoryPath: "files/Work/a.md") == "Work/a.md")
        #expect(files.contentPath(forRepositoryPath: "Files/a.md") == "a.md")
        // From before the move into files/.
        #expect(files.contentPath(forRepositoryPath: "assets/x.png") == "assets/x.png")
        #expect(files.contentPath(forRepositoryPath: ".gitignore") == nil)
        #expect(files.contentPath(forRepositoryPath: ".incognito/a.md") == nil)
        #expect(RepositoryLayout.root.repositoryPath(forContentPath: "a.md") == "a.md")
        #expect(RepositoryLayout.root.contentPath(forRepositoryPath: "a.md") == "a.md")
    }

    @Test func movesRootEntriesIntoFiles() throws {
        let root = try makeRoot()
        try write("# A", to: root.appending(path: "a.md"))
        try write("# B", to: root.appending(path: "Work/b.md"))
        try write("png", to: root.appending(path: "assets/x.png"))
        try write(#"{"color":"green"}"#, to: root.appending(path: ".notemd.json"))
        try write(".DS_Store\n", to: root.appending(path: ".gitignore"))
        try FileManager.default.createDirectory(at: root.appending(path: ".git"), withIntermediateDirectories: true)

        #expect(RepositoryLayout.existing(at: root) == .root)
        let strays = RepositoryLayout.strayEntries(at: root).map(\.lastPathComponent)
        #expect(strays == [".notemd.json", "Work", "a.md", "assets"])

        let layout = try RepositoryLayout.moveIntoNotesFolder(RepositoryLayout.strayEntries(at: root), at: root)
        #expect(layout.contentFolder == "files")
        let files = root.appending(path: "files")
        #expect(read(files.appending(path: "a.md")) == "# A")
        #expect(read(files.appending(path: "Work/b.md")) == "# B")
        #expect(read(files.appending(path: "assets/x.png")) == "png")
        #expect(read(files.appending(path: ".notemd.json")) == #"{"color":"green"}"#)
        #expect(read(root.appending(path: ".gitignore")) == ".DS_Store\n")
        #expect(FileManager.default.fileExists(atPath: root.appending(path: ".git").path))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "a.md").path))
        #expect(RepositoryLayout.existing(at: root) == layout)
        #expect(RepositoryLayout.strayEntries(at: root).isEmpty)
    }

    @Test func mergesLaterStraysWithoutOverwriting() throws {
        let root = try makeRoot()
        try write("kept", to: root.appending(path: "files/a.md"))
        try write("kept appearance", to: root.appending(path: "files/.notemd.json"))
        try write("png", to: root.appending(path: "files/assets/x.png"))
        try write("stray", to: root.appending(path: "a.md"))
        try write("root appearance", to: root.appending(path: ".notemd.json"))
        try write("other png", to: root.appending(path: "assets/x.png"))
        try write("new", to: root.appending(path: "assets/y.png"))

        // The notes folder already has an appearance file: the root's stays where it is.
        #expect(RepositoryLayout.strayEntries(at: root).map(\.lastPathComponent) == ["a.md", "assets"])
        try RepositoryLayout.moveIntoNotesFolder(RepositoryLayout.strayEntries(at: root), at: root)
        let files = root.appending(path: "files")
        #expect(read(files.appending(path: "a.md")) == "kept")
        #expect(read(files.appending(path: "a-2.md")) == "stray")
        #expect(read(files.appending(path: ".notemd.json")) == "kept appearance")
        #expect(read(files.appending(path: "assets/x.png")) == "png")
        #expect(read(files.appending(path: "assets/x-2.png")) == "other png")
        #expect(read(files.appending(path: "assets/y.png")) == "new")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "assets").path))
    }

    @Test func createsTheNotesFolderForAnEmptyRepository() throws {
        let root = try makeRoot()
        let layout = try RepositoryLayout.moveIntoNotesFolder([], at: root)
        #expect(layout.contentFolder == "files")
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "files").path))
    }

    @Test func incognitoFolderIgnoresItselfAndIsDiscarded() throws {
        let root = try makeRoot()
        let folder = try RepositoryLayout.prepareIncognitoFolder(at: root)
        #expect(read(folder.appending(path: ".gitignore")) == "*\n")
        try write("# Secret", to: folder.appending(path: "Secret.md"))
        try write("png", to: folder.appending(path: "assets/x.png"))
        // Hidden: never a stray to move into files/.
        #expect(RepositoryLayout.strayEntries(at: root).isEmpty)
        let notes = RepositoryScanner.scanNotes(in: folder, pathPrefix: RepositoryLayout.incognitoFolderName)
        #expect(notes.map(\.path) == [".incognito/Secret.md"] && notes.first?.title == "Secret")
        RepositoryLayout.discardIncognitoFolder(at: root)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(RepositoryScanner.scanNotes(in: folder, pathPrefix: RepositoryLayout.incognitoFolderName).isEmpty)
    }

    @Test func incognitoNotePathsStayInside() {
        #expect(RepositoryLayout.isSafeNotePath(".incognito/a.md"))
        #expect(RepositoryLayout.isSafeNotePath("Work/a.md"))
        #expect(!RepositoryLayout.isSafeNotePath(".incognito/../files/a.md"))
        #expect(!RepositoryLayout.isSafeNotePath(".incognito/"))
        #expect(!RepositoryLayout.isSafeNotePath(".git/config"))
        #expect(RepositoryLayout.isIncognitoPath(".incognito/a.md") && !RepositoryLayout.isIncognitoPath(".incognitox/a.md"))
    }

    @Test func commitMessagesLeaveOutTheNotesFolder() {
        let entries = [GitStatusEntry(kind: .renamed, path: "files/b.md", originalPath: "files/a.md")]
        #expect(CommitMessageBuilder.message(for: entries, strippingPrefix: "files/") == "Rename a.md → b.md")
        #expect(CommitMessageBuilder.message(for: [GitStatusEntry(kind: .added, path: "filesystem.md")], strippingPrefix: "files/") == "Create filesystem.md")
    }

    @Test func relocatedDeletionsKeepTheirGitPath() {
        let commit = GitCommit(id: "c1", shortID: "c1", date: Date(timeIntervalSince1970: 0), authorName: "a", subject: "Delete")
        let file = GitDeletedFile(path: "files/a.md", deletedIn: commit, lastRevision: "c0").relocated(to: "a.md")
        #expect(file.path == "a.md" && file.repositoryPath == "files/a.md")
    }
}
