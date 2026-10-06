import Foundation
import Synchronization
import Testing

@testable import NoteMDCore

private final class EventRecorder: Sendable {
    private let storage = Mutex<[AutoCommitEvent]>([])

    func record(_ event: AutoCommitEvent) { storage.withLock { $0.append(event) } }
    var events: [AutoCommitEvent] { storage.withLock { $0 } }
    var commits: [GitCommit] {
        events.compactMap { if case .committed(let commit) = $0 { commit } else { nil } }
    }
}

/// Polls `condition` until it holds or `timeout` elapses.
private func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        try await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@Suite("AutoCommitter")
struct GitAutoCommitterTests {
    @Test func savesWithinIdleWindowBecomeOneCommit() async throws {
        let repo = try await TestRepo.make()
        defer { repo.cleanUp() }
        let recorder = EventRecorder()
        let committer = AutoCommitter(git: repo.git, idleDelay: 0.3, maxDelay: 30, onEvent: recorder.record)

        for index in 1...3 {
            try repo.write("note \(index).md", "\(index)\n")
            committer.markDirty()
            try await Task.sleep(for: .milliseconds(40))
        }
        #expect(recorder.events.isEmpty)
        #expect(try await eventually { !recorder.events.isEmpty })
        try await Task.sleep(for: .milliseconds(500))

        #expect(recorder.commits.count == 1)
        #expect(recorder.commits.first?.subject == "Update 3 files")
        #expect(recorder.events.count == 1)
        #expect(try await repo.commitCount() == 2)  // initial .gitignore commit + one batch
    }

    @Test func continuousEditingCommitsAtMaxDelay() async throws {
        let repo = try await TestRepo.make()
        defer { repo.cleanUp() }
        let recorder = EventRecorder()
        let committer = AutoCommitter(git: repo.git, idleDelay: 0.4, maxDelay: 0.6, onEvent: recorder.record)

        let clock = ContinuousClock()
        let start = clock.now
        var index = 0
        while clock.now - start < .milliseconds(1500) {
            index += 1
            try repo.write("a.md", "\(index)\n")
            committer.markDirty()
            try await Task.sleep(for: .milliseconds(100))
        }
        // Saves never paused for the idle delay, yet maxDelay forced commits meanwhile.
        #expect(recorder.commits.count >= 1)
        await committer.flush()
        #expect(try String(contentsOf: repo.url.appending(path: "a.md"), encoding: .utf8) == "\(index)\n")
        #expect(try await repo.git.status().isEmpty)
    }

    @Test func flushCommitsImmediately() async throws {
        let repo = try await TestRepo.make()
        defer { repo.cleanUp() }
        let recorder = EventRecorder()
        let committer = AutoCommitter(git: repo.git, idleDelay: 30, onEvent: recorder.record)

        try repo.write("a.md", "a\n")
        committer.markDirty()
        await committer.flush()
        #expect(recorder.commits.map(\.subject) == ["Create a.md"])

        await committer.flush()
        #expect(recorder.events.last == .nothingToCommit)
        #expect(try await repo.commitCount() == 2)
    }

    @Test func concurrentFlushesAreSerialized() async throws {
        let repo = try await TestRepo.make()
        defer { repo.cleanUp() }
        let recorder = EventRecorder()
        let committer = AutoCommitter(git: repo.git, idleDelay: 30, onEvent: recorder.record)

        try repo.write("a.md", "a\n")
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 { group.addTask { await committer.flush() } }
        }
        #expect(recorder.events.count == 4)
        #expect(recorder.commits.count == 1)
        #expect(!recorder.events.contains { if case .failed = $0 { true } else { false } })
    }

    @Test func cancelDropsPendingCommit() async throws {
        let repo = try await TestRepo.make()
        defer { repo.cleanUp() }
        let recorder = EventRecorder()
        let committer = AutoCommitter(git: repo.git, idleDelay: 0.2, onEvent: recorder.record)

        try repo.write("a.md", "a\n")
        committer.markDirty()
        committer.cancel()
        try await Task.sleep(for: .milliseconds(500))
        #expect(recorder.events.isEmpty)
        #expect(try await repo.commitCount() == 1)
    }

    @Test func changingIdleDelayReschedulesPendingCommit() async throws {
        let repo = try await TestRepo.make()
        defer { repo.cleanUp() }
        let recorder = EventRecorder()
        let committer = AutoCommitter(git: repo.git, idleDelay: 30, onEvent: recorder.record)

        try repo.write("a.md", "a\n")
        committer.markDirty()
        committer.idleDelay = 0.1
        #expect(committer.idleDelay == 0.1)
        #expect(try await eventually { recorder.commits.count == 1 })
    }

    @Test func failuresAreReported() async throws {
        let repo = try await TestRepo.make(initialize: false)
        defer { repo.cleanUp() }
        let recorder = EventRecorder()
        let committer = AutoCommitter(git: repo.git, onEvent: recorder.record)

        await committer.flush()  // not a repository
        guard case .failed(let message) = recorder.events.first else {
            Issue.record("Expected a failure, got \(recorder.events)")
            return
        }
        #expect(!message.isEmpty)
    }
}
