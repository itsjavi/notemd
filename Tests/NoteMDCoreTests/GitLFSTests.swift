import Foundation
import Testing

@testable import NoteMDCore

@Suite("Git LFS")
struct GitLFSTests {
    @Test func addsLFSRuleKeepingExistingContent() {
        #expect(GitAttributes.addingLFSTracking("assets/**", to: "") == "assets/** filter=lfs diff=lfs merge=lfs -text\n")
        #expect(
            GitAttributes.addingLFSTracking("assets/**", to: "*.txt text")
                == "*.txt text\nassets/** filter=lfs diff=lfs merge=lfs -text\n")
        #expect(GitAttributes.addingLFSTracking("assets/**", to: "assets/**\tfilter=lfs diff=lfs\n") == nil)
        // The same pattern without the LFS filter still needs the rule.
        #expect(GitAttributes.addingLFSTracking("assets/**", to: "assets/** -diff\n") != nil)
    }

    @Test func lfsIsMissingWhenGitCannotFindIt() async throws {
        let repo = try await TestRepo.make()
        defer { repo.cleanUp() }
        let empty = repo.root.appending(path: "empty-bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let git = GitClient(
            repositoryURL: repo.url, executableURL: repo.git.executableURL,
            environment: repo.git.environment.merging(["PATH": empty.path(percentEncoded: false)]) { _, new in new })
        #expect(await git.isLFSInstalled() == false)
    }

    @Test func commitAllLeavesExcludedPathsOut() async throws {
        let repo = try await TestRepo.make()
        defer { repo.cleanUp() }
        try repo.write("note.md", "![x](assets/x.png)\n")
        try repo.write("assets/x.png", "binary")
        let commit = try await repo.git.commitAll(excluding: ["assets"])
        #expect(commit != nil)
        let tracked = try await repo.git.run(["ls-files"])
        #expect(tracked.contains("note.md"))
        #expect(!tracked.contains("assets/x.png"))
        #expect(try await repo.git.status().map(\.path) == ["assets/x.png"])
    }

    @Test func exclusionIgnoresCase() async throws {
        let repo = try await TestRepo.make()
        defer { repo.cleanUp() }
        try await repo.git.run(["config", "core.ignorecase", "true"])
        try repo.write("Assets/y.png", "binary")
        try repo.write("note.md", "x\n")
        try await repo.git.commitAll(excluding: ["assets"])
        let tracked = try await repo.git.run(["ls-files"])
        #expect(tracked.contains("note.md") && !tracked.contains("y.png"))
    }

    @Test(.enabled(if: lfsAvailable())) func enableLFSStoresAssetsAsPointers() async throws {
        let repo = try await TestRepo.make()
        defer { repo.cleanUp() }
        try await repo.git.enableLFS(tracking: "assets/**")
        try await repo.git.enableLFS(tracking: "assets/**")
        let attributes = try String(contentsOf: repo.url.appending(path: ".gitattributes"), encoding: .utf8)
        #expect(attributes == "assets/** filter=lfs diff=lfs merge=lfs -text\n")
        try repo.write("assets/clip.m4a", "pretend audio")
        try await repo.git.commitAll()
        let lfsFiles = try await repo.git.run(["lfs", "ls-files", "--name-only"])
        #expect(lfsFiles.contains("assets/clip.m4a"))
    }
}

private func lfsAvailable() -> Bool {
    ["/opt/homebrew/bin/git-lfs", "/usr/local/bin/git-lfs"].contains { FileManager.default.isExecutableFile(atPath: $0) }
}
