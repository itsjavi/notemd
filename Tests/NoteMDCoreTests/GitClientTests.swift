import Foundation
import Testing

@testable import NoteMDCore

/// A temporary git repository isolated from the developer's global/system git config.
struct TestRepo {
    let root: URL
    let url: URL
    let git: GitClient

    /// - Parameters:
    ///   - identity: configure a local `user.name`/`user.email`.
    ///   - initialCommit: commit the `.gitignore` written by `initialize()`, so the repo starts clean with a HEAD.
    static func make(initialize: Bool = true, identity: Bool = true, initialCommit: Bool = true) async throws -> TestRepo {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "notemd-git-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let url = root.appending(path: "repo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let globalConfig = root.appending(path: "gitconfig")
        try Data().write(to: globalConfig)
        let executable = try #require(GitClient.locateGit())
        let git = GitClient(
            repositoryURL: url, executableURL: executable,
            environment: ["GIT_CONFIG_GLOBAL": globalConfig.path(percentEncoded: false), "GIT_CONFIG_NOSYSTEM": "1"])
        let repo = TestRepo(root: root, url: url, git: git)
        if initialize {
            try await git.initialize()
            if identity {
                try await git.run(["config", "user.name", "Test User"])
                try await git.run(["config", "user.email", "test@example.com"])
            }
            if initialCommit { try await git.commitAll() }
        }
        return repo
    }

    func write(_ path: String, _ contents: String) throws {
        let file = url.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
    }

    func remove(_ path: String) throws {
        try FileManager.default.removeItem(at: url.appending(path: path))
    }

