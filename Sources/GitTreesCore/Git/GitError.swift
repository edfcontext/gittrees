import Foundation

/// Everything known about a Git invocation that exited non-zero.
///
/// Git failures are ordinary application states, so the full context is preserved:
/// the argument vector, the working directory, the exit code and both output streams.
public struct GitFailure: Sendable, Hashable {
    /// The program that ran, e.g. `git` or `gh`. Used only for display.
    public var program: String
    public var arguments: [String]
    public var workingDirectory: String?
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(
        program: String = "git",
        arguments: [String],
        workingDirectory: String?,
        exitCode: Int32,
        stdout: String,
        stderr: String
    ) {
        self.program = program
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    /// `git worktree add …` — for showing the user what actually ran.
    public var commandLine: String {
        ([program] + arguments).joined(separator: " ")
    }

    /// The program's own message, preferring stderr and falling back to stdout.
    public var message: String {
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { return err }
        let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty { return out }
        return "\(program) exited with status \(exitCode)."
    }
}

/// An error that wraps a failed external-command invocation. Both `GitError` and
/// `GitHubError` adopt it so `PresentableError` can surface either uniformly.
public protocol CommandExecutionError {
    var failure: GitFailure? { get }
}

public enum GitError: Error, LocalizedError, Sendable {
    /// The configured git executable is missing or not executable.
    case executableNotFound(path: String)
    /// `Process.run()` itself failed.
    case launchFailed(arguments: [String], reason: String)
    /// Git ran and exited with an unacceptable status.
    case commandFailed(GitFailure)
    /// The chosen directory is not inside a Git repository.
    case notARepository(path: String)
    /// Creating a new workspace folder failed before Git ran.
    case couldNotCreateDirectory(path: String, reason: String)
    /// Git's machine-readable output did not match the documented format.
    case unexpectedOutput(reason: String, arguments: [String])
    /// A destructive operation was already running against the same worktree.
    case operationInProgress(path: String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let path):
            return "Git was not found at \(path)."
        case .launchFailed(let arguments, let reason):
            return "Could not run git \(arguments.joined(separator: " ")): \(reason)"
        case .commandFailed(let failure):
            return failure.message
        case .notARepository(let path):
            return "\(path) is not inside a Git repository."
        case .couldNotCreateDirectory(let path, let reason):
            return "Could not create \(path): \(reason)"
        case .unexpectedOutput(let reason, _):
            return "Unexpected output from git: \(reason)"
        case .operationInProgress(let path):
            return "Another operation is already running in \(path)."
        }
    }

    public var failureReason: String? {
        switch self {
        case .commandFailed(let failure):
            return failure.commandLine
        case .unexpectedOutput(_, let arguments):
            return (["git"] + arguments).joined(separator: " ")
        default:
            return nil
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .executableNotFound:
            return "Install the Xcode Command Line Tools, or set a different git path in Settings."
        case .notARepository:
            return "Choose a directory that is inside a Git repository."
        case .couldNotCreateDirectory:
            return "Choose a different folder name, or a parent directory you can write to."
        default:
            return nil
        }
    }

    /// The underlying failure, when this error came from a non-zero exit.
    public var failure: GitFailure? {
        if case .commandFailed(let failure) = self { return failure }
        return nil
    }
}

extension GitError: CommandExecutionError {}
