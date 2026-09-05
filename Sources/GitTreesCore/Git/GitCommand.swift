import Foundation

/// A single Git invocation, expressed as an argument vector.
///
/// There is deliberately no way to express a shell command string: arguments are passed
/// to `Process` as an array and never interpreted by a shell.
public struct GitCommand: Sendable, Hashable {
    /// Arguments after the executable itself, e.g. `["worktree", "list", "--porcelain", "-z"]`.
    public var arguments: [String]
    /// Directory the process runs in. Determines which repository/worktree Git addresses.
    public var workingDirectory: URL?
    /// Environment entries layered on top of the inherited environment.
    public var environmentOverrides: [String: String]
    /// Exit codes treated as success. Defaults to `[0]`; `git diff --no-index` needs `[0, 1]`.
    public var acceptableExitCodes: Set<Int32>

    public init(
        _ arguments: [String],
        workingDirectory: URL? = nil,
        environmentOverrides: [String: String] = [:],
        acceptableExitCodes: Set<Int32> = [0]
    ) {
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environmentOverrides = environmentOverrides
        self.acceptableExitCodes = acceptableExitCodes
    }

    /// Global flags applied to every invocation so that output is machine-readable and
    /// no interactive pager or colouring interferes.
    public static let globalFlags: [String] = [
        "--no-pager",
        "-c", "color.ui=false",
        "-c", "core.quotepath=false"
    ]

    /// The full argument vector handed to `/usr/bin/git`.
    public var fullArguments: [String] {
        GitCommand.globalFlags + arguments
    }
}

/// The raw result of running Git.
public struct GitResult: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32

    public init(stdout: Data, stderr: Data, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    /// stdout decoded as UTF-8, replacing invalid byte sequences rather than failing:
    /// Git paths are byte strings and are not guaranteed to be valid UTF-8.
    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }

    /// stdout with a single trailing newline removed.
    public var trimmedStdout: String {
        stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Anything able to run a `GitCommand`. Injected into `GitClient` so parsing and
/// command construction can be tested without spawning processes.
public protocol GitRunning: Sendable {
    func run(_ command: GitCommand) async throws -> GitResult
}