    func move(_ source: String, _ destination: String) throws {
        let target = url.appending(path: destination)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url.appending(path: source), to: target)
    }

    func commitCount() async throws -> Int {
        guard await git.hasHead() else { return 0 }
        return Int(try await git.run(["rev-list", "--count", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("GitClient")
struct GitClientTests {
    @Test func locatesAnExecutableGit() throws {
        let git = try #require(GitClient.locateGit())
        #expect(FileManager.default.isExecutableFile(atPath: git.path(percentEncoded: false)))
    }

    @Test func initializeCreatesRepositoryWithGitignore() async throws {
        let repo = try await TestRepo.make(initialize: false)
        defer { repo.cleanUp() }

        #expect(await repo.git.isRepositoryRoot() == false)
        try await repo.git.initialize()
        #expect(await repo.git.isRepositoryRoot())
        let gitignore = try String(contentsOf: repo.url.appending(path: ".gitignore"), encoding: .utf8)
        #expect(gitignore == ".DS_Store\n")
        let branch = try await repo.git.run(["symbolic-ref", "--short", "HEAD"])
        #expect(branch == "main\n")
    }

    @Test func initializeKeepsExistingGitignore() async throws {
        let repo = try await TestRepo.make(initialize: false)
        defer { repo.cleanUp() }
        try repo.write(".gitignore", "build/\n")
        try await repo.git.initialize()
        #expect(try String(contentsOf: repo.url.appending(path: ".gitignore"), encoding: .utf8) == "build/\n")
    }

    @Test func subfolderOfRepositoryIsNotARoot() async throws {
        let repo = try await TestRepo.make()
        defer { repo.cleanUp() }
        try repo.write("sub/a.md", "a")
        let sub = GitClient(
            repositoryURL: repo.url.appending(path: "sub"), executableURL: repo.git.executableURL,
            environment: repo.git.environment)
        #expect(await sub.isRepositoryRoot() == false)
    }

    @Test func runThrowsGitErrorOnFailure() async throws {
        let repo = try await TestRepo.make()
        defer { repo.cleanUp() }
        let error = await #expect(throws: GitError.self) { try await repo.git.run(["no-such-command"]) }
        #expect(error?.exitCode != 0)
        #expect(error?.arguments == ["no-such-command"])
        #expect(error?.errorDescription?.contains("no-such-command") == true)
    }

    @Test func statusReportsEveryKindWithUnquotedPaths() async throws {
        let repo = try await TestRepo.make()
        defer { repo.cleanUp() }
        for name in ["keep.md", "mod.md", "del.md", "old name.md"] { try repo.write(name, "\(name)\n") }
        try await repo.git.commitAll()

        try repo.write("mod.md", "changed\n")
        try repo.remove("del.md")
        try await repo.git.run(["mv", "old name.md", "new name.md"])
        try repo.write("staged.md", "s\n")
        try await repo.git.run(["add", "staged.md"])
        try repo.write("notas/café ñ \"q\".md", "u\n")

        let entries = Set(try await repo.git.status())
        #expect(
            entries == [
                GitStatusEntry(kind: .modified, path: "mod.md"),
                GitStatusEntry(kind: .deleted, path: "del.md"),
                GitStatusEntry(kind: .renamed, path: "new name.md", originalPath: "old name.md"),
                GitStatusEntry(kind: .added, path: "staged.md"),
                GitStatusEntry(kind: .untracked, path: "notas/café ñ \"q\".md"),
            ])
    }

    @Test func statusOfEmptyRepositoryListsUntrackedFiles() async throws {
        let repo = try await TestRepo.make(initialCommit: false)
        defer { repo.cleanUp() }
        #expect(try await repo.git.status() == [GitStatusEntry(kind: .untracked, path: ".gitignore")])
    }

    @Test func commitAllCommitsWithGeneratedMessageAndReturnsNilWhenClean() async throws {
        let repo = try await TestRepo.make(initialCommit: false)
        defer { repo.cleanUp() }

        // First commit in a repository without HEAD.
        let first = try #require(try await repo.git.commitAll())
        #expect(first.subject == "Create .gitignore")
        #expect(first.authorName == "Test User")
        #expect(first.id.count == 40)
        #expect(first.id.hasPrefix(first.shortID))
        #expect(abs(first.date.timeIntervalSinceNow) < 120)
        #expect(try await repo.git.commitAll() == nil)

        try repo.write("notes/a.md", "a\n")
        try repo.write("b.md", "b\n")
        let second = try #require(try await repo.git.commitAll())
        #expect(second.subject == "Update 2 files")
        let body = try await repo.git.run(["log", "-1", "--format=%B"])
        #expect(body == "Update 2 files\n\n- Create b.md\n- Create notes/a.md\n\n")
        #expect(try await repo.git.commitAll() == nil)

        try repo.write("b.md", "b2\n")
        #expect(try await repo.git.commitAll(message: "Custom message")?.subject == "Custom message")
        #expect(try await repo.commitCount() == 3)
    }

    @Test func commitAllFallsBackToNoteMDIdentity() async throws {
        let repo = try await TestRepo.make(identity: false, initialCommit: false)
        defer { repo.cleanUp() }
        #expect(await repo.git.hasIdentity() == false)
        try #require(try await repo.git.commitAll() != nil)
        #expect(try await repo.git.run(["log", "-1", "--format=%an <%ae>"]) == "NoteMD <notemd@localhost>\n")
    }

    @Test func commitAllIgnoresHooksAndSigning() async throws {
        let repo = try await TestRepo.make()
        defer { repo.cleanUp() }
        #expect(await repo.git.hasIdentity())
        let hooks = repo.url.appending(path: ".git/hooks")
        for hook in ["pre-commit", "commit-msg", "prepare-commit-msg"] {
            let file = hooks.appending(path: hook)
            try Data("#!/bin/sh\nexit 1\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path(percentEncoded: false))
        }
        try await repo.git.run(["config", "commit.gpgsign", "true"])
        try await repo.git.run(["config", "gpg.program", "/usr/bin/false"])

        try repo.write("a.md", "a\n")
        #expect(try await repo.git.commitAll()?.subject == "Create a.md")
    }

    @Test func historyFollowsRenamesWithLineCounts() async throws {
        let repo = try await TestRepo.make()
        defer { repo.cleanUp() }
        try repo.write("a.md", "one\ntwo\nthree\n")
        let created = try #require(try await repo.git.commitAll())
        try repo.write("a.md", "one\n2\nthree\nfour\n")
        let edited = try #require(try await repo.git.commitAll())
        try repo.move("a.md", "notes/b é.md")
        let renamed = try #require(try await repo.git.commitAll())
        try repo.write("notes/b é.md", "one\n2\nthree\nfour\nfive\n")
        try repo.write("other.md", "unrelated\n")
        let appended = try #require(try await repo.git.commitAll())

        #expect(renamed.subject == "Rename a.md → notes/b é.md")

        let history = try await repo.git.history(for: "notes/b é.md")
        #expect(history.map(\.id) == [appended.id, renamed.id, edited.id, created.id])
        #expect(history.map(\.path) == ["notes/b é.md", "notes/b é.md", "a.md", "a.md"])
        #expect(history.map(\.changeKind) == [.modified, .renamed, .modified, .added])
        #expect(history.map(\.additions) == [1, 0, 2, 3])
        #expect(history.map(\.deletions) == [0, 0, 1, 0])
        #expect(history.first?.subject == "Update 2 files")

        #expect(try await repo.git.history(for: "notes/b é.md", limit: 2).count == 2)
        #expect(try await repo.git.history(for: "missing.md").isEmpty)
    }

    @Test func historyAndDeletedFilesAreEmptyWithoutCommits() async throws {
        let repo = try await TestRepo.make(initialCommit: false)
        defer { repo.cleanUp() }
        #expect(try await repo.git.history(for: ".gitignore").isEmpty)
        #expect(try await repo.git.deletedFiles().isEmpty)
    }

    @Test func contentAtRevision() async throws {
        let repo = try await TestRepo.make()
        defer { repo.cleanUp() }
        try repo.write("dir/a b.md", "line 1\r\nline 2\r\n")
        let first = try #require(try await repo.git.commitAll())
        try repo.write("dir/a b.md", "changed")
        let second = try #require(try await repo.git.commitAll())

        #expect(try await repo.git.content(of: "dir/a b.md", at: first.id) == "line 1\r\nline 2\r\n")
        #expect(try await repo.git.content(of: "dir/a b.md", at: second.shortID) == "changed")
        #expect(try await repo.git.content(of: "dir/a b.md", at: "HEAD~2") == nil)
        #expect(try await repo.git.content(of: "nope.md", at: "HEAD") == nil)
        await #expect(throws: GitError.self) {
            try await repo.git.content(of: "dir/a b.md", at: "0123456789abcdef0123456789abcdef01234567")
        }
    }

    @Test func deletedFilesListsMostRecentDeletionPerPath() async throws {
        let repo = try await TestRepo.make()
        defer { repo.cleanUp() }
        for name in ["x.md", "y.md", "keep.md", "w.md"] { try repo.write(name, "\(name) v1\n") }
        try await repo.git.commitAll()
        try repo.remove("x.md")
        try await repo.git.commitAll()
        try repo.move("y.md", "z.md")  // renames are not deletions
        try await repo.git.commitAll()
        try repo.remove("w.md")
        let wDeletion = try #require(try await repo.git.commitAll())
        try repo.remove("keep.md")  // deleted, then recreated: not listed
        try await repo.git.commitAll()
        try repo.write("keep.md", "back\n")
        try await repo.git.commitAll()
        try repo.write("x.md", "x.md v2\n")  // recreated and deleted again: listed once, latest deletion
        try await repo.git.commitAll()
        try repo.remove("x.md")
        let xDeletion = try #require(try await repo.git.commitAll())

        let deleted = try await repo.git.deletedFiles()
        #expect(deleted.map(\.path) == ["x.md", "w.md"])
        #expect(deleted.map(\.deletedIn.id) == [xDeletion.id, wDeletion.id])
        #expect(deleted.first?.deletedIn.subject == "Delete x.md")
        #expect(deleted.first?.deletedIn.changeKind == .deleted)
        #expect(deleted.first?.deletedIn.deletions == 1)
        #expect(try await repo.git.content(of: "x.md", at: deleted[0].lastRevision) == "x.md v2\n")
        #expect(try await repo.git.content(of: "w.md", at: deleted[1].lastRevision) == "w.md v1\n")
        #expect(try await repo.git.deletedFiles(limit: 1).map(\.path) == ["x.md"])

        // A deleted file restored on disk (not yet committed) is no longer "deleted".
        try repo.write("w.md", "restored\n")
        #expect(try await repo.git.deletedFiles().map(\.path) == ["x.md"])
    }
}
