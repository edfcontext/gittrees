import Foundation

/// The single place where Git argument vectors are constructed.
///
/// Views and view models call these methods; they never see or supply raw Git
/// arguments. Every method takes a repository or worktree URL, which becomes the
/// process working directory and therefore decides which worktree Git acts on.
public final class GitClient: Sendable {
    private let runner: any GitRunning

    public init(runner: any GitRunning = GitProcessRunner()) {
        self.runner = runner
    }

    // MARK: - Repository discovery

    /// Resolves any directory inside a repository — including a linked worktree — to the
    /// repository it belongs to.
    ///
    /// This is what keeps sibling worktrees from appearing as unrelated repositories:
    /// the identity is the shared git directory, and the main worktree is always the
    /// first record `git worktree list` reports.
    public func discoverRepository(at directory: URL) async throws -> Repository {
        let inside = try? await run(["rev-parse", "--is-inside-work-tree"], in: directory)
        let isBareRepo: Bool
        if inside?.trimmedStdout == "true" {
            isBareRepo = false
        } else {
            let bare = try? await run(["rev-parse", "--is-bare-repository"], in: directory)
            guard bare?.trimmedStdout == "true" else {
                throw GitError.notARepository(path: directory.path)
            }
            isBareRepo = true
        }

        let commonDir = try await run(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"],
            in: directory
        ).trimmedStdout
        guard !commonDir.isEmpty else {
            throw GitError.notARepository(path: directory.path)
        }

        let entries = try await worktrees(repository: directory)
        let main = entries.first
        let mainPath = main?.path ?? URL(fileURLWithPath: commonDir).deletingLastPathComponent()

        return Repository(
            mainWorktreePath: mainPath,
            commonGitDir: URL(fileURLWithPath: commonDir),
            isBare: isBareRepo || (main?.isBare ?? false)
        )
    }

    // MARK: - Worktrees

    public func worktrees(repository: URL) async throws -> [Worktree] {
        let result = try await run(["worktree", "list", "--porcelain", "-z"], in: repository)
        return try WorktreeParser.parse(result.stdout)
    }

    /// `git worktree add <path> <branch>` — check out an existing branch in a new worktree.
    public func createWorktree(
        repository: URL,
        path: URL,
        checkingOut branch: String
    ) async throws {
        _ = try await run(["worktree", "add", path.path, branch], in: repository)
    }

    /// `git worktree add -b <newBranch> <path> [<startPoint>]` — branch and worktree at once.
    public func createWorktree(
        repository: URL,
        path: URL,
        newBranch: String,
        startingAt startPoint: String?
    ) async throws {
        var arguments = ["worktree", "add", "-b", newBranch, path.path]
        if let startPoint, !startPoint.isEmpty {
            arguments.append(startPoint)
        }
        _ = try await run(arguments, in: repository)
    }

    /// `git worktree add --detach <path> <commit>`.
    public func createDetachedWorktree(repository: URL, path: URL, at commit: String) async throws {
        _ = try await run(["worktree", "add", "--detach", path.path, commit], in: repository)
    }

    /// `git worktree remove [--force] <path>`. Force is never the default: the caller
    /// must have checked for local changes and asked the user.
    public func removeWorktree(repository: URL, path: URL, force: Bool = false) async throws {
        var arguments = ["worktree", "remove"]
        if force { arguments.append("--force") }
        arguments.append(path.path)
        _ = try await run(arguments, in: repository)
    }

