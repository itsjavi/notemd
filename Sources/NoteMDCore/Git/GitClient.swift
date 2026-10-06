import Foundation

/// Runs `git` as a subprocess against one repository. Arguments are always passed as arrays,
/// never through a shell, and git is never allowed to prompt or page.
public struct GitClient: Sendable {
    public let repositoryURL: URL
    public let executableURL: URL
    /// Extra environment variables (e.g. `GIT_CONFIG_GLOBAL` to isolate tests). The prompt/pager/locale
    /// overrides are applied after these and always win.
    public let environment: [String: String]

    public init(repositoryURL: URL, executableURL: URL, environment: [String: String] = [:]) {
        self.repositoryURL = repositoryURL
        self.executableURL = executableURL
        self.environment = environment
    }

    // MARK: Locating git

    /// Finds a usable git: Homebrew (Apple silicon, then Intel), then `/usr/bin/git` only when developer
    /// tools are installed (otherwise that shim pops a Command Line Tools install prompt). Nil when none.
    public static func locateGit() -> URL? {
        let fileManager = FileManager.default
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let systemGit = "/usr/bin/git"
        guard fileManager.isExecutableFile(atPath: systemGit), developerToolsInstalled() else { return nil }
        return URL(fileURLWithPath: systemGit)
    }

    private static func developerToolsInstalled() -> Bool {
        guard
            let output = try? ProcessRunner.runSynchronously(
                executableURL: URL(fileURLWithPath: "/usr/bin/xcode-select"),
                arguments: ["-p"], currentDirectoryURL: nil, environment: nil),
            output.status == 0
        else { return false }
        let path = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return !path.isEmpty && FileManager.default.fileExists(atPath: path)
    }

    // MARK: Running

    /// Runs git with `-c core.quotePath=false` in `repositoryURL` and returns stdout.
    /// Throws `GitError` on a non-zero exit.
    @discardableResult
    public func run(_ arguments: [String]) async throws -> String {
        String(decoding: try await runData(arguments), as: UTF8.self)
    }

    func runData(_ arguments: [String]) async throws -> Data {
        let output = try await execute(arguments)
        guard output.status == 0 else {
            throw GitError(arguments: arguments, exitCode: output.status, stderr: output.stderrString)
        }
        return output.stdout
    }

    /// Runs git without treating a non-zero exit as an error (for probes). Throws only when git can't launch.
    func execute(_ arguments: [String]) async throws -> ProcessRunner.Output {
        do {
            return try await ProcessRunner.run(
                executableURL: executableURL,
                arguments: ["-c", "core.quotePath=false"] + arguments,
                currentDirectoryURL: repositoryURL,
                environment: processEnvironment)
        } catch {
            throw GitError(arguments: arguments, exitCode: -1, stderr: error.localizedDescription)
        }
    }

