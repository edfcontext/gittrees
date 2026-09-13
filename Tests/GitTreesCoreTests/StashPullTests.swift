import Foundation
import Testing
@testable import GitTreesCore

/// End-to-end cover for stash → pull → re-apply, the one remote operation that is a
/// sequence with its own failure modes rather than a single command.
///
/// The safety rules are: the stash is a transport dropped only after the work is safely
/// back, a re-apply conflict is reported (not swallowed) and keeps the stash, and a clean
/// run leaves no stash behind. These drive `RepositoryService` against real clones of a
/// real bare remote, because only Git can produce the fast-forward and the conflict.
@MainActor
@Suite(
    "Stash, pull and re-apply",
    .enabled(if: FileManager.default.isExecutableFile(atPath: GitProcessRunner.defaultExecutablePath))
)
struct StashPullTests {

    @MainActor
    struct Fixture {
        let root: URL
        let remote: URL
        let work: URL
        let service: RepositoryService
        private let defaultsName: String
        private let defaults: UserDefaults
        private let runner = GitProcessRunner()

        init() async throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("gittrees-stashpull-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            remote = root.appendingPathComponent("remote.git", isDirectory: true)
            work = root.appendingPathComponent("work", isDirectory: true)

            // Every stored property is set before any instance method runs.
            defaultsName = "com.gittrees.tests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: defaultsName)!
            service = RepositoryService(preferences: PreferencesService(defaults: defaults))

            try await git(["init", "--quiet", "--bare", "--initial-branch=main", remote.path], in: root)
            try await git(["clone", "--quiet", remote.path, work.path], in: root)
            // The service runs Git with the developer's real environment, so every setting
            // the pull depends on is pinned in the clone's own config, where it wins.
            try await configure(work)

            try write("line1\nline2\nline3\n", to: "file.txt")
            try await git(["add", "-A"], in: work)
            try await git(["commit", "--quiet", "--message", "initial"], in: work)
            try await git(["push", "--quiet", "--set-upstream", "origin", "main"], in: work)

            await service.open(directory: work)
            try await settle()
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: root)
        }

        /// Pushes a remote edit to `file.txt`'s third line, so `work` falls one behind.
        func pushRemoteChange(line3: String) async throws {
            let other = root.appendingPathComponent("other-\(UUID().uuidString)", isDirectory: true)
            try await git(["clone", "--quiet", remote.path, other.path], in: root)
            try await configure(other)
            try "line1\nline2\n\(line3)\n".write(
                to: other.appendingPathComponent("file.txt"),
                atomically: true,
                encoding: .utf8
            )
            try await git(["commit", "--quiet", "--all", "--message", "remote change"], in: other)
            try await git(["push", "--quiet", "origin", "main"], in: other)
            // Let the worktree learn it is behind, the way the UI would after a fetch.
            try await git(["fetch", "--quiet"], in: work)
            service.refreshSelectedWorktree()
            try await settle()
        }

        private func configure(_ directory: URL) async throws {
            try await git(["config", "user.email", "tests@example.com"], in: directory)
            try await git(["config", "user.name", "GitTrees Tests"], in: directory)
            try await git(["config", "commit.gpgsign", "false"], in: directory)
            // Deterministic regardless of the developer's global pull settings.
            try await git(["config", "pull.rebase", "false"], in: directory)
        }

        func write(_ contents: String, to relativePath: String) throws {
            try contents.write(
                to: work.appendingPathComponent(relativePath),
                atomically: true,
                encoding: .utf8
            )
        }

        func localEdit(line1: String = "line1", line3: String = "line3") throws {
            try write("\(line1)\nline2\n\(line3)\n", to: "file.txt")
            service.refreshSelectedWorktree()
        }

        @discardableResult
        func git(_ arguments: [String], in directory: URL) async throws -> String {
            let result = try await runner.run(
                GitCommand(
                    arguments,
                    workingDirectory: directory,
                    environmentOverrides: [
                        "GIT_CONFIG_GLOBAL": "/dev/null",
                        "GIT_CONFIG_SYSTEM": "/dev/null"
                    ]
                )
            )
            return result.trimmedStdout
        }

