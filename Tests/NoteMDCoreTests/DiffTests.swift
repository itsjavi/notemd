import Testing

@testable import NoteMDCore

@Suite("LineDiff")
struct DiffTests {
    private func numbered(_ count: Int, replacing replacements: [Int: String] = [:]) -> String {
        (1...count).map { replacements[$0] ?? "line \($0)" }.joined(separator: "\n") + "\n"
    }

    @Test func identicalTextsHaveNoHunks() {
        let diff = LineDiff(old: "a\nb\n", new: "a\nb\n")
        #expect(diff.isEmpty)
        #expect(diff.additions == 0 && diff.deletions == 0)
        #expect(LineDiff(old: "", new: "").isEmpty)
    }

    @Test func modificationProducesNumberedLines() throws {
        let diff = LineDiff(old: "a\nb\nc\n", new: "a\nB\nc\n")
        let hunk = try #require(diff.hunks.first)
        #expect(diff.hunks.count == 1)
        #expect(hunk.header == "@@ -1,3 +1,3 @@")
        #expect(hunk.lines.map(\.kind) == [.context, .removed, .added, .context])
        #expect(hunk.lines.map(\.text) == ["a", "b", "B", "c"])
        #expect(hunk.lines.map(\.oldNumber) == [1, 2, nil, 3])
        #expect(hunk.lines.map(\.newNumber) == [1, nil, 2, 3])
        #expect(diff.additions == 1 && diff.deletions == 1)
    }

    @Test func insertionIntoEmptyText() throws {
        let diff = LineDiff(old: "", new: "x\ny\n")
        let hunk = try #require(diff.hunks.first)
        #expect(hunk.header == "@@ -0,0 +1,2 @@")
        #expect(hunk.lines.map(\.newNumber) == [1, 2])
        #expect(diff.additions == 2)
    }

    @Test func deletionOfEverything() throws {
        let diff = LineDiff(old: "x\n", new: "")
        #expect(try #require(diff.hunks.first).header == "@@ -1,1 +0,0 @@")
        #expect(diff.deletions == 1)
    }

    @Test func distantChangesGetSeparateHunks() {
        let diff = LineDiff(old: numbered(20), new: numbered(20, replacing: [2: "two", 18: "eighteen"]))
        #expect(diff.hunks.map(\.header) == ["@@ -1,5 +1,5 @@", "@@ -15,6 +15,6 @@"])
        #expect(diff.hunks.map(\.id) == [0, 1])
        let ids = diff.hunks.flatMap(\.lines).map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func nearbyChangesShareAHunk() {
        let diff = LineDiff(old: numbered(20), new: numbered(20, replacing: [2: "two", 8: "eight"]))
        #expect(diff.hunks.map(\.header) == ["@@ -1,11 +1,11 @@"])
    }

    @Test func contextParameter() {
        let zero = LineDiff(old: "a\nb\nc\n", new: "a\nc\n", context: 0)
        #expect(zero.hunks.map(\.header) == ["@@ -2,1 +1,0 @@"])
        let prepend = LineDiff(old: "b\n", new: "a\nb\n", context: 0)
        #expect(prepend.hunks.map(\.header) == ["@@ -0,0 +1,1 @@"])
        let whole = LineDiff(old: numbered(20), new: numbered(20, replacing: [10: "ten"]), context: .max)
        #expect(whole.hunks.map(\.header) == ["@@ -1,20 +1,20 @@"])
    }

    @Test func lineEndingsAreNotChanges() throws {
        #expect(LineDiff(old: "a\r\nb\r\n", new: "a\nb\n").isEmpty)
        #expect(LineDiff(old: "a\nb", new: "a\nb\n").isEmpty)

        let crlf = LineDiff(old: "a\r\nb\r\n", new: "a\r\nc\r\n")
        #expect(crlf.hunks.first?.lines.map(\.text) == ["a", "b", "c"])

        let appended = LineDiff(old: "a\nb", new: "a\nb\nc")
        let hunk = try #require(appended.hunks.first)
        #expect(hunk.lines.map(\.kind) == [.context, .context, .added])
        #expect(hunk.lines.last?.newNumber == 3)
    }

    @Test func blankLinesAreLines() throws {
        let diff = LineDiff(old: "a\n\nb\n", new: "a\nb\n")
        let hunk = try #require(diff.hunks.first)
        #expect(hunk.lines.map(\.kind) == [.context, .removed, .context])
        #expect(hunk.lines[1].text == "")
        #expect(hunk.lines[1].oldNumber == 2)
    }
}
