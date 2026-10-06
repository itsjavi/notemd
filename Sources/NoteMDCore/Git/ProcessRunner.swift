import Foundation

/// Launches a subprocess and collects its output. stdout and stderr are drained concurrently so a
/// child that fills one pipe while we block on the other can't deadlock.
enum ProcessRunner {
    struct Output: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data

        var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
        var stderrString: String { String(decoding: stderr, as: UTF8.self) }
    }

    /// Runs off the cooperative thread pool, since waiting on a process blocks a thread.
    static func run(
        executableURL: URL, arguments: [String], currentDirectoryURL: URL?, environment: [String: String]?
    ) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    with: Result {
                        try runSynchronously(
                            executableURL: executableURL, arguments: arguments,
                            currentDirectoryURL: currentDirectoryURL, environment: environment)
                    })
            }
        }
    }

    static func runSynchronously(
        executableURL: URL, arguments: [String], currentDirectoryURL: URL?, environment: [String: String]?
    ) throws -> Output {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let currentDirectoryURL { process.currentDirectoryURL = currentDirectoryURL }
        if let environment { process.environment = environment }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice
        try process.run()

        let stderrBuffer = Buffer()
        let stderrHandle = stderrPipe.fileHandleForReading
        let group = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            stderrBuffer.data = (try? stderrHandle.readToEnd()) ?? Data()
        }
        let stdout = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
        group.wait()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, stdout: stdout, stderr: stderrBuffer.data)
    }

    /// Written by one reader thread, read only after `DispatchGroup.wait()` establishes ordering.
    private final class Buffer: @unchecked Sendable {
        var data = Data()
    }
}
