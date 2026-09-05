import Foundation

/// Runs the GitHub CLI by spawning `gh` through the shared `Subprocess` plumbing.
///
/// Unlike git, gh has no system location — it only ever comes from a package manager —
/// so the default is a best-effort probe of the usual install paths, overridable in
/// Settings.
public final class GitHubProcessRunner: GitHubRunning {
    /// Common install locations, most likely first: Apple-silicon Homebrew, Intel
    /// Homebrew, then MacPorts.
    public static let knownExecutablePaths = [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh",
        "/opt/local/bin/gh"
    ]

    /// The first install location that exists, or the Apple-silicon default when none
    /// is present yet (so the setting shows a sensible path to correct).
    public static var defaultExecutablePath: String {
        knownExecutablePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? knownExecutablePaths[0]
    }

    private let executableURL: URL

    public init(executablePath: String = GitHubProcessRunner.defaultExecutablePath) {
        self.executableURL = URL(fileURLWithPath: executablePath)
    }

    public var executablePath: String { executableURL.path }

    public func run(_ command: GitHubCommand) async throws -> GitResult {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw GitHubError.executableNotFound(path: executableURL.path)
        }

        if let directory = command.workingDirectory {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
            guard exists, isDirectory.boolValue else {
                throw GitHubError.launchFailed(
                    arguments: command.arguments,
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
                arguments: command.arguments,
                workingDirectory: command.workingDirectory,
                environment: Self.environment(overrides: command.environmentOverrides)
            )
        } catch let failure as ProcessLaunchFailure {
            throw GitHubError.launchFailed(arguments: command.arguments, reason: failure.reason)
        }

        guard command.acceptableExitCodes.contains(result.exitCode) else {
            throw GitHubError.commandFailed(
                GitFailure(
                    program: "gh",
                    arguments: command.arguments,
                    workingDirectory: command.workingDirectory?.path,
                    exitCode: result.exitCode,
                    stdout: result.stdoutText,
                    stderr: result.stderrText
                )
            )
        }
        return result
    }

    /// The user's environment plus the settings that keep gh non-interactive: no
    /// prompts (which would hang with no terminal attached), no colour codes in output
    /// the app parses, and no update-check noise on stderr.
    private static func environment(overrides: [String: String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        environment["GH_PAGER"] = "cat"
        environment["PAGER"] = "cat"
        environment["NO_COLOR"] = "1"
        environment["CLICOLOR"] = "0"
        // gh shells out to git to push; keep that non-interactive too.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        for (key, value) in overrides {
            environment[key] = value
        }
        return environment
    }
}
