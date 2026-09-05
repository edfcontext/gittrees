import Foundation

/// A single GitHub CLI invocation, expressed as an argument vector.
///
/// Kept separate from `GitCommand` because gh takes none of git's global flags
/// (`--no-pager`, `-c color.ui=false`); injecting those would make every gh call fail.
/// As with git, there is no way to express a shell string — arguments are an array.
public struct GitHubCommand: Sendable, Hashable {
    public var arguments: [String]
    public var workingDirectory: URL?
    public var environmentOverrides: [String: String]
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
}

/// Anything able to run a `GitHubCommand`. Injected into `GitHubClient` so parsing and
/// argument construction can be tested without spawning `gh`.
public protocol GitHubRunning: Sendable {
    func run(_ command: GitHubCommand) async throws -> GitResult
}