        func stashCount() async throws -> Int {
            let list = try await git(["stash", "list"], in: work)
            return list.isEmpty ? 0 : list.split(separator: "\n").count
        }

        /// Commits a local edit so `work` moves ahead of its upstream.
        func commitLocal(line1: String = "line1", line3: String = "line3") async throws {
            try write("\(line1)\nline2\n\(line3)\n", to: "file.txt")
            try await git(["commit", "--quiet", "--all", "--message", "local commit"], in: work)
            service.refreshSelectedWorktree()
            try await settle()
        }

        /// Produces a real merge conflict on `file.txt`: local and remote both change line
        /// 3, then a merge pull collides. Leaves the service showing the conflict.
        func createMergeConflict() async throws {
            try await unsetPullRebase()
            try await commitLocal(line3: "LOCAL-3")
            try await pushRemoteChange(line3: "REMOTE-3")
            await service.pull(strategy: .merge)
            try await settle()
            try await waitUntil { !self.service.status.conflicts.isEmpty }
        }

        var conflictChange: FileChange? {
            service.status.conflicts.first { $0.path == "file.txt" }
        }

        /// Removes the reconcile preference, reproducing a machine where a divergent bare
        /// `git pull` would refuse with "Need to specify how to reconcile".
        func unsetPullRebase() async throws {
            _ = try? await git(["config", "--unset", "pull.rebase"], in: work)
        }

        /// Drops the current branch's upstream, as a branch created without tracking has.
        func unsetUpstream() async throws {
            _ = try? await git(["branch", "--unset-upstream"], in: work)
        }

        /// The current branch's upstream (`origin/main`), or nil when it has none.
        func upstream() async throws -> String? {
            let value = try? await git(
                ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
                in: work
            )
            return (value?.isEmpty ?? true) ? nil : value
        }

        /// A full reload so `branches`/`remoteBranches`/upstream state reflect the repo.
        func fullRefresh() async throws {
            service.refresh()
            try await Task.sleep(for: .milliseconds(60))
            try await settle()
        }

        func fileContents() throws -> String {
            try String(contentsOf: work.appendingPathComponent("file.txt"), encoding: .utf8)
        }

        func settle() async throws {
            for _ in 0..<200 where service.activeOperation != nil || service.isRefreshing {
                try await Task.sleep(for: .milliseconds(20))
            }
            try await Task.sleep(for: .milliseconds(60))
        }

        /// Waits until an observed condition holds — for the selected-worktree status read,
        /// which lands in a task the operation does not await, so `settle()` cannot see it.
        func waitUntil(_ condition: @MainActor () -> Bool, timeoutMs: Int = 5000) async throws {
            for _ in 0..<(timeoutMs / 20) {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    @Test("a non-overlapping local edit is stashed, the pull lands, and the edit re-applies")
    func cleanReapply() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }

        try await fixture.pushRemoteChange(line3: "REMOTE-line3")
        // The behind count is what the commit banner reads.
        try await fixture.waitUntil { fixture.service.status.behind == 1 }
        #expect(fixture.service.status.behind == 1)
        try fixture.localEdit(line1: "LOCAL-line1")
        try await fixture.settle()

        await fixture.service.stashPullAndReapply()
        try await fixture.settle()
        try await fixture.waitUntil { fixture.service.status.behind == 0 }

        // Both changes are present: the pull brought line3, the re-apply kept line1.
        let file = try String(contentsOf: fixture.work.appendingPathComponent("file.txt"), encoding: .utf8)
        #expect(file == "LOCAL-line1\nline2\nREMOTE-line3\n")
        // A clean run drops the stash and reports success, not an error.
        #expect(try await fixture.stashCount() == 0)
        #expect(fixture.service.lastError == nil)
        #expect(fixture.service.status.conflicts.isEmpty)
        #expect(fixture.service.status.behind == 0)
    }

