import Foundation
import Testing
@testable import NoteMDCore

@Suite struct RecentlyDeletedTests {
    private func deleted(_ path: String, in commit: String) -> GitDeletedFile {
        GitDeletedFile(
            path: path,
            deletedIn: GitCommit(id: commit, shortID: String(commit.prefix(7)), date: Date(timeIntervalSince1970: 0), authorName: "a", subject: "Delete \(path)"),
            lastRevision: commit + "^"
        )
    }

    @Test func listsDeletedNotesOnly() {
        let files = [deleted("a.md", in: "c1"), deleted("assets/b.png", in: "c1"), deleted("Folder/c.markdown", in: "c2")]
        #expect(RecentlyDeleted.visible(files, cleared: [], existingPaths: []).map(\.path) == ["a.md", "Folder/c.markdown"])
    }

    @Test func listsDeletedAssetsWhenAsked() {
        let files = [deleted("a.md", in: "c1"), deleted("assets/b.png", in: "c1"), deleted("other/c.png", in: "c1"), deleted("assets", in: "c1")]
        #expect(RecentlyDeleted.visible(files, cleared: [], existingPaths: [], includingAssets: true).map(\.path) == ["a.md", "assets/b.png"])
        #expect(RecentlyDeleted.isAsset("Assets/x.pdf") && !RecentlyDeleted.isAsset("notes/assets.md"))
    }

    @Test func hidesRestoredAndClearedDeletions() {
        let files = [deleted("a.md", in: "c1"), deleted("b.md", in: "c1"), deleted("c.md", in: "c2")]
        let cleared: Set = [RecentlyDeleted.key(for: files[1])]
        #expect(RecentlyDeleted.visible(files, cleared: cleared, existingPaths: ["a.md"]).map(\.path) == ["c.md"])
    }

    @Test func deletingAgainShowsTheFileAgain() {
        let first = deleted("a.md", in: "c1")
        let again = deleted("a.md", in: "c9")
        let cleared: Set = [RecentlyDeleted.key(for: first)]
        #expect(RecentlyDeleted.key(for: first) != RecentlyDeleted.key(for: again))
        #expect(RecentlyDeleted.visible([again], cleared: cleared, existingPaths: []).map(\.path) == ["a.md"])
    }
}
