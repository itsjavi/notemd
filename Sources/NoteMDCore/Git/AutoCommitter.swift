import Foundation

public enum AutoCommitEvent: Sendable, Hashable {
    case committed(GitCommit)
    case nothingToCommit
    case failed(String)
}

/// Batches saves into commits: a commit happens `idleDelay` seconds after the last `markDirty()`, but never
/// later than `maxDelay` seconds after the first un-committed change. Commits run one at a time.
///
/// Thread-safe: state is guarded by a private serial queue. `onEvent` is called from a background task,
/// so UI consumers must hop to the main actor themselves. A failed commit is not retried on its own; its
/// changes are picked up by the next commit (`git add -A` stages everything).
public final class AutoCommitter: @unchecked Sendable {
    public let git: GitClient
    public let maxDelay: TimeInterval
    private let onEvent: @Sendable (AutoCommitEvent) -> Void
    private let queue = DispatchQueue(label: "NoteMD.AutoCommitter")

    // Guarded by `queue`.
    private var currentIdleDelay: TimeInterval
    private var firstDirtyAt: DispatchTime?
    private var lastDirtyAt: DispatchTime?
    private var timer: DispatchWorkItem?
    private var lastCommit: Task<Void, Never>?

    public init(
        git: GitClient,
        idleDelay: TimeInterval = 30,
        maxDelay: TimeInterval = 300,
        onEvent: @escaping @Sendable (AutoCommitEvent) -> Void
    ) {
        self.git = git
        self.currentIdleDelay = max(0, idleDelay)
        self.maxDelay = max(0, maxDelay)
        self.onEvent = onEvent
    }

    deinit {
        timer?.cancel()
    }

    /// Seconds of inactivity before committing. Changing it re-schedules a pending commit.
    public var idleDelay: TimeInterval {
        get { queue.sync { currentIdleDelay } }
        set {
            queue.sync {
                currentIdleDelay = max(0, newValue)
                scheduleTimer()
            }
        }
    }

    /// Call after every save: (re)starts the idle timer without postponing past `maxDelay`.
    public func markDirty() {
        queue.sync {
            let now = DispatchTime.now()
            if firstDirtyAt == nil { firstDirtyAt = now }
            lastDirtyAt = now
            scheduleTimer()
        }
    }

    /// Commits now, cancelling any pending timer, and returns once that commit finished.
    /// Always safe to call; it queues behind a commit already in progress.
    public func flush() async {
        let commit = queue.sync { enqueueCommit() }
        await commit.value
    }

    /// Drops the pending commit, if any. A commit already running is allowed to finish.
    public func cancel() {
        queue.sync { resetPending() }
    }

    // MARK: Private (on `queue`)

    private func scheduleTimer() {
        guard let firstDirtyAt, let lastDirtyAt else { return }
        timer?.cancel()
        let deadline = min(lastDirtyAt + currentIdleDelay, firstDirtyAt + maxDelay)
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.timer = nil
            _ = self.enqueueCommit()
        }
        timer = item
        queue.asyncAfter(deadline: deadline, execute: item)
    }

    private func resetPending() {
        timer?.cancel()
        timer = nil
        firstDirtyAt = nil
        lastDirtyAt = nil
    }

    /// Clears the pending state and chains a commit after the previous one, so commits never overlap.
    /// Saves marked dirty from here on schedule a new commit.
    private func enqueueCommit() -> Task<Void, Never> {
        resetPending()
        let previous = lastCommit
        let commit = Task(priority: .utility) { [git, onEvent] in
            await previous?.value
            do {
                if let commit = try await git.commitAll() {
                    onEvent(.committed(commit))
                } else {
                    onEvent(.nothingToCommit)
                }
            } catch {
                onEvent(.failed(error.localizedDescription))
            }
        }
        lastCommit = commit
        return commit
    }
}