    public func lockWorktree(repository: URL, path: URL, reason: String?) async throws {
        var arguments = ["worktree", "lock"]
        if let reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments.append(contentsOf: ["--reason", reason])
        }
        arguments.append(path.path)
        _ = try await run(arguments, in: repository)
    }

    public func unlockWorktree(repository: URL, path: URL) async throws {
        _ = try await run(["worktree", "unlock", path.path], in: repository)
    }

    /// `git worktree prune` — drops administrative records for worktrees whose
    /// directories are gone. Never touches files on disk.
    public func pruneWorktrees(repository: URL) async throws -> String {
        let result = try await run(["worktree", "prune", "--verbose"], in: repository)
        return result.stdoutText + result.stderrText
    }

    // MARK: - Branches

    /// `%00` is `for-each-ref`'s escape for a literal NUL byte, giving the same
    /// unambiguous field separation that `-z` provides elsewhere.
    static let branchFormat = [
        "%(refname)",
        "%(objectname)",
        "%(upstream)",
        "%(upstream:track,nobracket)",
        "%(worktreepath)",
        "%(HEAD)"
    ].joined(separator: "%00")

    public func branches(repository: URL) async throws -> [Branch] {
        let result = try await run(
            [
                "for-each-ref",
                "--format=\(Self.branchFormat)",
                "refs/heads",
                "refs/remotes"
            ],
            in: repository
        )
        return try BranchParser.parse(result.stdout)
    }

    /// The short name of the branch checked out in `worktree`, or nil when detached.
    public func currentBranch(worktree: URL) async throws -> String? {
        let result = try await run(
            ["symbolic-ref", "--quiet", "--short", "HEAD"],
            in: worktree,
            acceptableExitCodes: [0, 1]
        )
        let name = result.trimmedStdout
        return name.isEmpty ? nil : name
    }

    /// True when the repository has at least one commit. Guards operations that
    /// cannot work on an unborn HEAD.
    public func hasCommits(worktree: URL) async throws -> Bool {
        let result = try await run(
            ["rev-parse", "--verify", "--quiet", "HEAD"],
            in: worktree,
            acceptableExitCodes: [0, 1]
        )
        return result.exitCode == 0 && !result.trimmedStdout.isEmpty
    }

    /// `git checkout <branch>` inside an existing worktree.
    ///
    /// Git refuses when the branch is already checked out elsewhere; that refusal is
    /// surfaced as a normal error rather than worked around.
    public func checkout(worktree: URL, branch: String) async throws {
        _ = try await run(["checkout", branch], in: worktree)
    }

    // MARK: - Status

    /// Spec-shaped accessor returning only the changed paths.
    public func status(worktree: URL) async throws -> [FileChange] {
        try await statusSummary(worktree: worktree).changes
    }

    /// Full status including the branch headers used by the detail header bar.
    public func statusSummary(worktree: URL) async throws -> WorktreeStatus {
        let result = try await run(
            [
                "--no-optional-locks",
                "status",
                "--porcelain=v2",
                "-z",
                "--branch",
                "--untracked-files=all"
            ],
            in: worktree
        )
        return try StatusParser.parse(result.stdout)
    }

    /// A cheap dirtiness check for the sidebar indicators.
    ///
    /// Uses `--untracked-files=normal` so a large untracked directory costs one entry
    /// rather than a full walk, and stops caring past the first change.
    public func isDirty(worktree: URL) async throws -> Bool {
        let result = try await run(
            [
                "--no-optional-locks",
                "status",
                "--porcelain=v2",
                "-z",
                "--untracked-files=normal"
            ],
            in: worktree
        )
        return !result.stdout.isEmpty
    }

    // MARK: - Staging

    /// Stages whole files. Hunk and line staging are deliberately out of scope.
    public func stage(worktree: URL, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await run(["add", "--"] + paths, in: worktree)
    }

    public func unstage(worktree: URL, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        if try await hasCommits(worktree: worktree) {
            _ = try await run(["restore", "--staged", "--"] + paths, in: worktree)
        } else {
            // Before the first commit there is no HEAD to restore from; removing the
            // path from the index is the equivalent operation.
            _ = try await run(["rm", "--cached", "--quiet", "--"] + paths, in: worktree)
        }
    }

    // MARK: - Diff

    /// Unified diff for one path. `staged` selects `--cached` (index vs HEAD) instead of
    /// the working tree vs index comparison.
    public func diff(worktree: URL, path: String, staged: Bool, contextLines: Int = 3) async throws -> String {
        var arguments = ["diff", "--no-color", "--no-ext-diff", "-U\(contextLines)"]
        if staged { arguments.append("--cached") }
        arguments.append(contentsOf: ["--", path])
        let result = try await run(arguments, in: worktree)
        return result.stdoutText
    }

    /// Diff for an untracked file. `git diff` ignores untracked paths, so the file is
    /// compared against an empty one; exit code 1 simply means "differences found".
    public func diffUntracked(worktree: URL, path: String) async throws -> String {
        let result = try await run(
            ["diff", "--no-color", "--no-ext-diff", "--no-index", "--", "/dev/null", path],
            in: worktree,
            acceptableExitCodes: [0, 1]
        )
        return result.stdoutText
    }

    // MARK: - Commit

    /// Commits the staged contents of the index.
    ///
    /// The message is passed as an argument rather than through an editor, and no
    /// `--no-verify` is used, so `pre-commit`, `commit-msg` and `post-commit` hooks and
    /// all commit-related configuration behave exactly as they would on the command line.
    public func commit(worktree: URL, message: String) async throws -> String {
        let result = try await run(["commit", "--message", message], in: worktree)
        return result.stdoutText + result.stderrText
    }

    // MARK: - Remotes

    public func fetch(worktree: URL, remote: String? = nil, prune: Bool = false) async throws -> String {
        var arguments = ["fetch"]
        if prune { arguments.append("--prune") }
        if let remote, !remote.isEmpty { arguments.append(remote) } else { arguments.append("--all") }
        let result = try await run(arguments, in: worktree)
        return result.stdoutText + result.stderrText
    }

    public func pull(worktree: URL) async throws -> String {
        let result = try await run(["pull"], in: worktree)
        return result.stdoutText + result.stderrText
    }

    /// Pushes the current branch. `setUpstream` adds `--set-upstream origin <branch>`
    /// for a branch that has never been pushed.
    public func push(worktree: URL, setUpstream: Bool = false, remote: String = "origin") async throws -> String {
        var arguments = ["push"]
        if setUpstream {
            guard let branch = try await currentBranch(worktree: worktree) else {
                throw GitError.unexpectedOutput(
                    reason: "cannot set an upstream for a detached HEAD",
                    arguments: arguments
                )
            }
            arguments.append(contentsOf: ["--set-upstream", remote, branch])
        }
        let result = try await run(arguments, in: worktree)
        return result.stdoutText + result.stderrText
    }

    public func remotes(repository: URL) async throws -> [String] {
        let result = try await run(["remote"], in: repository)
        return result.stdoutText
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - History

    private static let logFormat = ["%H", "%h", "%an", "%aI", "%D", "%s"].joined(separator: "%x00")

    /// A flat, chronological commit list. Rendering a commit graph is out of scope.
    public func log(worktree: URL, limit: Int = 200) async throws -> [CommitSummary] {
        let result = try await run(
            ["log", "--max-count=\(limit)", "-z", "--format=\(Self.logFormat)"],
            in: worktree,
            acceptableExitCodes: [0, 128]
        )
        // An unborn HEAD exits 128; treat it as an empty history rather than an error.
        guard result.exitCode == 0 else { return [] }

        // `-z` separates commits with NUL and `%x00` separates fields, so the stream is
        // simply six NUL-separated fields per commit.
        let fields = result.stdout
            .split(separator: 0x00, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }

        let formatter = ISO8601DateFormatter()
        var commits: [CommitSummary] = []
        var index = 0
        while index + 5 < fields.count {
            let subject = fields[index + 5].trimmingCharacters(in: .newlines)
            commits.append(
                CommitSummary(
                    hash: fields[index],
                    abbreviatedHash: fields[index + 1],
                    subject: subject,
                    authorName: fields[index + 2],
                    authorDate: formatter.date(from: fields[index + 3]) ?? Date(timeIntervalSince1970: 0),
                    refNames: fields[index + 4]
                )
            )
            index += 6
        }
        return commits
    }

    // MARK: - Execution

    @discardableResult
    private func run(
        _ arguments: [String],
        in directory: URL?,
        acceptableExitCodes: Set<Int32> = [0],
        environmentOverrides: [String: String] = [:]
    ) async throws -> GitResult {
        try await runner.run(
            GitCommand(
                arguments,
                workingDirectory: directory,
                environmentOverrides: environmentOverrides,
                acceptableExitCodes: acceptableExitCodes
            )
        )
    }
}