    private var processEnvironment: [String: String] {
        var result = ProcessInfo.processInfo.environment
        // Variables that would redirect git away from `repositoryURL`.
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY", "GIT_PREFIX"] {
            result[key] = nil
        }
        result.merge(environment) { _, new in new }
        result["GIT_TERMINAL_PROMPT"] = "0"
        result["GIT_PAGER"] = "cat"
        result["PAGER"] = "cat"
        result["LC_ALL"] = "C"
        return result
    }

    // MARK: Repository

    /// Whether `repositoryURL` itself is the root of a work tree (not merely inside one).
    public func isRepositoryRoot() async -> Bool {
        guard let output = try? await execute(["rev-parse", "--show-toplevel"]), output.status == 0 else {
            return false
        }
        var topLevel = output.stdoutString
        if topLevel.hasSuffix("\n") { topLevel.removeLast() }
        return Self.canonicalPath(URL(fileURLWithPath: topLevel)) == Self.canonicalPath(repositoryURL)
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
    }

    /// `git init -b main`, plus a `.gitignore` ignoring `.DS_Store` when the folder has none.
    public func initialize() async throws {
        try await run(["init", "--quiet", "--initial-branch=main"])
        let gitignore = repositoryURL.appending(path: ".gitignore", directoryHint: .notDirectory)
        if !FileManager.default.fileExists(atPath: gitignore.path(percentEncoded: false)) {
            try Data(".DS_Store\n".utf8).write(to: gitignore, options: .withoutOverwriting)
        }
    }

    /// Whether HEAD points at a commit (false in a freshly initialized repository).
    func hasHead() async -> Bool {
        (try? await execute(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"]))?.status == 0
    }

    /// Working tree status, including individual untracked files and renames.
    public func status() async throws -> [GitStatusEntry] {
        try await statusRecords().map(\.entry)
    }

    func statusRecords() async throws -> [GitOutputParser.StatusRecord] {
        // --no-optional-locks: a read-only status must not contend with a concurrent commit for index.lock.
        let data = try await runData(["--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all"])
        return GitOutputParser.statusRecords(data)
    }

    /// Whether git has a configured `user.name` and `user.email`.
    public func hasIdentity() async -> Bool {
        for key in ["user.name", "user.email"] {
            guard let output = try? await execute(["config", "--get", key]), output.status == 0,
                !output.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return false }
        }
        return true
    }

    // MARK: Committing

    /// Stages everything (`git add -A`) and commits it if anything is staged. Returns nil when there was
    /// nothing to commit. Hooks and signing are disabled so background commits never prompt or block;
    /// the author falls back to `NoteMD <notemd@localhost>` when no git identity is configured.
    @discardableResult
    public func commitAll(message: String? = nil) async throws -> GitCommit? {
        try await run(["add", "--all"])
        let staged = try await statusRecords().filter(\.isStaged).map(\.entry)
        guard !staged.isEmpty else { return nil }

        var arguments = ["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"]
        if !(await hasIdentity()) {
            arguments += ["-c", "user.name=NoteMD", "-c", "user.email=notemd@localhost"]
        }
        let message = message ?? CommitMessageBuilder.message(for: staged)
        arguments += ["commit", "--quiet", "--no-verify", "--message=\(message)"]
        try await run(arguments)

        let data = try await runData(["log", "-1", "--no-show-signature", "--format=\(GitOutputParser.logFormat)", "-z", "HEAD", "--"])
        return GitOutputParser.logRecords(data).first?.commit(for: nil)
    }

    // MARK: History

    /// Commits touching `path`, newest first, following renames. Each commit carries the path the file
    /// had in it, how it changed and its added/deleted line counts.
    public func history(for path: String, limit: Int = 300) async throws -> [GitCommit] {
        guard limit > 0, await hasHead() else { return [] }
        let data = try await runData(
            ["log", "--follow", "-M", "--max-count=\(limit)"] + Self.logOptions + ["--raw", "--numstat", "--", path])

        // Walk newest → oldest tracking the file's name, so commits without a diff (merges) still get a path.
        var trackedPath = path
        return GitOutputParser.logRecords(data).map { record in
            let change = record.changes.first { $0.path == trackedPath } ?? record.changes.first
            guard let change else {
                return GitCommit(
                    id: record.id, shortID: record.shortID, date: record.date,
                    authorName: record.authorName, subject: record.subject, path: trackedPath)
            }
            trackedPath = change.originalPath ?? change.path
            return record.commit(for: change)
        }
    }

    /// File content at `revision` (`git show rev:path`); nil when the path doesn't exist there.
    /// Throws when the revision itself is invalid.
    public func content(of path: String, at revision: String) async throws -> String? {
        let arguments = ["cat-file", "blob", "\(revision):\(path)"]
        let output = try await execute(arguments)
        if output.status == 0 { return String(decoding: output.stdout, as: UTF8.self) }
        let revisionExists = try await execute(["rev-parse", "--verify", "--quiet", "\(revision)^{commit}"]).status == 0
        guard revisionExists else {
            throw GitError(arguments: arguments, exitCode: output.status, stderr: output.stderrString)
        }
        return nil
    }

    /// Files deleted in history, most recent deletion first, one entry per path. Renamed files and paths
    /// that exist again (at HEAD or on disk) are excluded.
    public func deletedFiles(limit: Int = 100) async throws -> [GitDeletedFile] {
        guard limit > 0, await hasHead() else { return [] }
        let data = try await runData(["log", "--diff-filter=D", "-M"] + Self.logOptions + ["--raw", "--numstat"])
        let trackedAtHead = Set(
            try await runData(["ls-tree", "-r", "-z", "--name-only", "--full-tree", "HEAD"])
                .split(separator: 0).map(GitOutputParser.decode))

        var seen = Set<String>()
        var result: [GitDeletedFile] = []
        for record in GitOutputParser.logRecords(data) {
            guard let parent = record.parents.first else { continue }
            for change in record.changes where change.kind == .deleted {
                guard seen.insert(change.path).inserted else { continue }
                let onDisk = repositoryURL.appending(path: change.path).path(percentEncoded: false)
                if trackedAtHead.contains(change.path) || FileManager.default.fileExists(atPath: onDisk) { continue }
                result.append(GitDeletedFile(path: change.path, deletedIn: record.commit(for: change), lastRevision: parent))
                if result.count == limit { return result }
            }
        }
        return result
    }

    /// Log flags that keep `-z` output machine-readable regardless of user config.
    private static let logOptions = [
        "--format=\(GitOutputParser.logFormat)", "-z",
        "--no-show-signature", "--no-color", "--no-ext-diff", "--no-textconv",
    ]
}
