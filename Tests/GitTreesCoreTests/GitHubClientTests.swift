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

    @Test("an explicit PR lookup decodes the GitHub author and head commit")
    func explicitPullRequestLookup() async throws {
        let runner = MockGitHubRunner()
        runner.responder = { _ in
            .init(stdout: """
                {"number":88,"url":"https://github.com/o/r/pull/88","title":"Docs","state":"OPEN","isDraft":false,"baseRefName":"main","headRefName":"topic","headRefOid":"abc123","author":{"login":"Octocat","name":""}}
                """, stderr: "", exitCode: 0)
        }
        let client = GitHubClient(runner: runner)
        let url = "https://github.com/o/r/pull/88"

        let pr = try await client.pullRequest(url, directory: Self.worktree)

        #expect(pr.isAuthored(by: "octocat"))
        #expect(!pr.isAuthored(by: "reviewer"))
        #expect(pr.headRefOid == "abc123")
        #expect(runner.commands.first?.arguments == [
            "pr", "view", "--json", GitHubClient.pullRequestFields, "--", url
        ])
        #expect(runner.commands.first?.acceptableExitCodes == [0])
    }

    @Test("the repository list requests open PRs with the fields needed for review and merge",
          arguments: [false, true])
    func openPullRequestList(isEmpty: Bool) async throws {
        let runner = MockGitHubRunner()
        let request = openRequest()
        let payload = try JSONEncoder().encode(isEmpty ? [] : [request])
        runner.responder = { _ in
            .init(stdout: String(decoding: payload, as: UTF8.self), stderr: "", exitCode: 0)
        }
        let client = GitHubClient(runner: runner)

        let requests = try await client.openPullRequests(directory: Self.worktree, limit: 100)

        #expect(requests == (isEmpty ? [] : [request]))
        let command = try #require(runner.commands.first)
        #expect(command.arguments == [
            "pr", "list", "--state", "open", "--limit", "100", "--json", GitHubClient.pullRequestFields
        ])
        #expect(command.workingDirectory == Self.worktree)
    }

    @Test("approval targets the displayed repository and commit, independent of the checked-out branch")
    func approvalArguments() async throws {
        let runner = MockGitHubRunner()
        let client = GitHubClient(runner: runner)
        let pr = openRequest()
        let metadata = try JSONEncoder().encode(pr)
        runner.responder = { command in
            let output = command.arguments.first == "pr" ? String(decoding: metadata, as: UTF8.self) : ""
            return .init(stdout: output, stderr: "", exitCode: 0)
        }

        _ = try await client.perform(.approve, on: pr, directory: Self.worktree)

        let command = try #require(runner.commands.last)
        #expect(runner.commands.count == 2)
        #expect(command.arguments == [
            "api", "--hostname", "github.com", "--method", "POST", "repos/o/r/pulls/88/reviews",
            "--raw-field", "event=APPROVE", "--raw-field", "commit_id=abc123"
        ])
        #expect(command.workingDirectory == Self.worktree)
    }

    @Test("an approval from a stale review never submits a write command")
    func staleApproval() async throws {
        let runner = MockGitHubRunner()
        let client = GitHubClient(runner: runner)
        let pr = openRequest()
        var updated = pr
        updated.headRefOid = "def456"
        let metadata = try JSONEncoder().encode(updated)
        runner.responder = { _ in
            .init(stdout: String(decoding: metadata, as: UTF8.self), stderr: "", exitCode: 0)
        }

        await #expect(throws: GitHubError.self) {
            try await client.perform(.approve, on: pr, directory: Self.worktree)
        }
        #expect(runner.commands.count == 1)
        #expect(runner.commands.first?.arguments.prefix(2) == ["pr", "view"])
    }

    @Test("changed files use the selected repository URL and assemble every page")
    func changedFiles() async throws {
        let runner = MockGitHubRunner()
        let client = GitHubClient(runner: runner)
        let pr = openRequest()
        var updated = pr
        updated.baseRefOid = "updated-base"
        let metadata = try JSONEncoder().encode(updated)
        let filePages = #"""
        [
            [{"filename":"new name.swift","previous_filename":"old name.swift","status":"renamed",
              "additions":1,"deletions":1,"patch":"@@ -1 +1 @@\n-old\n+new"}],
            [{"filename":"image.png","status":"modified","additions":0,"deletions":0},
             {"filename":"large.txt","status":"added","additions":2,"deletions":0,"patch":"@@ -0,0 +1,2 @@\n+one"}]
        ]
        """#
        runner.responder = { command in
            let output = command.arguments.first == "api" ? filePages : String(decoding: metadata, as: UTF8.self)
            return .init(stdout: output, stderr: "", exitCode: 0)
        }

        let changes = try await client.pullRequestChanges(pr, directory: Self.worktree)

        #expect(changes.request == updated)
        #expect(changes.files.map(\.filename) == ["new name.swift", "image.png", "large.txt"])
        #expect(changes.files[0].previousFilename == "old name.swift")
        #expect(!changes.files[0].hasPartialPatch)
        #expect(changes.files[1].patch == nil)
        #expect(changes.files[2].hasPartialPatch)
        #expect(runner.commands.count == 4)
        #expect(runner.commands.first?.arguments == [
            "api", "--hostname", "github.com", "--paginate", "--slurp", "repos/o/r/pulls/88/files?per_page=100"
        ])
        #expect(runner.commands.first?.workingDirectory == Self.worktree)
    }

    @Test("PR checks preserve failures and pending states returned with a nonzero exit status")
    func pullRequestChecks() async throws {
        let runner = MockGitHubRunner()
        runner.responder = { _ in
            .init(stdout: """
                [{"name":"Java","workflow":"build","state":"FAILURE","bucket":"fail"},
                 {"name":"Lint","workflow":"build","state":"IN_PROGRESS","bucket":"pending"}]
                """, stderr: "", exitCode: 8)
        }
        let pr = openRequest()
        let checks = try await GitHubClient(runner: runner).pullRequestChecks(pr, directory: Self.worktree)

        #expect(checks.map(\.name) == ["Java", "Lint"])
        #expect(checks.first?.hasFailed == true)
        #expect(checks.last?.isPending == true)
        #expect(runner.commands.first?.arguments == [
            "pr", "checks", "--json", "name,workflow,state,bucket,event,description,link", "--", pr.url
        ])
        #expect(runner.commands.first?.acceptableExitCodes == [0, 1, 8])
    }

    @Test("no reported checks are empty but GitHub access failures are surfaced")
    func emptyChecks() async throws {
        let runner = MockGitHubRunner()
        let client = GitHubClient(runner: runner)
        let pr = openRequest()
        runner.responder = { _ in
            .init(stdout: "", stderr: "no checks reported on the 'topic' branch", exitCode: 1)
        }
        #expect(try await client.pullRequestChecks(pr, directory: Self.worktree).isEmpty)

        runner.responder = { _ in .init(stdout: "", stderr: "gh: HTTP 403", exitCode: 1) }
        await #expect(throws: GitHubError.self) {
            try await client.pullRequestChecks(pr, directory: Self.worktree)
        }
    }

    @Test("Actions details and logs target the linked job and fetch only failed steps in failure mode")
    func actionsLogs() async throws {
        let runner = MockGitHubRunner()
        runner.responder = { command in
            let path = command.arguments.last ?? ""
            let output: String
            if path.contains("/annotations") {
                output = """
                [[{"annotation_level":"failure","title":"Test failed","message":"assertion","path":"Tests.swift","start_line":17},
                  {"annotation_level":"warning","message":"warning","path":"Tests.swift","start_line":20}]]
                """
            } else if path.hasSuffix("/logs") {
                output = "\u{001B}[31mexpected true\u{001B}[0m\u{0007}\n"
            } else {
                output = """
                {"steps":[{"name":"Compile","number":3,"conclusion":"success"},
                          {"name":"Test","number":8,"conclusion":"failure"}]}
                """
            }
            return .init(stdout: output, stderr: "", exitCode: 0)
        }
        let client = GitHubClient(runner: runner)
        let pr = openRequest()
        let check = try JSONDecoder().decode(PullRequestCheck.self, from: Data("""
            {"name":"Java","workflow":"build","state":"FAILURE","bucket":"fail",
             "link":"https://github.com/org/fork/actions/runs/125/job/340"}
            """.utf8))

        let details = try await client.pullRequestCheckDetails(check, request: pr, directory: Self.worktree)
        let failedLog = try await client.pullRequestCheckLog(check, request: pr, failedOnly: true, directory: Self.worktree)
        let fullLog = try await client.pullRequestCheckLog(check, request: pr, failedOnly: false, directory: Self.worktree)

        #expect(details.failedSteps == ["Test"])
        #expect(details.annotations.map(\.title) == ["Test failed"])
        #expect(failedLog == "Test\nexpected true\n")
        #expect(fullLog == "expected true\n")
        #expect(runner.commands.compactMap { $0.arguments.last }.filter { $0.hasSuffix("/logs") } == [
            "repos/org/fork/actions/jobs/340/steps/8/logs", "repos/org/fork/actions/jobs/340/logs"
        ])
    }

    @Test("external checks keep their details link without being treated as an Actions job")
    func externalCheck() async throws {
        let runner = MockGitHubRunner()
        let pr = openRequest()
        let check = try JSONDecoder().decode(PullRequestCheck.self, from: Data("""
            {"name":"External","workflow":"","state":"FAILURE","bucket":"fail",
             "link":"https://ci.example.com/org/repo/actions/runs/125/job/340"}
            """.utf8))
        #expect(check.detailsURL?.host == "ci.example.com")
        #expect(!check.hasJobLogs(for: pr))
        await #expect(throws: GitHubError.self) {
            try await GitHubClient(runner: runner).pullRequestCheckLog(
                check, request: pr, failedOnly: true, directory: Self.worktree
            )
        }
        #expect(runner.commands.isEmpty)
    }

    @Test("merge pins the displayed head and uses the selected strategy", arguments: PullRequestMergeMethod.allCases)
    func mergeArguments(method: PullRequestMergeMethod) async throws {
        let runner = MockGitHubRunner()
        let client = GitHubClient(runner: runner)
        let pr = openRequest()

        _ = try await client.perform(.merge(method), on: pr, directory: Self.worktree)

        let command = try #require(runner.commands.first)
        #expect(command.arguments == [
            "pr", "merge", "--\(method.rawValue)", "--match-head-commit", "abc123", "--", pr.url
        ])
    }

    @Test("drafts, closed PRs and merges without a verified head cannot run a write command")
    func invalidWriteTargets() async {
        let runner = MockGitHubRunner()
        let client = GitHubClient(runner: runner)
        var pr = openRequest()
        pr.isDraft = true
        await #expect(throws: GitHubError.self) {
            try await client.perform(.approve, on: pr, directory: Self.worktree)
        }
        pr.isDraft = false
        pr.state = "CLOSED"
        await #expect(throws: GitHubError.self) {
            try await client.perform(.merge(.squash), on: pr, directory: Self.worktree)
        }
        pr.state = "OPEN"
        pr.headRefOid = nil
        await #expect(throws: GitHubError.self) {
            try await client.perform(.merge(.squash), on: pr, directory: Self.worktree)
        }
        #expect(runner.commands.isEmpty)
    }

    private func openRequest() -> PullRequest {
        PullRequest(
            number: 88, url: "https://github.com/o/r/pull/88", title: "Docs",
            state: "OPEN", isDraft: false, baseRefName: "main", headRefName: "topic", headRefOid: "abc123"
        )
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
