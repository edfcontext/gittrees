import Foundation

/// The single place where GitHub CLI argument vectors are constructed.
///
/// Mirrors `GitClient`: views and view models call these methods and never see raw gh
/// arguments. Each method takes a worktree or repository URL, which becomes the process
/// working directory — so gh acts on the branch that worktree has checked out.
public final class GitHubClient: Sendable {
    private struct ActionsJobDetails: Decodable {
        struct Step: Decodable {
            let name: String
            let number: Int
            let conclusion: String?
        }
        let steps: [Step]?
    }

    /// The JSON fields requested from `gh pr view`; must match `PullRequest`'s keys.
    static let pullRequestFields = "number,url,title,state,isDraft,baseRefName,headRefName,headRefOid,author,baseRefOid,changedFiles"

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

    public func openPullRequests(directory: URL, limit: Int) async throws -> [PullRequest] {
        let result = try await runner.run(
            GitHubCommand(
                ["pr", "list", "--state", "open", "--limit", String(limit), "--json", Self.pullRequestFields],
                workingDirectory: directory
            )
        )
        do {
            return try JSONDecoder().decode([PullRequest].self, from: result.stdout)
        } catch {
            throw GitHubError.unexpectedOutput(reason: "could not decode the open pull request list")
        }
    }

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

    /// Looks up a specific PR by number or URL, including closed and merged PRs.
    public func pullRequest(_ reference: String, directory: URL) async throws -> PullRequest {
        let result = try await runner.run(
            GitHubCommand(
                ["pr", "view", "--json", Self.pullRequestFields, "--", reference],
                workingDirectory: directory
            )
        )
        return try Self.decodePullRequest(result.stdout)
    }

    public func openPullRequestInBrowser(worktree: URL, reference: String? = nil) async throws {
        var arguments = ["pr", "view", "--web"]
        if let reference { arguments += ["--", reference] }
        _ = try await runner.run(GitHubCommand(arguments, workingDirectory: worktree))
    }

    public func pullRequestChecks(_ request: PullRequest, directory: URL) async throws -> [PullRequestCheck] {
        let arguments = ["pr", "checks", "--json", "name,workflow,state,bucket,event,description,link", "--", request.url]
        let result = try await runner.run(GitHubCommand(arguments, workingDirectory: directory, acceptableExitCodes: [0, 1, 8]))
        if let checks = try? JSONDecoder().decode([PullRequestCheck].self, from: result.stdout) {
            return checks
        }
        if result.exitCode == 1 && result.stderrText.hasPrefix("no checks reported") { return [] }
        if result.exitCode != 0 {
            throw GitHubError.commandFailed(GitFailure(
                program: "gh", arguments: arguments, workingDirectory: directory.path, exitCode: result.exitCode,
                stdout: result.stdoutText, stderr: result.stderrText
            ))
        }
        throw GitHubError.unexpectedOutput(reason: "could not decode the PR checks")
    }

    public func pullRequestCheckDetails(
        _ check: PullRequestCheck, request: PullRequest, directory: URL
    ) async throws -> PullRequestCheckDetails {
        guard let job = check.actionsJob(for: request) else {
            throw GitHubError.unexpectedOutput(reason: "this check does not identify a GitHub Actions job")
        }
        async let annotations = check.hasFailed ? checkFailureAnnotations(job, directory: directory) : []
        let steps = try await failedSteps(job, directory: directory)
        return await PullRequestCheckDetails(failedSteps: steps.map(\.name), annotations: annotations)
    }

    private func failedSteps(_ job: GitHubActionsJob, directory: URL) async throws -> [ActionsJobDetails.Step] {
        let result = try await runner.run(GitHubCommand(
            ["api", "--hostname", job.repository.host, job.apiPath],
            workingDirectory: directory
        ))
        guard let details = try? JSONDecoder().decode(ActionsJobDetails.self, from: result.stdout) else {
            throw GitHubError.unexpectedOutput(reason: "could not decode the Actions job")
        }
        return (details.steps ?? []).filter { $0.conclusion == "failure" }
    }

    private func checkFailureAnnotations(_ job: GitHubActionsJob, directory: URL) async -> [PullRequestCheckAnnotation] {
        let path = "repos/\(job.repository.name)/check-runs/\(job.id)/annotations?per_page=100"
        guard let result = try? await runner.run(GitHubCommand(
            ["api", "--hostname", job.repository.host, "--paginate", "--slurp", path],
            workingDirectory: directory
        )), let pages = try? JSONDecoder().decode([[PullRequestCheckAnnotation]].self, from: result.stdout)
        else { return [] }
        return pages.joined().filter { $0.level == "failure" }
    }

