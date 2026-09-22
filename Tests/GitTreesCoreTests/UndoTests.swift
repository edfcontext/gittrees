import Foundation
import Testing
@testable import GitTreesCore

/// Cover for the recovery actions: finishing a rebase, throwing local changes away, and
/// correcting or undoing the last commit.
///
/// These are the operations where a mistake costs work, so each one is driven against a
/// real repository and checked for what survives — a discarded file is back at its
/// committed content, an undone commit leaves everything staged, and a resolved rebase can
/// actually be finished rather than only abandoned.
@MainActor
@Suite(
    "Undo, discard and amend",
    .enabled(if: FileManager.default.isExecutableFile(atPath: GitProcessRunner.defaultExecutablePath))
)
struct UndoTests {

    // MARK: - Rebase

    @Test("a conflicted rebase can be resolved and continued, not only aborted")
    func rebaseCanBeContinued() async throws {
        let fixture = try await MergeTests.Fixture()
        defer { fixture.cleanUp() }

        // main and feature both rewrite line 3, so replaying feature onto main conflicts.
        try await fixture.branchChangingFile("feature", contents: "line1\nline2\nFEATURE-3\n")
        try await fixture.commitHere(contents: "line1\nline2\nMAIN-3\n")
        try await fixture.git(["checkout", "--quiet", "feature"], in: fixture.work)
        // Exits non-zero on the conflict, which is the state under test.
        _ = try? await fixture.git(["rebase", "main"], in: fixture.work)
        try await fixture.fullRefresh()
        try await fixture.waitUntil { !fixture.service.status.conflicts.isEmpty }

        #expect(fixture.service.mergeOperation == .rebase)
        // Nothing to continue while the conflict is unresolved.
        #expect(!fixture.service.canContinueRebase)

        let change = try #require(fixture.service.status.conflicts.first)
        await fixture.service.resolveConflicts([change], keeping: .theirs)
        try await fixture.waitUntil { fixture.service.status.conflicts.isEmpty }
        #expect(fixture.service.canContinueRebase)

        await fixture.service.continueRebase()
        try await fixture.waitUntil { fixture.service.mergeOperation == .none }

        // The rebase finished rather than being thrown away.
        #expect(fixture.service.mergeOperation == .none)
        #expect(fixture.service.status.conflicts.isEmpty)
    }

    // MARK: - Discard

    @Test("discarding returns a modified file to its committed state")
    func discardModifiedFile() async throws {
        let fixture = try await MergeTests.Fixture()
        defer { fixture.cleanUp() }

        try fixture.write("line1\nline2\nEDITED\n", to: "file.txt")
        fixture.service.refreshSelectedWorktree()
        try await fixture.waitUntil { !fixture.service.status.unstagedChanges.isEmpty }
        let change = try #require(fixture.service.status.unstagedChanges.first)

        await fixture.service.discardChanges([change])
        try await fixture.waitUntil { fixture.service.status.isClean }

        let contents = try fixture.fileContents()
        #expect(contents == "line1\nline2\nline3\n")
        #expect(fixture.service.status.isClean)
    }

    @Test("discarding a staged edit also clears it from the index")
    func discardStagedEdit() async throws {
        let fixture = try await MergeTests.Fixture()
        defer { fixture.cleanUp() }

        try fixture.write("line1\nline2\nSTAGED\n", to: "file.txt")
        try await fixture.git(["add", "-A"], in: fixture.work)
        fixture.service.refreshSelectedWorktree()
        try await fixture.waitUntil { !fixture.service.status.stagedChanges.isEmpty }
        let change = try #require(fixture.service.status.stagedChanges.first)

        await fixture.service.discardChanges([change])
        try await fixture.waitUntil { fixture.service.status.isClean }

        let contents = try fixture.fileContents()
        #expect(contents == "line1\nline2\nline3\n")
        #expect(fixture.service.status.isClean)
    }

    @Test("discarding an untracked file removes it, because it has no committed state")
    func discardUntrackedFile() async throws {
        let fixture = try await MergeTests.Fixture()
        defer { fixture.cleanUp() }

        try fixture.write("scratch\n", to: "scratch.txt")
        fixture.service.refreshSelectedWorktree()
        try await fixture.waitUntil {
            fixture.service.status.unstagedChanges.contains { $0.path == "scratch.txt" }
        }
        let change = try #require(
            fixture.service.status.unstagedChanges.first { $0.path == "scratch.txt" }
        )

        await fixture.service.discardChanges([change])
        // Wait on the service, not the filesystem: the file is gone before the status
        // refresh that reflects it has landed.
        try await fixture.waitUntil { fixture.service.status.isClean }

        #expect(!fixture.exists("scratch.txt"))
        #expect(fixture.service.status.isClean)
    }

    @Test("discarding a newly added, staged file removes it from the index and disk")
    func discardStagedNewFile() async throws {
        let fixture = try await MergeTests.Fixture()
        defer { fixture.cleanUp() }

        try fixture.write("brand new\n", to: "added.txt")
        try await fixture.git(["add", "-A"], in: fixture.work)
        fixture.service.refreshSelectedWorktree()
        try await fixture.waitUntil {
            fixture.service.status.stagedChanges.contains { $0.path == "added.txt" }
        }
        let change = try #require(
            fixture.service.status.stagedChanges.first { $0.path == "added.txt" }
        )

        await fixture.service.discardChanges([change])
        try await fixture.waitUntil { fixture.service.status.isClean }

        #expect(!fixture.exists("added.txt"))
        #expect(fixture.service.status.isClean)
    }

    // MARK: - Amend and undo

    @Test("amending rewrites the last commit instead of adding one")
    func amendRewritesTheLastCommit() async throws {
        let fixture = try await MergeTests.Fixture()
        defer { fixture.cleanUp() }

        let before = try await fixture.git(["rev-list", "--count", "HEAD"], in: fixture.work)
        let committed = await fixture.service.commit(message: "corrected message", amend: true)
        try await fixture.settle()

        let after = try await fixture.git(["rev-list", "--count", "HEAD"], in: fixture.work)
        let subject = try await fixture.git(["log", "-1", "--format=%s"], in: fixture.work)
        #expect(committed)
        #expect(before == after)              // rewritten, not added to
        #expect(subject == "corrected message")
    }

    @Test("undoing the last commit keeps everything it contained staged")
    func undoKeepsTheWorkStaged() async throws {
        let fixture = try await MergeTests.Fixture()
        defer { fixture.cleanUp() }

        try fixture.write("second commit\n", to: "added.txt")
        try await fixture.git(["add", "-A"], in: fixture.work)
        try await fixture.git(["commit", "--quiet", "--message", "second"], in: fixture.work)
        try await fixture.fullRefresh()

        await fixture.service.undoLastCommit()
        try await fixture.waitUntil { !fixture.service.status.stagedChanges.isEmpty }

        let count = try await fixture.git(["rev-list", "--count", "HEAD"], in: fixture.work)
        let staged = fixture.service.status.stagedChanges.contains { $0.path == "added.txt" }
        #expect(count == "1")                 // the commit is gone
        #expect(staged)                       // but its content is not
        #expect(fixture.exists("added.txt"))
    }
}
