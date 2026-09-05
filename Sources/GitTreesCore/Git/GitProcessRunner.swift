import Foundation

/// Runs Git by spawning `/usr/bin/git` through Foundation's `Process`.
///
/// Arguments are always passed as an array. No shell is involved at any point, so
/// paths, branch names and lock reasons containing spaces, quotes or glob characters
/// need no escaping and cannot be reinterpreted as syntax. The process plumbing lives
/// in `Subprocess`, shared with the GitHub CLI runner.
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

        let arguments = command.fullArguments

        // `Process.run()` raises an Objective-C exception — which cannot be caught from
        // Swift — when the current directory does not exist. A worktree can be deleted
        // from under the application at any moment, so this is checked rather than risked.
        if let directory = command.workingDirectory {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
            guard exists, isDirectory.boolValue else {
                throw GitError.launchFailed(
                    arguments: arguments,
                    reason: exists
                        ? "\(directory.path) is not a directory"
                        : "the directory \(directory.path) no longer exists"
                )
            }
        }

        let result: GitResult
        do {
            result = try await Subprocess.run(
                executable: executableURL,
                arguments: arguments,
                workingDirectory: command.workingDirectory,
                environment: Self.environment(overrides: command.environmentOverrides)
            )
        } catch let failure as ProcessLaunchFailure {
            throw GitError.launchFailed(arguments: arguments, reason: failure.reason)
        }

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
}
