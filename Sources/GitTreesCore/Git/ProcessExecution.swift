import Foundation

/// Spawn failure from `Subprocess.run` — the process could not be started at all.
///
/// Distinct from a non-zero exit (which is returned, not thrown): each runner maps this
/// to its own error type so callers see "git" or "gh" in the message, not a generic one.
struct ProcessLaunchFailure: Error {
    let reason: String
}

/// Runs an external executable through Foundation's `Process`, capturing both streams.
///
/// Extracted so every command-line tool the app drives — `git`, `gh` — shares one
/// correct implementation of the tricky parts: draining both pipes concurrently (a large
/// diff exceeds a pipe buffer, so reading only after exit would deadlock), and honouring
/// task cancellation without signalling a process that never started or leaking one that
/// did. Arguments are always passed as an array, so nothing is ever handed to a shell.
enum Subprocess {
    static func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]
    ) async throws -> GitResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let handle = ProcessHandle(process: process)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GitResult, Error>) in
                let out = DataCollector()
                let err = DataCollector()
                let group = DispatchGroup()

                let outHandle = UncheckedBox(outPipe.fileHandleForReading)
                let errHandle = UncheckedBox(errPipe.fileHandleForReading)
                let box = UncheckedBox(process)

                // Enter for the termination handler and both pipe readers up front, so
                // `notify` cannot fire early. The reads themselves are dispatched only
                // after a successful spawn (below): if `run()` throws, no reader is ever
                // handed a file descriptor, so a failed launch can never close a handle
                // out from under a blocked `readDataToEndOfFile` — the cause of an
                // uncatchable Bad-file-descriptor exception under concurrent launches.
                group.enter()
                group.enter()
                group.enter()
                process.terminationHandler = { _ in
                    group.leave()
                }

                do {
                    try handle.start()
                } catch {
                    // No readers were dispatched; balance their enters and the
                    // termination enter, then fail. ARC closes the pipes safely because
                    // nothing is reading them.
                    process.terminationHandler = nil
                    group.leave()
                    group.leave()
                    group.leave()
                    if error is CancellationError {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(
                            throwing: ProcessLaunchFailure(reason: (error as NSError).localizedDescription)
                        )
                    }
                    return
                }

                // The process is live; drain both pipes concurrently while it runs.
                readQueue.async {
                    out.set(outHandle.value.readDataToEndOfFile())
                    group.leave()
                }
                readQueue.async {
                    err.set(errHandle.value.readDataToEndOfFile())
                    group.leave()
                }

                group.notify(queue: readQueue) {
                    continuation.resume(
                        returning: GitResult(
                            stdout: out.value,
                            stderr: err.value,
                            exitCode: box.value.terminationStatus
                        )
                    )
                }
            }
        } onCancel: {
            handle.terminate()
        }
    }

    private static let readQueue = DispatchQueue(
        label: "com.gittrees.subprocess-io",
        qos: .userInitiated,
        attributes: .concurrent
    )
}

// MARK: - Concurrency helpers

/// Carries a non-`Sendable` Foundation object across a concurrency boundary where the
/// surrounding code guarantees single-threaded access.
private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Lock-protected buffer written by a pipe-reading queue and read after both reads finish.
private final class DataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func set(_ data: Data) {
        lock.lock()
        storage = data
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Serialises `run()` and `terminate()` so a task cancelled between the two cannot
/// signal a process that has not started, or leak one that has.
private final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var started = false
    private var cancelled = false

    init(process: Process) {
        self.process = process
    }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try process.run()
        started = true
    }

    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if started, process.isRunning {
            process.terminate()
        }
    }
}
