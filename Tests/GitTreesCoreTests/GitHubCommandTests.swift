import Foundation
import Testing
@testable import GitTreesCore

@Suite("GitHubCommand & executable")
struct GitHubCommandTests {

    @Test("gh commands carry no git global flags")
    func noGitGlobalFlags() {
        // The whole reason gh has its own command type: git's flags would break it.
        let command = GitHubCommand(["pr", "create", "--title", "x"])
        #expect(command.arguments == ["pr", "create", "--title", "x"])
        #expect(!command.arguments.contains("--no-pager"))
        #expect(!command.arguments.contains("color.ui=false"))
    }

    @Test("arguments stay separate elements, so a title with spaces is one argument")
    func argumentsAreNotShellStrings() {
        let title = "Fix: the thing; rm -rf * & echo"
        let command = GitHubCommand(["pr", "create", "--title", title])
        #expect(command.arguments.filter { $0 == title }.count == 1)
    }

    @Test("a missing gh executable is refused before anything is launched")
    func missingExecutableIsRefused() async {
        let runner = GitHubProcessRunner(executablePath: "/nonexistent/bin/gh")
        do {
            _ = try await runner.run(GitHubCommand(["--version"]))
            Issue.record("running a missing gh should have thrown")
        } catch let error as GitHubError {
            guard case .executableNotFound(let path) = error else {
                Issue.record("expected executableNotFound, got \(error)")
                return
            }
            #expect(path == "/nonexistent/bin/gh")
            #expect(error.recoverySuggestion?.contains("brew install gh") == true)
        } catch {
            Issue.record("expected GitHubError, got \(error)")
        }
    }

    @Test("the default gh path is one of the known install locations")
    func defaultPathIsKnown() {
        #expect(GitHubProcessRunner.knownExecutablePaths.contains(GitHubProcessRunner.defaultExecutablePath))
        #expect(GitHubProcessRunner.defaultExecutablePath.hasPrefix("/"))
    }

    @Test("a failed gh command labels the command line as gh, not git")
    func failureLabelsGh() {
        let failure = GitFailure(
            program: "gh",
            arguments: ["pr", "create"],
            workingDirectory: "/repo",
            exitCode: 1,
            stdout: "",
            stderr: "must be on a branch"
        )
        #expect(failure.commandLine == "gh pr create")
        #expect(GitHubError.commandFailed(failure).failure?.exitCode == 1)
    }
}

@Suite("PullRequest model")
struct PullRequestModelTests {

    @Test("gh JSON decodes directly into a PullRequest")
    func decodesRealJSON() throws {
        let json = """
        {"baseRefName":"main","headRefName":"feature/x","isDraft":true,"number":42,"state":"OPEN","title":"Add x","url":"https://github.com/o/r/pull/42"}
        """
        let pr = try JSONDecoder().decode(PullRequest.self, from: Data(json.utf8))
        #expect(pr.number == 42)
        #expect(pr.isOpen)
        #expect(pr.isDraft)
        #expect(pr.stateLabel == "Draft")
        #expect(pr.shortDescription == "#42 · main ← feature/x")
    }

    @Test(
        "state maps to a readable label",
        arguments: [
            ("OPEN", false, "Open"),
            ("OPEN", true, "Draft"),
            ("MERGED", false, "Merged"),
            ("CLOSED", false, "Closed")
        ]
    )
    func stateLabels(state: String, draft: Bool, expected: String) {
        let pr = PullRequest(
            number: 1, url: "u", title: "t", state: state,
            isDraft: draft, baseRefName: "main", headRefName: "x"
        )
        #expect(pr.stateLabel == expected)
        #expect(pr.isOpen == (state == "OPEN"))
    }

    @Test("GitHubAuth summarises its readiness")
    func authSummary() {
        #expect(GitHubAuth().summary == "GitHub CLI not found")
        #expect(GitHubAuth(isInstalled: true).summary == "Installed, but not signed in")
        let ready = GitHubAuth(isInstalled: true, isAuthenticated: true, account: "octocat", host: "github.com")
        #expect(ready.isReady)
        #expect(ready.summary == "Signed in to github.com as octocat")
    }
}