    @Test("an overlapping edit is re-applied with conflicts, and the stash is preserved")
    func conflictingReapply() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }

        try await fixture.pushRemoteChange(line3: "REMOTE-line3")
        try fixture.localEdit(line3: "LOCAL-line3")
        try await fixture.settle()

        await fixture.service.stashPullAndReapply()
        try await fixture.settle()
        try await fixture.waitUntil { !fixture.service.status.conflicts.isEmpty }

        // The conflict is surfaced, naming the file, not swallowed.
        let error = try #require(fixture.service.lastError)
        #expect(error.title == "Re-applied With Conflicts")
        #expect(error.message.contains("file.txt"))
        #expect(fixture.service.status.conflicts.map(\.path) == ["file.txt"])
        // The stash is kept so the user can recover the original after resolving.
        #expect(try await fixture.stashCount() == 1)
        // The pull itself still landed.
        #expect(fixture.service.status.behind == 0)
    }

    @Test("with nothing to stash it is an ordinary pull that leaves no stash")
    func nothingToStash() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }

        try await fixture.pushRemoteChange(line3: "REMOTE-line3")
        // No local edit this time.
        await fixture.service.stashPullAndReapply()
        try await fixture.settle()
        try await fixture.waitUntil { fixture.service.status.behind == 0 }

        let file = try String(contentsOf: fixture.work.appendingPathComponent("file.txt"), encoding: .utf8)
        #expect(file == "line1\nline2\nREMOTE-line3\n")
        #expect(try await fixture.stashCount() == 0)
        #expect(fixture.service.lastError == nil)
        #expect(fixture.service.status.behind == 0)
    }

    // MARK: - Reconcile strategy

    @Test("a merge pull reconciles divergent branches even with no pull.rebase configured")
    func mergePullOnDivergenceWithoutConfig() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }

        // The exact machine state behind "Need to specify how to reconcile": no reconcile
        // preference set, and the branch diverged (ahead and behind).
        try await fixture.unsetPullRebase()
        try await fixture.commitLocal(line1: "LOCAL-line1")
        try await fixture.pushRemoteChange(line3: "REMOTE-line3")
        try await fixture.waitUntil { fixture.service.status.behind == 1 }
        #expect(fixture.service.status.behind == 1)

        await fixture.service.pull(strategy: .merge)
        try await fixture.settle()
        try await fixture.waitUntil { fixture.service.status.behind == 0 }

        // The explicit strategy makes the pull succeed where a bare one would have refused.
        #expect(fixture.service.lastError == nil)
        #expect(fixture.service.status.behind == 0)
        #expect(try fixture.fileContents() == "LOCAL-line1\nline2\nREMOTE-line3\n")
    }

    @Test("a fast-forward-only pull refuses a divergent branch, cleanly")
    func fastForwardOnlyPullRefusesDivergence() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }

        try await fixture.unsetPullRebase()
        try await fixture.commitLocal(line1: "LOCAL-line1")
        try await fixture.pushRemoteChange(line3: "REMOTE-line3")

        await fixture.service.pull(strategy: .fastForwardOnly)
        try await fixture.settle()

        // It fails as a reported Pull error, not a merge — and nothing was merged in.
        #expect(fixture.service.lastError?.title == "Pull Failed")
        try await fixture.waitUntil { fixture.service.status.behind == 1 }
        #expect(fixture.service.status.behind == 1)
    }

    // MARK: - No upstream

    @Test("pulling a branch with no upstream sets tracking to the matching remote branch")
    func pullSetsUpstreamWhenMissing() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }

        // A branch with no tracking config but a same-named branch on the remote.
        try await fixture.unsetUpstream()
        try await fixture.fullRefresh()
        #expect(fixture.service.selectedBranchNeedsUpstream)
        #expect(try await fixture.upstream() == nil)

        try await fixture.pushRemoteChange(line3: "REMOTE-line3")

        await fixture.service.pull()
        try await fixture.settle()

        // The upstream is now set and the remote change was pulled in.
        #expect(fixture.service.lastError == nil)
        #expect(try await fixture.upstream() == "origin/main")
        #expect(try fixture.fileContents() == "line1\nline2\nREMOTE-line3\n")
    }

    @Test("pulling a branch with no upstream and no matching remote branch explains why")
    func pullWithNoMatchingRemoteBranch() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }

        // Rename the local branch to something the remote does not have, and drop tracking.
        _ = try await fixture.git(["branch", "--move", "orphan-branch"], in: fixture.work)
        try await fixture.unsetUpstream()
        try await fixture.fullRefresh()

        await fixture.service.pull()
        try await fixture.settle()

        // A clear, actionable message rather than Git's raw "no tracking information".
        #expect(fixture.service.lastError?.title == "Pull Failed")
        #expect(fixture.service.lastError?.detail?.contains("Push this branch first") == true)
    }

    // MARK: - Conflict resolution

    @Test("a conflicting pull surfaces the conflict and the in-progress merge")
    func conflictIsSurfaced() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }

        try await fixture.createMergeConflict()

        // The failed pull still refreshed, so the conflict is visible and known to be a merge.
        #expect(fixture.service.status.conflicts.map(\.path) == ["file.txt"])
        #expect(fixture.service.mergeOperation == .merge)
    }

    @Test("Use Mine keeps this branch's side and resolves the conflict")
    func useMineKeepsOurs() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        try await fixture.createMergeConflict()
        let change = try #require(fixture.conflictChange)

        await fixture.service.resolveConflicts([change], keeping: .mine)
        try await fixture.waitUntil { fixture.service.status.conflicts.isEmpty }

        // The conflict is resolved to this branch's line. (Its content equals HEAD here,
        // so there is no staged diff to show — the merge is simply ready to commit.)
        #expect(fixture.service.status.conflicts.isEmpty)
        #expect(try fixture.fileContents() == "line1\nline2\nLOCAL-3\n")
    }

    @Test("Use Theirs takes the incoming side and resolves the conflict")
    func useTheirsTakesIncoming() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        try await fixture.createMergeConflict()
        let change = try #require(fixture.conflictChange)

        await fixture.service.resolveConflicts([change], keeping: .theirs)
        try await fixture.waitUntil { fixture.service.status.conflicts.isEmpty }

        #expect(fixture.service.status.conflicts.isEmpty)
        #expect(try fixture.fileContents() == "line1\nline2\nREMOTE-3\n")
        // Taking the incoming line differs from HEAD, so it stages as a merge change.
        #expect(fixture.service.status.stagedChanges.map(\.path) == ["file.txt"])
    }

    @Test("Discard restores the file from the branch and resolves the conflict")
    func discardRestoresFromBranch() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        try await fixture.createMergeConflict()
        let change = try #require(fixture.conflictChange)

        await fixture.service.discardConflicts([change])
        try await fixture.waitUntil { fixture.service.status.conflicts.isEmpty }

        #expect(fixture.service.status.conflicts.isEmpty)
        // HEAD is this branch's tip, which committed LOCAL-3.
        #expect(try fixture.fileContents() == "line1\nline2\nLOCAL-3\n")
    }

    @Test("Abort returns the worktree to the branch as it was before the merge")
    func abortReturnsToBranch() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        try await fixture.createMergeConflict()
        #expect(fixture.service.mergeOperation == .merge)

        await fixture.service.abortMerge()
        try await fixture.waitUntil { fixture.service.mergeOperation == .none && fixture.service.status.isClean }

        // No merge in progress, no conflict, and the branch's committed content is intact.
        #expect(fixture.service.mergeOperation == .none)
        #expect(fixture.service.status.conflicts.isEmpty)
        #expect(fixture.service.status.isClean)
        #expect(try fixture.fileContents() == "line1\nline2\nLOCAL-3\n")
        // The merge was undone, so the branch is behind its upstream again.
        try await fixture.waitUntil { fixture.service.status.behind == 1 }
        #expect(fixture.service.status.behind == 1)
    }
}
