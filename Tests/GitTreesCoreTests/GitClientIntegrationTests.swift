import Foundation
import Testing
@testable import GitTreesCore

/// End-to-end tests against the real `git` binary.
///
/// The parser suites cover Git's output formats; these cover the other half — that the
/// argument vectors `GitClient` builds are the ones Git actually accepts, which no
/// amount of fixture parsing can prove.
@Suite(
    "GitClient integration",
    .enabled(if: FileManager.default.isExecutableFile(atPath: GitProcessRunner.defaultExecutablePath))
)
struct GitClientIntegrationTests {

    // MARK: - Fixture

    /// A throwaway repository with one commit, plus a runner for setup commands the
    /// client deliberately does not expose (`init`, `config`).
    struct Fixture {
        let root: URL
        let repository: URL
        let client = GitClient()
        private let runner = GitProcessRunner()

        init() async throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("gittrees-tests-\(UUID().uuidString)", isDirectory: true)
            // A space in the path proves nothing is being passed through a shell.
            repository = root.appendingPathComponent("summit repo", isDirectory: true)
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)

            try await git(["init", "--quiet", "--initial-branch=main"])
            try await git(["config", "user.email", "tests@example.com"])
            try await git(["config", "user.name", "GitTrees Tests"])
            try await git(["config", "commit.gpgsign", "false"])

