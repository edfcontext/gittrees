import Foundation
import Testing
@testable import GitTreesCore

/// Records the commands it is asked to run and replays scripted results, so the exact
/// `gh` argument vectors and the JSON parsing can be tested without spawning gh.
final class MockGitHubRunner: GitHubRunning, @unchecked Sendable {
    struct Stub { var stdout: String; var stderr: String; var exitCode: Int32 }

    private let lock = NSLock()
    private var _commands: [GitHubCommand] = []
    /// Matched against the joined argument vector, in order; first match wins.
    var responder: (@Sendable (GitHubCommand) -> Stub)?

    var commands: [GitHubCommand] {
        lock.withLock { _commands }
    }

    func run(_ command: GitHubCommand) async throws -> GitResult {
        lock.withLock { _commands.append(command) }
        let stub = responder?(command) ?? Stub(stdout: "", stderr: "", exitCode: 0)
        return GitResult(
            stdout: Data(stub.stdout.utf8),
            stderr: Data(stub.stderr.utf8),
            exitCode: stub.exitCode
        )
    }
}

@Suite("GitHubClient")
struct GitHubClientTests {
    static let worktree = URL(fileURLWithPath: "/tmp/summit/zpl")

    /// A real `gh pr view --json` payload, captured from `cli/cli#9000`.
    static let prJSON = """
    {"baseRefName":"trunk","headRefName":"andyfeller/flag-level-disableauth","isDraft":false,"number":9000,"state":"MERGED","title":"proof of concept for flag-level disable auth check","url":"https://github.com/cli/cli/pull/9000"}
    """

    @Test("pr create builds the documented argument vector, head and base included")
    func createArguments() async throws {
        let runner = MockGitHubRunner()
        runner.responder = { command in
            // `pr view` (the read-back) returns a PR; `pr create` returns its URL text.
            if command.arguments.contains("view") {
                return .init(stdout: Self.prJSON, stderr: "", exitCode: 0)
            }
            return .init(stdout: "https://github.com/o/r/pull/1\n", stderr: "", exitCode: 0)
        }
        let client = GitHubClient(runner: runner)

        let draft = PullRequestDraft(
            title: "Add ZPL templates",
            body: "Body text",
            base: "main",
            head: "feature/zpl",
            isDraft: true
        )
        _ = try await client.createPullRequest(worktree: Self.worktree, draft: draft)

        let create = try #require(runner.commands.first { $0.arguments.contains("create") })
        #expect(create.arguments == [
            "pr", "create",
            "--title", "Add ZPL templates",
            "--body", "Body text",
            "--base", "main",
            "--head", "feature/zpl",
            "--draft"
        ])
        // The command runs in the worktree, so gh sees that branch as HEAD.
        #expect(create.workingDirectory == Self.worktree)
    }

    @Test("a non-draft pull request omits the --draft flag")
    func nonDraftOmitsFlag() async throws {
        let runner = MockGitHubRunner()
        runner.responder = { command in
            command.arguments.contains("view")
                ? .init(stdout: Self.prJSON, stderr: "", exitCode: 0)
                : .init(stdout: "", stderr: "", exitCode: 0)
        }
        let client = GitHubClient(runner: runner)

        _ = try await client.createPullRequest(
            worktree: Self.worktree,
            draft: PullRequestDraft(title: "T", body: "", base: "main", head: "x", isDraft: false)
        )
        let create = try #require(runner.commands.first { $0.arguments.contains("create") })
        #expect(!create.arguments.contains("--draft"))
    }

    @Test("pr view decodes gh's JSON into a PullRequest")
    func pullRequestDecoding() async throws {
        let runner = MockGitHubRunner()
        runner.responder = { _ in .init(stdout: Self.prJSON, stderr: "", exitCode: 0) }
        let client = GitHubClient(runner: runner)

        let pr = try #require(try await client.pullRequest(worktree: Self.worktree))
        #expect(pr.number == 9000)
        #expect(pr.baseRefName == "trunk")
        #expect(pr.headRefName == "andyfeller/flag-level-disableauth")
        #expect(pr.state == "MERGED")
        #expect(!pr.isDraft)
        #expect(pr.url == "https://github.com/cli/cli/pull/9000")

        // The requested fields must match the type, or gh would omit some.
        let view = try #require(runner.commands.first { $0.arguments.contains("view") })
        #expect(view.arguments.contains("--json"))
        #expect(view.arguments.contains(GitHubClient.pullRequestFields))
    }

    @Test("no open pull request (gh exits 1) is reported as nil, not an error")
    func noPullRequest() async throws {
        let runner = MockGitHubRunner()
        runner.responder = { _ in
            .init(stdout: "", stderr: "no pull requests found for branch \"x\"", exitCode: 1)
        }
        let client = GitHubClient(runner: runner)

        #expect(try await client.pullRequest(worktree: Self.worktree) == nil)
    }

    @Test("auth status is parsed for the current phrasing")
    func authStatusCurrentPhrasing() {
        let text = """
        github.com
          ✓ Logged in to github.com account octocat (keyring)
          - Active account: true
          - Git operations protocol: ssh
        """
        let parsed = GitHubClient.parseAuthStatus(text)
        #expect(parsed.host == "github.com")
        #expect(parsed.account == "octocat")
    }

    @Test("auth status is parsed for the older 'as <user>' phrasing")
    func authStatusOlderPhrasing() {
        let parsed = GitHubClient.parseAuthStatus("  ✓ Logged in to github.com as octocat (oauth_token)")
        #expect(parsed.host == "github.com")
        #expect(parsed.account == "octocat")
    }

    @Test("signed-out auth status yields no account")
    func authStatusSignedOut() {
        let parsed = GitHubClient.parseAuthStatus("You are not logged into any GitHub hosts. Run gh auth login to authenticate.")
        #expect(parsed.account == nil)
    }

    @Test("auth() reports not-installed when gh cannot even be spawned")
    func authNotInstalled() async {
        // A binary that cannot run makes even `gh --version` throw.
        let auth = await GitHubClient(runner: ThrowingGitHubRunner()).auth(executablePath: "/nope/gh")
        #expect(!auth.isInstalled)
        #expect(!auth.isReady)
        #expect(auth.executablePath == "/nope/gh")
    }

    @Test("auth() reports installed-but-signed-out when status exits non-zero")
    func authSignedOut() async {
        let runner = MockGitHubRunner()
        runner.responder = { command in
            command.arguments == ["--version"]
                ? .init(stdout: "gh version 2.0.0", stderr: "", exitCode: 0)
                : .init(stdout: "", stderr: "not logged in", exitCode: 1)
        }
        let auth = await GitHubClient(runner: runner).auth(executablePath: "/opt/homebrew/bin/gh")
        #expect(auth.isInstalled)
        #expect(!auth.isAuthenticated)
    }

    @Test("isGitHubRemoteURL recognises SSH and HTTPS GitHub URLs")
    func gitHubRemoteDetection() {
        #expect(GitHubClient.isGitHubRemoteURL("git@github.com:owner/repo.git"))
        #expect(GitHubClient.isGitHubRemoteURL("https://github.com/owner/repo"))
        #expect(!GitHubClient.isGitHubRemoteURL("git@gitlab.com:owner/repo.git"))
        #expect(!GitHubClient.isGitHubRemoteURL("/local/path/repo.git"))
    }
}

/// A runner whose every call throws, standing in for a gh binary that cannot be spawned.
private struct ThrowingGitHubRunner: GitHubRunning {
    func run(_ command: GitHubCommand) async throws -> GitResult {
        throw GitHubError.executableNotFound(path: "/nope/gh")
    }
}
