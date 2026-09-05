import Foundation

/// Runs Git by spawning `/usr/bin/git` through Foundation's `Process`.
///
/// Arguments are always passed as an array. No shell is involved at any point, so
/// paths, branch names and lock reasons containing spaces, quotes or glob characters
/// need no escaping and cannot be reinterpreted as syntax.
public final class GitProcessRunner: GitRunning {
    /// Path to the git executable. `/usr/bin/git` is the system shim; users with a
    /// newer Git can point this at e.g. `/opt/homebrew/bin/git`.
    public static let defaultExecutablePath = "/usr/bin/git"

    private let executableURL: URL

    public init(executablePath: String = GitProcessRunner.defaultExecutablePath) {
        self.executableURL = URL(fileURLWithPath: executablePath)
    }

    public var executablePath: String { executableURL.path }

    public func run(_ command: GitCommand) async throws -> GitResult {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw GitError.executableNotFound(path: executableURL.path)
        }

        // `Process.run()` raises an Objective-C exception — which cannot be caught from
        // Swift — when the current directory does not exist. A worktree can be deleted
        // from under the application at any moment, so this is checked rather than risked.
        if let directory = command.workingDirectory {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
            guard exists, isDirectory.boolValue else {
                throw GitError.launchFailed(
                    arguments: command.fullArguments,
                    reason: exists
                        ? "\(directory.path) is not a directory"
                        : "the directory \(directory.path) no longer exists"
                )
            }
        }

        let arguments = command.fullArguments
        let result = try await Self.execute(
            executable: executableURL,
            arguments: arguments,
            workingDirectory: command.workingDirectory,
            environment: Self.environment(overrides: command.environmentOverrides)
        )

        guard command.acceptableExitCodes.contains(result.exitCode) else {
            throw GitError.commandFailed(
                GitFailure(
                    arguments: arguments,
                    workingDirectory: command.workingDirectory?.path,
                    exitCode: result.exitCode,
                    stdout: result.stdoutText,
                    stderr: result.stderrText
                )
            )
        }
        return result
    }

    // MARK: - Environment

    /// The user's environment, plus the few settings needed for non-interactive use.
    ///
    /// Git configuration and hooks are otherwise left completely untouched: the
    /// inherited environment is what the user's own shell would give `git`.
    private static func environment(overrides: [String: String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        // There is no terminal attached, so a credential prompt would hang forever.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_PAGER"] = "cat"
        environment["PAGER"] = "cat"
        for (key, value) in overrides {
            environment[key] = value
        }
        return environment
    }

    // MARK: - Process plumbing

    /// Wraps `Process` in a continuation, draining both pipes on background queues.
    ///
    /// Both streams must be read while the process runs: Git can produce more than a
    /// pipe buffer of output (a large diff), and waiting for exit before reading would
    /// deadlock as soon as it does.
    private static func execute(
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

                group.enter()
                readQueue.async {
                    out.set(outHandle.value.readDataToEndOfFile())
                    group.leave()
                }
                group.enter()
                readQueue.async {
                    err.set(errHandle.value.readDataToEndOfFile())
                    group.leave()
                }

                let box = UncheckedBox(process)
                group.enter()
                process.terminationHandler = { _ in
                    group.leave()
                }

                do {
                    try handle.start()
                } catch {
                    // The termination handler will never fire, so balance the group
                    // by hand before failing, or `notify` would never run.
                    process.terminationHandler = nil
                    group.leave()
                    outHandle.value.closeFile()
                    errHandle.value.closeFile()
                    if error is CancellationError {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(
                            throwing: GitError.launchFailed(
                                arguments: arguments,
                                reason: (error as NSError).localizedDescription
                            )
                        )
                    }
                    return
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
        label: "com.gittrees.git-io",
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