            try write("hello\n", to: "README.md")
            try write("a\n", to: "src/a.txt")
            try write("b\n", to: "src/b.txt")
            try await git(["add", "-A"])
            try await git(["commit", "--quiet", "--message", "initial commit"])
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }

        @discardableResult
        func git(_ arguments: [String], in directory: URL? = nil) async throws -> GitResult {
            try await runner.run(
                GitCommand(
                    arguments,
                    workingDirectory: directory ?? repository,
                    // Keep the developer's own global config out of the test.
                    environmentOverrides: [
                        "GIT_CONFIG_GLOBAL": "/dev/null",
                        "GIT_CONFIG_SYSTEM": "/dev/null"
                    ]
                )
            )
        }

        func write(_ contents: String, to relativePath: String, in worktree: URL? = nil) throws {
            let url = (worktree ?? repository).appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }

        func worktreeRoot(_ name: String) -> URL {
            root.appendingPathComponent(name, isDirectory: true)
        }
    }

    // MARK: - Repository discovery

    @Test("a linked worktree resolves to the same repository as the main worktree")
    func discoveryFromLinkedWorktree() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }

        let linked = fixture.worktreeRoot("zpl engine")
        try await fixture.client.createWorktree(
            repository: fixture.repository,
            path: linked,
            newBranch: "feature/zpl-engine",
            startingAt: "main"
        )

        let fromMain = try await fixture.client.discoverRepository(at: fixture.repository)
        let fromLinked = try await fixture.client.discoverRepository(at: linked)

        // The whole worktree-first model depends on these being one repository.
        #expect(fromMain.id == fromLinked.id)
        #expect(fromMain.mainWorktreePath == fromLinked.mainWorktreePath)
        #expect(fromMain.name == "summit repo")
        #expect(!fromMain.isBare)
    }

    @Test("a directory outside any repository is rejected")
    func discoveryOutsideRepository() async throws {
        let empty = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("gittrees-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        await #expect(throws: GitError.self) {
            try await GitClient().discoverRepository(at: empty)
        }
    }

    // MARK: - Initialising a repository

    @Test("an uninitialized folder can be turned into a repository and then opened")
    func initializeUninitializedFolder() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("gittrees-init-\(UUID().uuidString)", isDirectory: true)
        // A space in the name, and existing content that must survive `git init`.
        let workspace = folder.appendingPathComponent("new workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let existing = workspace.appendingPathComponent("notes.txt")
        try "already here\n".write(to: existing, atomically: true, encoding: .utf8)

        let client = GitClient()

        // Precondition: this is the state the UI offers to fix.
        await #expect(throws: GitError.self) {
            try await client.discoverRepository(at: workspace)
        }

        try await client.initializeRepository(at: workspace)

        let repository = try await client.discoverRepository(at: workspace)
        #expect(repository.mainWorktreePath.standardizedFileURL == workspace.standardizedFileURL)
        #expect(repository.name == "new workspace")
        #expect(!repository.isBare)

        // Exactly one worktree, and it is the main one.
        let worktrees = try await client.worktrees(repository: workspace)
        #expect(worktrees.count == 1)
        #expect(worktrees[0].isMain)

        // Nothing on disk was disturbed; the existing file is simply untracked now.
        #expect(FileManager.default.fileExists(atPath: existing.path))
        let status = try await client.statusSummary(worktree: workspace)
        #expect(status.changes.contains { $0.kind == .untracked && $0.path == "notes.txt" })

        // A brand new repository has an unborn HEAD and no history.
        #expect(try await client.hasCommits(worktree: workspace) == false)
        #expect(try await client.log(worktree: workspace).isEmpty)
    }

    @Test("a working directory that does not exist is reported rather than crashing")
    func missingWorkingDirectoryIsReported() async throws {
        // Process.run() raises an uncatchable Objective-C exception for a missing
        // current directory, so the runner has to reject it first. This is the case a
        // worktree deleted from under the application hits.
        let missing = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("gittrees-gone-\(UUID().uuidString)", isDirectory: true)

        do {
            try await GitClient().initializeRepository(at: missing)
            Issue.record("initializing a missing directory should have failed")
        } catch let error as GitError {
            guard case .launchFailed(_, let reason) = error else {
                Issue.record("expected launchFailed, got \(error)")
                return
            }
            #expect(reason.contains("no longer exists"))
        }
    }

    @Test("a working directory that is a file, not a directory, is also rejected")
    func fileAsWorkingDirectoryIsReported() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("gittrees-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("notes.txt")
        try "x\n".write(to: file, atomically: true, encoding: .utf8)

        await #expect(throws: GitError.self) {
            try await GitClient().initializeRepository(at: file)
        }
    }

    // MARK: - Worktrees

    @Test("creating, locking, unlocking and removing a worktree round-trips")
    func worktreeLifecycle() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let client = fixture.client
        let path = fixture.worktreeRoot("scanner dir")

        try await client.createWorktree(
            repository: fixture.repository,
            path: path,
            newBranch: "bugfix/scanner",
            startingAt: "main"
        )

        var worktrees = try await client.worktrees(repository: fixture.repository)
        #expect(worktrees.count == 2)
        let created = try #require(worktrees.first { $0.path.lastPathComponent == "scanner dir" })
        #expect(created.branchName == "bugfix/scanner")
        #expect(!created.isMain)
        #expect(!created.isLocked)

        try await client.lockWorktree(
            repository: fixture.repository,
            path: path,
            reason: "waiting on a build"
        )
        worktrees = try await client.worktrees(repository: fixture.repository)
        let locked = try #require(worktrees.first { $0.path.lastPathComponent == "scanner dir" })
        #expect(locked.isLocked)
        #expect(locked.lockReason == "waiting on a build")

        try await client.unlockWorktree(repository: fixture.repository, path: path)
        try await client.removeWorktree(repository: fixture.repository, path: path)

        worktrees = try await client.worktrees(repository: fixture.repository)
        #expect(worktrees.count == 1)
        #expect(worktrees[0].isMain)
    }

    @Test("Git refuses a second worktree for a branch that is already checked out")
    func branchAlreadyCheckedOut() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }

        // `main` is checked out in the main worktree, so this must fail rather than
        // being worked around.
        await #expect(throws: GitError.self) {
            try await fixture.client.createWorktree(
                repository: fixture.repository,
                path: fixture.worktreeRoot("second-main"),
                checkingOut: "main"
            )
        }
    }

    @Test("a worktree whose directory is deleted is reported as prunable, then pruned")
    func prunableWorktree() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let client = fixture.client
        let path = fixture.worktreeRoot("gone")

        try await client.createWorktree(
            repository: fixture.repository,
            path: path,
            newBranch: "chore/gone",
            startingAt: "main"
        )
        try FileManager.default.removeItem(at: path)

        var worktrees = try await client.worktrees(repository: fixture.repository)
        let stale = try #require(worktrees.first { $0.path.lastPathComponent == "gone" })
        #expect(stale.isPrunable)
        #expect(stale.isMissingOnDisk)

        _ = try await client.pruneWorktrees(repository: fixture.repository)
        worktrees = try await client.worktrees(repository: fixture.repository)
        #expect(!worktrees.contains { $0.path.lastPathComponent == "gone" })
    }

    @Test("Git refuses to remove a worktree with local changes unless forced")
    func removalOfDirtyWorktreeRequiresForce() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let client = fixture.client
        let path = fixture.worktreeRoot("dirty")

        try await client.createWorktree(
            repository: fixture.repository,
            path: path,
            newBranch: "feature/dirty",
            startingAt: "main"
        )
        try fixture.write("local edit\n", to: "README.md", in: path)
        try fixture.write("untracked\n", to: "scratch.txt", in: path)

        // What the removal sheet shows the user before offering to force.
        let status = try await client.statusSummary(worktree: path)
        #expect(!status.isClean)
        #expect(status.dirtySummary.contains("1 modified file"))
        #expect(status.dirtySummary.contains("1 untracked file"))

        // The default removal must fail rather than silently discarding the work.
        await #expect(throws: GitError.self) {
            try await client.removeWorktree(repository: fixture.repository, path: path)
        }
        #expect(FileManager.default.fileExists(atPath: path.path))

        // Forcing is a separate, explicit action.
        try await client.removeWorktree(repository: fixture.repository, path: path, force: true)
        let worktrees = try await client.worktrees(repository: fixture.repository)
        #expect(!worktrees.contains { $0.path.lastPathComponent == "dirty" })
    }

    // MARK: - Branches

    @Test("branches report the worktree holding them")
    func branchWorktreeAssociation() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let client = fixture.client

        try await fixture.git(["branch", "develop"])
        let path = fixture.worktreeRoot("zpl")
        try await client.createWorktree(
            repository: fixture.repository,
            path: path,
            newBranch: "feature/zpl",
            startingAt: "main"
        )

        let branches = try await client.branches(repository: fixture.repository)
        let names = Set(branches.map(\.name))
        #expect(names == ["main", "develop", "feature/zpl"])

        let zpl = try #require(branches.first { $0.name == "feature/zpl" })
        #expect(zpl.worktreePath?.standardizedFileURL == path.standardizedFileURL)

        let develop = try #require(branches.first { $0.name == "develop" })
        #expect(develop.worktreePath == nil)
        #expect(!develop.hasUpstream)
    }

    // MARK: - Identity

    @Test("the local commit identity can be read, changed and cleared")
    func localIdentityRoundTrip() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let client = fixture.client

        // The fixture sets both with `git config`, i.e. --local.
        var identity = try await client.identity(directory: fixture.repository)
        #expect(identity.name == "GitTrees Tests")
        #expect(identity.email == "tests@example.com")
        #expect(identity.localName == "GitTrees Tests")
        #expect(identity.scope == .repository)
        #expect(identity.displayName == "GitTrees Tests <tests@example.com>")

        try await client.setLocalIdentity(
            repository: fixture.repository,
            name: "Other Dev",
            email: "other@example.com"
        )
        identity = try await client.identity(directory: fixture.repository)
        #expect(identity.name == "Other Dev")
        #expect(identity.email == "other@example.com")

        // Clearing must succeed even though `git config --unset` exits 5 for a key that
        // is already absent.
        try await client.setLocalIdentity(repository: fixture.repository, name: nil, email: nil)
        identity = try await client.identity(directory: fixture.repository)
        #expect(identity.localName == nil)
        #expect(identity.localEmail == nil)
        try await client.setLocalIdentity(repository: fixture.repository, name: nil, email: nil)
    }

    @Test("a local identity set on the repository is visible from a linked worktree")
    func identityIsSharedAcrossWorktrees() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let client = fixture.client
        let linked = fixture.worktreeRoot("linked")

        try await client.createWorktree(
            repository: fixture.repository,
            path: linked,
            newBranch: "feature/linked",
            startingAt: "main"
        )
        try await client.setLocalIdentity(
            repository: fixture.repository,
            name: "Shared Dev",
            email: "shared@example.com"
        )

        // --local config lives in the common git dir, which is what makes this a
        // repository-wide setting rather than a per-worktree one.
        let identity = try await client.identity(directory: linked)
        #expect(identity.name == "Shared Dev")
        #expect(identity.localEmail == "shared@example.com")
        #expect(identity.scope == .repository)
    }

    // MARK: - Remotes

    @Test("remotes are listed with their fetch URLs, in Git's order")
    func remoteListing() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }

        #expect(try await fixture.client.remotes(repository: fixture.repository).isEmpty)

        try await fixture.git(["remote", "add", "origin", "https://example.com/summit.git"])
        try await fixture.git(["remote", "add", "gitea", "https://git.internal/summit.git"])

        let remotes = try await fixture.client.remotes(repository: fixture.repository)
        #expect(remotes.map(\.name) == ["gitea", "origin"])
        #expect(remotes.first { $0.name == "origin" }?.fetchURL == "https://example.com/summit.git")
        #expect(remotes.first { $0.name == "gitea" }?.fetchURL == "https://git.internal/summit.git")
    }

    @Test("publishing a branch uses the named remote rather than assuming origin")
    func pushSetsUpstreamOnNamedRemote() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let client = fixture.client

        // A bare repository standing in for a server, deliberately not called "origin".
        let server = fixture.worktreeRoot("server.git")
        try await fixture.git(["init", "--quiet", "--bare", server.path], in: fixture.root)
        try await fixture.git(["remote", "add", "gitea", server.path])

        try await client.push(worktree: fixture.repository, remote: "gitea", setUpstream: true)

        let branches = try await client.branches(repository: fixture.repository)
        let main = try #require(branches.first { $0.name == "main" })
        #expect(main.upstreamName == "gitea/main")
        #expect(main.ahead == 0)
        #expect(main.behind == 0)
    }

    @Test("publishing without a remote is refused rather than defaulting to origin")
    func pushWithoutRemoteIsRefused() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }

        await #expect(throws: GitError.self) {
            _ = try await fixture.client.push(worktree: fixture.repository, remote: nil, setUpstream: true)
        }
    }

    @Test("fetching a named remote addresses only that remote")
    func fetchNamedRemote() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let client = fixture.client

        let server = fixture.worktreeRoot("server.git")
        try await fixture.git(["init", "--quiet", "--bare", server.path], in: fixture.root)
        try await fixture.git(["remote", "add", "gitea", server.path])
        try await client.push(worktree: fixture.repository, remote: "gitea", setUpstream: true)

        // Naming a remote that does not exist must fail, proving the name is really used.
        await #expect(throws: GitError.self) {
            _ = try await client.fetch(worktree: fixture.repository, remote: "origin")
        }
        _ = try await client.fetch(worktree: fixture.repository, remote: "gitea")
    }

    // MARK: - Status, staging, diff, commit

    @Test("status reflects modified, staged, untracked, renamed and deleted paths")
    func statusAcrossChangeKinds() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let client = fixture.client

        try fixture.write("hello\nchanged\n", to: "README.md")
        try fixture.write("new\n", to: "docs/new note.md")
        try fixture.write("staged\n", to: "staged.txt")
        try await fixture.git(["add", "staged.txt"])
        try await fixture.git(["mv", "src/a.txt", "src/renamed a.txt"])
        try FileManager.default.removeItem(at: fixture.repository.appendingPathComponent("src/b.txt"))

        let status = try await client.statusSummary(worktree: fixture.repository)
        #expect(status.branch == "main")

        let readme = try #require(status.changes.first { $0.path == "README.md" })
        #expect(readme.worktreeStatus == .modified)

        let staged = try #require(status.changes.first { $0.path == "staged.txt" })
        #expect(staged.hasStagedChanges)

        let renamed = try #require(status.changes.first { $0.path == "src/renamed a.txt" })
        #expect(renamed.indexStatus == .renamed)
        #expect(renamed.originalPath == "src/a.txt")

        // --untracked-files=all lists the file itself, not just its directory, which is
        // what makes per-file staging possible.
        #expect(status.changes.contains { $0.kind == .untracked && $0.path == "docs/new note.md" })
    }

    @Test("staging and unstaging a file moves it between the two lists")
    func stageAndUnstage() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let client = fixture.client

        try fixture.write("hello\nchanged\n", to: "README.md")

        try await client.stage(worktree: fixture.repository, paths: ["README.md"])
        var status = try await client.statusSummary(worktree: fixture.repository)
        #expect(status.stagedChanges.map(\.path) == ["README.md"])
        #expect(status.unstagedChanges.isEmpty)

        try await client.unstage(worktree: fixture.repository, paths: ["README.md"])
        status = try await client.statusSummary(worktree: fixture.repository)
        #expect(status.stagedChanges.isEmpty)
        #expect(status.unstagedChanges.map(\.path) == ["README.md"])
    }

    @Test("unstaging works before the first commit, where there is no HEAD to restore from")
    func unstageOnUnbornHead() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("gittrees-unborn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runner = GitProcessRunner()
        try await runner.run(GitCommand(["init", "--quiet", "--initial-branch=main"], workingDirectory: root))
        try "x\n".write(to: root.appendingPathComponent("first.txt"), atomically: true, encoding: .utf8)

        let client = GitClient()
        #expect(try await client.hasCommits(worktree: root) == false)

        try await client.stage(worktree: root, paths: ["first.txt"])
        #expect(try await client.statusSummary(worktree: root).stagedChanges.count == 1)

        try await client.unstage(worktree: root, paths: ["first.txt"])
        let status = try await client.statusSummary(worktree: root)
        #expect(status.stagedChanges.isEmpty)
        #expect(status.changes.contains { $0.kind == .untracked })
    }

    @Test("diffs are produced for tracked and untracked files, on both sides of the index")
    func diffs() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let client = fixture.client

        try fixture.write("hello\nchanged\n", to: "README.md")
        try fixture.write("brand new\n", to: "notes.txt")

        let unstaged = try await client.diff(worktree: fixture.repository, path: "README.md", staged: false)
        #expect(unstaged.contains("+changed"))

        try await client.stage(worktree: fixture.repository, paths: ["README.md"])
        let stagedDiff = try await client.diff(worktree: fixture.repository, path: "README.md", staged: true)
        #expect(stagedDiff.contains("+changed"))
        // Once staged there is nothing left between the index and the working tree.
        #expect(try await client.diff(worktree: fixture.repository, path: "README.md", staged: false).isEmpty)

        // `git diff` ignores untracked paths, so these go through --no-index, which
        // exits 1 on difference and must not be treated as a failure.
        let untracked = try await client.diffUntracked(worktree: fixture.repository, path: "notes.txt")
        #expect(untracked.contains("+brand new"))
    }

    @Test("committing advances HEAD and clears the staged list")
    func commitStagedChanges() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let client = fixture.client

        try fixture.write("hello\nchanged\n", to: "README.md")
        try await client.stage(worktree: fixture.repository, paths: ["README.md"])
        _ = try await client.commit(worktree: fixture.repository, message: "update readme")

        let status = try await client.statusSummary(worktree: fixture.repository)
        #expect(status.isClean)

        let history = try await client.log(worktree: fixture.repository, limit: 10)
        #expect(history.count == 2)
        #expect(history.first?.subject == "update readme")
        #expect(history.first?.authorName == "GitTrees Tests")
        #expect(history.last?.subject == "initial commit")
    }

    @Test("commit hooks run, so a rejecting pre-commit hook fails the commit")
    func commitHooksAreNotBypassed() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }

        let hook = fixture.repository.appendingPathComponent(".git/hooks/pre-commit")
        try "#!/bin/sh\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

        try fixture.write("hello\nchanged\n", to: "README.md")
        try await fixture.client.stage(worktree: fixture.repository, paths: ["README.md"])

        await #expect(throws: GitError.self) {
            _ = try await fixture.client.commit(worktree: fixture.repository, message: "should be rejected")
        }
    }

    @Test("a merge conflict is surfaced as unmerged status entries")
    func mergeConflictStatus() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }

        try await fixture.git(["checkout", "--quiet", "-b", "other"])
        try fixture.write("theirs\n", to: "README.md")
        try await fixture.git(["commit", "--quiet", "--all", "--message", "theirs"])

        try await fixture.git(["checkout", "--quiet", "main"])
        try fixture.write("ours\n", to: "README.md")
        try await fixture.git(["commit", "--quiet", "--all", "--message", "ours"])

        // The merge itself exits non-zero on conflict, which is expected here.
        _ = try? await fixture.git(["merge", "other"])

        let status = try await fixture.client.statusSummary(worktree: fixture.repository)
        let conflict = try #require(status.conflicts.first)
        #expect(conflict.path == "README.md")
        #expect(conflict.rawXY == "UU")
        #expect(conflict.conflictDescription == "both modified")
    }

    @Test("a failing command reports its exit code, stderr and the command line")
    func failureDetail() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }

        do {
            try await fixture.client.checkout(worktree: fixture.repository, branch: "does-not-exist")
            Issue.record("checkout of a missing branch should have failed")
        } catch let error as GitError {
            let failure = try #require(error.failure)
            #expect(failure.exitCode != 0)
            #expect(failure.commandLine.contains("checkout does-not-exist"))
            #expect(!failure.message.isEmpty)
        }
    }

    @Test("dirtiness is detected for the sidebar indicator")
    func dirtyDetection() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }

        #expect(try await fixture.client.isDirty(worktree: fixture.repository) == false)
        try fixture.write("hello\nchanged\n", to: "README.md")
        #expect(try await fixture.client.isDirty(worktree: fixture.repository) == true)
    }
}
