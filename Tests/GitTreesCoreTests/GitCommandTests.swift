import Foundation
import Testing
@testable import GitTreesCore

@Suite("GitCommand")
struct GitCommandTests {

    @Test("every invocation carries the flags that make output machine-readable")
    func globalFlags() {
        let command = GitCommand(["status", "--porcelain=v2"])
        let arguments = command.fullArguments

        #expect(arguments.starts(with: GitCommand.globalFlags))
        #expect(arguments.contains("--no-pager"))
        #expect(arguments.contains("color.ui=false"))
        #expect(arguments.contains("core.quotepath=false"))
        #expect(arguments.suffix(2) == ["status", "--porcelain=v2"])
    }

    @Test("arguments stay separate elements, so shell metacharacters are inert")
    func argumentsAreNotShellStrings() {
        // A path a shell would mangle: spaces, a quote, a semicolon and a glob.
        let path = "/tmp/a dir/it's; rm -rf *"
        let command = GitCommand(["worktree", "add", path, "feature/x"])

        #expect(command.fullArguments.contains(path))
        // Exactly one element holds the whole path — nothing was split or escaped.
        #expect(command.fullArguments.filter { $0 == path }.count == 1)
    }

    @Test("exit codes default to zero and can be widened for commands that use them")
    func acceptableExitCodes() {
        #expect(GitCommand(["status"]).acceptableExitCodes == [0])
        #expect(GitCommand(["diff", "--no-index"], acceptableExitCodes: [0, 1]).acceptableExitCodes == [0, 1])
    }

    @Test("stdout is decoded leniently, because Git paths are bytes rather than text")
    func lenientDecoding() {
        // 0xFF is not valid UTF-8; decoding must substitute rather than fail.
        let result = GitResult(stdout: Data([0x61, 0xFF, 0x62]), stderr: Data(), exitCode: 0)

        #expect(result.stdoutText.hasPrefix("a"))
        #expect(result.stdoutText.hasSuffix("b"))
    }

    @Test("a failure carries the command line, exit code and Git's message")
    func failureDescription() {
        let failure = GitFailure(
            arguments: ["worktree", "add", "/tmp/x", "main"],
            workingDirectory: "/repo",
            exitCode: 128,
            stdout: "",
            stderr: "fatal: 'main' is already checked out at '/repo'\n"
        )

        #expect(failure.commandLine == "git worktree add /tmp/x main")
        #expect(failure.message == "fatal: 'main' is already checked out at '/repo'")
        #expect(GitError.commandFailed(failure).failure?.exitCode == 128)
    }
}
