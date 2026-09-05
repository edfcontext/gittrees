import Foundation
import Testing
@testable import GitTreesCore

/// Exercises the real `gh` binary where it is installed. These prove the argument
/// vectors are ones gh accepts and that the graceful paths (signed-out, no GitHub
/// remote) do not crash. Actually opening a pull request needs a live GitHub repo and
/// is left to the mock-runner tests.
/// The first real gh on this machine, or nil when none is installed.
private func installedGitHubCLIPath() -> String? {
    GitHubProcessRunner.knownExecutablePaths.first {
        FileManager.default.isExecutableFile(atPath: $0)
    }
}

@Suite("GitHub integration", .enabled(if: installedGitHubCLIPath() != nil))
struct GitHubIntegrationTests {

    private var ghPath: String { installedGitHubCLIPath()! }

    private var client: GitHubClient {
        GitHubClient(runner: GitHubProcessRunner(executablePath: ghPath))
    }

    @Test("auth() reports gh as installed and reads a coherent state")
    func authReportsInstalled() async {
        let auth = await client.auth(executablePath: ghPath)
        #expect(auth.isInstalled)
        // Signed in or not, the two flags must be consistent with each other.
        if auth.isAuthenticated {
            #expect(auth.account != nil)
            #expect(auth.isReady)
        } else {
            #expect(!auth.isReady)
        }
    }

    @Test("looking up a pull request in a non-GitHub repository returns nil, not a crash")
    func pullRequestLookupInPlainRepo() async throws {
        // A throwaway local repository with no remotes at all.
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("gittrees-gh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let git = GitProcessRunner()
        _ = try await git.run(GitCommand(["init", "--quiet"], workingDirectory: root))

        // gh cannot resolve a GitHub repo here, so it exits non-zero — which the client
        // must translate to "no pull request", never an error.
        let pr = try await client.pullRequest(worktree: root)
        #expect(pr == nil)
    }
}