    public func pullRequestCheckLog(
        _ check: PullRequestCheck, request: PullRequest, failedOnly: Bool, directory: URL
    ) async throws -> String {
        guard let job = check.actionsJob(for: request) else {
            throw GitHubError.unexpectedOutput(reason: "this check does not identify a GitHub Actions job")
        }
        if !failedOnly {
            return try await actionsLog(host: job.repository.host, path: "\(job.apiPath)/logs", directory: directory)
        }

        let steps = try await failedSteps(job, directory: directory)
        var logs: [String] = []
        for step in steps {
            let log = try await actionsLog(
                host: job.repository.host, path: "\(job.apiPath)/steps/\(step.number)/logs", directory: directory
            )
            if !log.isEmpty { logs.append("\(step.name)\n\(log)") }
        }
        return logs.joined(separator: "\n")
    }

    private func actionsLog(host: String, path: String, directory: URL) async throws -> String {
        // The API streams raw logs, which may contain terminal controls. Keep them
        // out of the text viewer while preserving the original log lines.
        let result = try await runner.run(GitHubCommand(
            ["api", "--hostname", host, "--allow-escape-sequences",
             "-H", "X-GitHub-Api-Version: 2026-03-10", path],
            workingDirectory: directory
        ))
        let unstyled = result.stdoutText.replacingOccurrences(
            of: "\u{001B}(?:\\[[0-?]*[ -/]*[@-~]|\\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\\\))",
            with: "", options: .regularExpression
        )
        return String(unstyled.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\r" || scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar)
        })
    }

    public func pullRequestChanges(_ request: PullRequest, directory: URL) async throws -> PullRequestChanges {
        // The files endpoint follows the live PR. Confirm its revision after reading
        // every page, and retry once if a push or retarget happened while loading.
        var expected = request
        for _ in 0..<2 {
            let target = try Self.pullRequestAPITarget(expected)
            let result = try await runner.run(GitHubCommand(
                ["api", "--hostname", target.host, "--paginate", "--slurp", "\(target.path)/files?per_page=100"],
                workingDirectory: directory
            ))
            let current = try await pullRequest(expected.url, directory: directory)
            if current.hasSameRevision(as: expected) {
                do {
                    let pages = try JSONDecoder().decode([[PullRequestFile]].self, from: result.stdout)
                    return PullRequestChanges(request: current, files: pages.flatMap { $0 })
                } catch {
                    throw GitHubError.unexpectedOutput(reason: "could not decode the changed files")
                }
            }
            expected = current
        }
        throw GitHubError.pullRequestChanged
    }

    public func perform(
        _ action: PullRequestAction, on pr: PullRequest, directory: URL
    ) async throws -> GitResult {
        guard pr.isOpen, !pr.isDraft else {
            throw GitHubError.unexpectedOutput(reason: "the pull request must be open and ready for review")
        }

        let arguments: [String]
        switch action {
        case .approve:
            if let head = pr.headRefOid, !head.isEmpty {
                let target = try Self.pullRequestAPITarget(pr)
                let current = try await pullRequest(pr.url, directory: directory)
                guard current.hasSameRevision(as: pr), current.isOpen, !current.isDraft else {
                    throw GitHubError.pullRequestChanged
                }
                arguments = [
                    "api", "--hostname", target.host, "--method", "POST", "\(target.path)/reviews",
                    "--raw-field", "event=APPROVE", "--raw-field", "commit_id=\(head)"
                ]
            } else {
                arguments = ["pr", "review", "--approve", "--", pr.url]
            }
        case .merge(let method):
            guard let head = pr.headRefOid, !head.isEmpty else {
                throw GitHubError.unexpectedOutput(reason: "reload the pull request to verify its head commit")
            }
            arguments = ["pr", "merge", "--\(method.rawValue)", "--match-head-commit", head, "--", pr.url]
        }
        return try await runner.run(GitHubCommand(arguments, workingDirectory: directory))
    }

    private static func pullRequestAPITarget(_ pr: PullRequest) throws -> (host: String, path: String) {
        guard let repository = GitHubRepositoryURL(pr.url), repository.path.count == 2,
              repository.path[0] == "pull", Int(repository.path[1]) == pr.number, pr.number > 0 else {
            throw GitHubError.unexpectedOutput(reason: "invalid pull request URL")
        }
        return (repository.host, "repos/\(repository.name)/pulls/\(pr.number)")
    }

    private static func decodePullRequest(_ data: Data) throws -> PullRequest {
        do {
            return try JSONDecoder().decode(PullRequest.self, from: data)
        } catch {
            throw GitHubError.unexpectedOutput(reason: "could not decode pull request JSON")
        }
    }
}
