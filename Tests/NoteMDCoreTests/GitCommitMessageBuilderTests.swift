import Testing

@testable import NoteMDCore

@Suite("CommitMessageBuilder")
struct GitCommitMessageBuilderTests {
    @Test(arguments: [
        (GitStatusEntry(kind: .added, path: "notes/a.md"), "Create notes/a.md"),
        (GitStatusEntry(kind: .untracked, path: "notes/a.md"), "Create notes/a.md"),
        (GitStatusEntry(kind: .modified, path: "notes/a.md"), "Update notes/a.md"),
        (GitStatusEntry(kind: .deleted, path: "notes/a.md"), "Delete notes/a.md"),
        (GitStatusEntry(kind: .renamed, path: "b.md", originalPath: "a.md"), "Rename a.md → b.md"),
    ])
    func singleEntry(entry: GitStatusEntry, expected: String) {
        #expect(CommitMessageBuilder.message(for: [entry]) == expected)
    }

    @Test func severalEntriesListEachSortedByPath() {
        let message = CommitMessageBuilder.message(for: [
            GitStatusEntry(kind: .modified, path: "z.md"),
            GitStatusEntry(kind: .renamed, path: "m.md", originalPath: "old.md"),
            GitStatusEntry(kind: .added, path: "a b.md"),
            GitStatusEntry(kind: .deleted, path: "notes/d.md"),
        ])
        #expect(
            message == """
                Update 4 files

                - Create a b.md
                - Rename old.md → m.md
                - Delete notes/d.md
                - Update z.md
                """)
    }

    @Test func noEntries() {
        #expect(CommitMessageBuilder.message(for: []) == "Update files")
    }
}
