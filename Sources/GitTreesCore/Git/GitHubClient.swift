import Foundation

/// The single place where GitHub CLI argument vectors are constructed.
///
/// Mirrors `GitClient`: views and view models call these methods and never see raw gh
/// arguments. Each method takes a worktree or repository URL, which becomes the process
/// working directory — so gh acts on the branch that worktree has checked out.
public final class GitHubClient: Sendable {
    /// The JSON fields requested from `gh pr view`; must match `PullRequest`'s keys.
    static let pullRequestFields = "number,url,title,state,isDraft,baseRefName,headRefName"

    private let runner: any GitHubRunning

    public init(runner: any GitHubRunning = GitHubProcessRunner()) {
        self.runner = runner
    }

    // MARK: - Availability

    /// Reads gh's installation and sign-in state.
    ///
    /// Never throws: "not installed" and "not signed in" are states the UI explains, so
    /// they come back as an unauthenticated `GitHubAuth`, not an error.
    public func auth(executablePath: String) async -> GitHubAuth {
        // `gh --version` is the cheapest proof the binary runs at all.
        guard (try? await runner.run(GitHubCommand(["--version"]))) != nil else {
            return GitHubAuth(isInstalled: false, executablePath: executablePath)
        }

        // `gh auth status` exits non-zero when signed out; that is not a failure here.
        guard let result = try? await runner.run(
            GitHubCommand(["auth", "status"], acceptableExitCodes: [0, 1])
        ) else {
            return GitHubAuth(isInstalled: true, executablePath: executablePath)
        }

        let text = result.stdoutText + result.stderrText
        let parsed = Self.parseAuthStatus(text)
        return GitHubAuth(
            isInstalled: true,
            isAuthenticated: result.exitCode == 0 && parsed.account != nil,
            account: parsed.account,
            host: parsed.host,
            executablePath: executablePath
        )
    }

    /// Extracts the host and account from `gh auth status` output.
    ///
    /// Handles both current gh ("Logged in to github.com account octocat") and older
    /// phrasing ("Logged in to github.com as octocat").
    static func parseAuthStatus(_ text: String) -> (host: String?, account: String?) {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let range = line.range(of: "Logged in to ") else { continue }

            let remainder = line[range.upperBound...]
            let words = remainder.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let host = words.first else { continue }

            var account: String?
            if let marker = words.firstIndex(where: { $0 == "account" || $0 == "as" }),
               marker + 1 < words.count {
                account = words[marker + 1]
            }
            return (host, account)
        }
        return (nil, nil)
    }

    /// Whether a remote URL points at GitHub. Covers `git@github.com:owner/repo.git`,
    /// `https://github.com/owner/repo`, `ssh://git@github.com/owner/repo` — and, crucially,
    /// SSH host aliases like `git@github-work:owner/repo`, which resolve to github.com via
    /// `~/.ssh/config` even though the URL never contains the string "github.com".
    public static func isGitHubRemoteURL(_ url: String) -> Bool {
        isGitHubRemoteURL(url, sshConfig: .user)
    }

    /// The alias-resolving core, with the ssh config injected so tests can supply one.
    static func isGitHubRemoteURL(_ url: String, sshConfig: SSHConfig) -> Bool {
        guard let host = remoteHost(url) else { return false }
        if host.caseInsensitiveCompare("github.com") == .orderedSame { return true }
        // Otherwise the host may be an ssh alias; ask ssh config what it connects to.
        if let resolved = sshConfig.hostName(for: host) {
            return resolved.caseInsensitiveCompare("github.com") == .orderedSame
        }
        return false
    }

    /// The host component of a git remote URL, or nil for a local path with no host.
    ///
    /// Handles the three forms git accepts: `scheme://[user@]host[:port]/path`, the
    /// scp-like `[user@]host:path`, and a bare local path (which has neither and is not a
    /// remote host).
    static func remoteHost(_ raw: String) -> String? {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }

        if let scheme = url.range(of: "://") {
            var rest = Substring(url[scheme.upperBound...])
            if let at = rest.firstIndex(of: "@") { rest = rest[rest.index(after: at)...] }
            let host = rest.prefix { $0 != "/" && $0 != ":" }
            return host.isEmpty ? nil : String(host)
        }

        // scp-like: the host is what precedes the first colon (a local path has none).
        if let colon = url.firstIndex(of: ":") {
            var head = Substring(url[..<colon])
            if let at = head.firstIndex(of: "@") { head = head[head.index(after: at)...] }
            return head.isEmpty ? nil : String(head)
        }

        return nil
    }

    // MARK: - Pull requests

    /// The pull request already open for the worktree's branch, or nil when there is
    /// none (or gh cannot resolve a GitHub repository here).
    public func pullRequest(worktree: URL) async throws -> PullRequest? {
        let result = try await runner.run(
            GitHubCommand(
                ["pr", "view", "--json", Self.pullRequestFields],
                workingDirectory: worktree,
                // No PR / not a GitHub repo exits 1; both mean "nothing to show".
                acceptableExitCodes: [0, 1]
            )
        )
        guard result.exitCode == 0 else { return nil }
        return try Self.decodePullRequest(result.stdout)
    }

    /// Opens a pull request with `gh pr create`, then reads it back as structured JSON.
    ///
    /// gh handles authentication, hooks and the push of an unpushed branch itself; the
    /// argument vector only states the title, body, base, head and draft flag.
    public func createPullRequest(worktree: URL, draft: PullRequestDraft) async throws -> PullRequest {
        var arguments = [
            "pr", "create",
            "--title", draft.title,
            "--body", draft.body,
            "--base", draft.base,
            "--head", draft.head
        ]
        if draft.isDraft { arguments.append("--draft") }

        _ = try await runner.run(GitHubCommand(arguments, workingDirectory: worktree))

        // gh pr create prints the URL as text; re-read as JSON for a structured result.
        guard let created = try await pullRequest(worktree: worktree) else {
            throw GitHubError.unexpectedOutput(
                reason: "the pull request was created but could not be read back"
            )
        }
        return created
    }

    /// Opens a pull request (or its create page) in the browser via `gh pr view --web`.
    public func openPullRequestInBrowser(worktree: URL) async throws {
        _ = try await runner.run(
            GitHubCommand(["pr", "view", "--web"], workingDirectory: worktree)
        )
    }

    private static func decodePullRequest(_ data: Data) throws -> PullRequest {
        do {
            return try JSONDecoder().decode(PullRequest.self, from: data)
        } catch {
            throw GitHubError.unexpectedOutput(reason: "could not decode pull request JSON")
        }
    }
}
