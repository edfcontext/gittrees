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

    /// Runs `git init` in an existing directory.
    ///
    /// The initial branch name is deliberately not forced: Git takes it from the user's
    /// `init.defaultBranch` configuration, exactly as `git init` on the command line
    /// would. Re-running it on an existing repository is safe — Git reinitialises rather
    /// than discarding anything — but callers should only reach here after
    /// `discoverRepository` has said the directory is not in a repository.
    public func initializeRepository(at directory: URL) async throws {
        _ = try await run(["init"], in: directory)
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

    // MARK: - Identity

    /// Reads both the resolved and the repository-local commit identity.
    ///
    /// `git config --get` exits 1 when a key is unset, which is a normal answer here
    /// rather than a failure.
    public func identity(directory: URL) async throws -> GitIdentity {
        async let name = configValue(["--get", "user.name"], in: directory)
        async let email = configValue(["--get", "user.email"], in: directory)
        async let localName = configValue(["--local", "--get", "user.name"], in: directory)
        async let localEmail = configValue(["--local", "--get", "user.email"], in: directory)

        return try await GitIdentity(
            name: name,
            email: email,
            localName: localName,
            localEmail: localEmail
        )
    }

    /// Pins the identity on the repository with `git config --local`.
    ///
    /// `--local` config lives in the shared git directory, so this applies to every
    /// worktree of the repository. Passing nil for a field unsets it, letting the
    /// global configuration show through again.
    public func setLocalIdentity(repository: URL, name: String?, email: String?) async throws {
        try await setLocalConfig(key: "user.name", value: name, in: repository)
        try await setLocalConfig(key: "user.email", value: email, in: repository)
    }

    private func setLocalConfig(key: String, value: String?, in directory: URL) async throws {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            _ = try await run(["config", "--local", key, trimmed], in: directory)
        } else {
            // `--unset` exits 5 when the key was not set, which is the desired end state.
            _ = try await run(
                ["config", "--local", "--unset", key],
                in: directory,
                acceptableExitCodes: [0, 5]
            )
        }
    }

    private func configValue(_ arguments: [String], in directory: URL) async throws -> String? {
        let result = try await run(
            ["config"] + arguments,
            in: directory,
            acceptableExitCodes: [0, 1]
        )
        guard result.exitCode == 0 else { return nil }
        let value = result.trimmedStdout
        return value.isEmpty ? nil : value
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

    /// Fetches one remote, or every remote when `remote` is nil.
    public func fetch(worktree: URL, remote: String? = nil, prune: Bool = false) async throws -> String {
        var arguments = ["fetch"]
        if prune { arguments.append("--prune") }
        if let remote, !remote.isEmpty { arguments.append(remote) } else { arguments.append("--all") }
        let result = try await run(arguments, in: worktree)
        return result.stdoutText + result.stderrText
    }

    /// Pulls. With no remote, Git uses the branch's own tracking configuration.
    public func pull(worktree: URL, remote: String? = nil) async throws -> String {
        var arguments = ["pull"]
        if let remote, !remote.isEmpty { arguments.append(remote) }
        let result = try await run(arguments, in: worktree)
        return result.stdoutText + result.stderrText
    }

    /// Pushes the current branch.
    ///
    /// `setUpstream` adds `--set-upstream <remote> <branch>` for a branch that has never
    /// been pushed, which requires knowing which remote to publish to.
    public func push(worktree: URL, remote: String? = nil, setUpstream: Bool = false) async throws -> String {
        var arguments = ["push"]
        if setUpstream {
            guard let remote, !remote.isEmpty else {
                throw GitError.unexpectedOutput(
                    reason: "publishing a branch needs a remote to push it to",
                    arguments: arguments
                )
            }
            guard let branch = try await currentBranch(worktree: worktree) else {
                throw GitError.unexpectedOutput(
                    reason: "cannot set an upstream for a detached HEAD",
                    arguments: arguments
                )
            }
            arguments.append(contentsOf: ["--set-upstream", remote, branch])
        } else if let remote, !remote.isEmpty {
            arguments.append(remote)
        }
        let result = try await run(arguments, in: worktree)
        return result.stdoutText + result.stderrText
    }

    /// Configured remote names, in Git's order.
    public func remoteNames(repository: URL) async throws -> [String] {
        let result = try await run(["remote"], in: repository)
        return result.stdoutText
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Remotes with their fetch URLs, for display in Branch Info and the remote picker.
    public func remotes(repository: URL) async throws -> [Remote] {
        let names = try await remoteNames(repository: repository)
        guard !names.isEmpty else { return [] }

        return try await withThrowingTaskGroup(of: (Int, Remote).self) { group in
            for (index, name) in names.enumerated() {
                group.addTask { [self] in
                    // A remote can exist with no URL configured; that is not an error.
                    let result = try await run(
                        ["remote", "get-url", name],
                        in: repository,
                        acceptableExitCodes: [0, 2, 128]
                    )
                    let url = result.exitCode == 0 ? result.trimmedStdout : ""
                    return (index, Remote(name: name, fetchURL: url.isEmpty ? nil : url))
                }
            }
            var collected: [(Int, Remote)] = []
            for try await entry in group { collected.append(entry) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// `git remote add <name> <url>`.
    ///
    /// Git validates the name and rejects a duplicate itself (exit 3), so no rule about
    /// what a remote may be called is reimplemented here.
    public func addRemote(repository: URL, name: String, url: String) async throws {
        _ = try await run(["remote", "add", name, url], in: repository)
    }

    // MARK: - History

    private static let logFormat = ["%H", "%h", "%an", "%aI", "%D", "%s"].joined(separator: "%x00")
    /// Field order must match `CommitDetailParser.metadataFieldCount`.
    static let commitDetailFormat = [
        "%H", "%h", "%an", "%ae", "%aI", "%P", "%s", "%b"
    ].joined(separator: "%x00")

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

    /// Identity, message and changed files for one commit.
    ///
    /// Files are the first-parent diff (`git diff-tree`), which is what History should
    /// show for a merge: the change relative to the branch being merged into, not a
    /// combined diff. A root commit is compared to the empty tree (`--root`).
    public func commitDetail(worktree: URL, hash: String) async throws -> CommitDetail {
        let metadata = try await run(
            ["log", "-1", "-z", "--format=\(Self.commitDetailFormat)", hash],
            in: worktree
        )
        var detail = try CommitDetailParser.parseMetadata(metadata.stdout)

        var arguments = ["diff-tree", "--no-commit-id", "-r", "-z", "-M", "--name-status"]
        if let parent = detail.parentHashes.first {
            arguments.append(contentsOf: [parent, detail.hash])
        } else {
            arguments.append(contentsOf: ["--root", detail.hash])
        }
        let nameStatus = try await run(arguments, in: worktree)
        detail.files = try CommitDetailParser.parseNameStatus(nameStatus.stdout)
        return detail
    }

    /// Unified diff of one path as introduced by `hash`.
    ///
    /// `--first-parent` matches `commitDetail`'s file list for merge commits. `--format=`
    /// suppresses the commit header so the pane is only the patch, like the Changes tab.
    public func commitDiff(
        worktree: URL,
        hash: String,
        path: String,
        contextLines: Int = 3
    ) async throws -> String {
        let result = try await run(
            [
                "show",
                "--no-color",
                "--no-ext-diff",
                "--first-parent",
                "--format=",
                "-U\(contextLines)",
                hash,
                "--",
                path
            ],
            in: worktree
        )
        return result.stdoutText
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
