import Foundation
import Testing
@testable import GitTreesCore

@MainActor
@Suite(
    "Rebase a branch",
    .enabled(if: FileManager.default.isExecutableFile(atPath: GitProcessRunner.defaultExecutablePath))
)
struct RebaseTests {
    @Test("rebase rewrites only the current branch onto the chosen local or remote base",
          arguments: [false, true])
    func direction(remote: Bool) async throws {
        let fixture = try await MergeTests.Fixture()
        defer { fixture.cleanUp() }
        try await fixture.branchAddingFile("base", named: "base.txt", contents: "base content\n")
        try await fixture.commitHere(contents: "local commit\n")
        let original = try await fixture.git(["rev-parse", "HEAD"], in: fixture.work)
        let baseHead = try await fixture.git(["rev-parse", "base"], in: fixture.work)
        try await fixture.git(["branch", "keep-original"], in: fixture.work)
        try await fixture.git(["config", "rebase.updateRefs", "true"], in: fixture.work)
        let ref = remote ? "refs/remotes/origin/base" : "refs/heads/base"
        if remote {
            try await fixture.git(["update-ref", ref, baseHead], in: fixture.work)
        }
        try await fixture.fullRefresh()
        let base = try #require(fixture.service.mergeCandidates.first { $0.refName == ref })

        #expect(fixture.service.canRebase)
        await fixture.service.rebase(onto: base)

        let current = try await fixture.git(["branch", "--show-current"], in: fixture.work)
        let head = try await fixture.git(["rev-parse", "HEAD"], in: fixture.work)
        let parent = try await fixture.git(["rev-parse", "HEAD^"], in: fixture.work)
        let unchangedBase = try await fixture.git(["rev-parse", ref], in: fixture.work)
        let unchangedOther = try await fixture.git(["rev-parse", "keep-original"], in: fixture.work)
        #expect(fixture.service.lastError == nil)
        #expect(current == "main")
        #expect(head != original)
        #expect(parent == baseHead)
        #expect(unchangedBase == baseHead)
        #expect(unchangedOther == original)
        #expect(try fixture.fileContents() == "local commit\n")
        #expect(try fixture.fileContents("base.txt") == "base content\n")
    }

    @Test("a conflicting rebase exposes conflicts and abort restores the original branch")
    func conflictAndAbort() async throws {
        let fixture = try await MergeTests.Fixture()
        defer { fixture.cleanUp() }
        try await fixture.branchChangingFile("base", contents: "line1\nline2\nBASE\n")
        try await fixture.commitHere(contents: "line1\nline2\nLOCAL\n")
        let original = try await fixture.git(["rev-parse", "HEAD"], in: fixture.work)
        let base = try #require(fixture.branch(named: "base"))

        await fixture.service.rebase(onto: base)
        try await fixture.waitUntil {
            fixture.service.mergeOperation == .rebase && !fixture.service.status.conflicts.isEmpty
        }

        #expect(fixture.service.mergeOperation == .rebase)
        #expect(fixture.service.status.conflicts.map(\.path) == ["file.txt"])
        #expect(!fixture.service.canMerge)
        #expect(!fixture.service.canRebase)
        #expect(!fixture.service.canContinueRebase)

        await fixture.service.abortMerge()
        try await fixture.waitUntil { fixture.service.mergeOperation == .none }
        let restored = try await fixture.git(["rev-parse", "HEAD"], in: fixture.work)
        let current = try await fixture.git(["branch", "--show-current"], in: fixture.work)
        #expect(restored == original)
        #expect(current == "main")
        #expect(try fixture.fileContents() == "line1\nline2\nLOCAL\n")
        #expect(fixture.service.mergeOperation == .none)
    }

    @Test("dirty work is preserved even if autostash is configured and displayed status is stale")
    func dirtyWork() async throws {
        let fixture = try await MergeTests.Fixture()
        defer { fixture.cleanUp() }
        try await fixture.branchAddingFile("base", named: "base.txt", contents: "base\n")
        let base = try #require(fixture.branch(named: "base"))
        let original = try await fixture.git(["rev-parse", "HEAD"], in: fixture.work)
        try await fixture.git(["config", "rebase.autoStash", "true"], in: fixture.work)
        try fixture.write("uncommitted work\n", to: "file.txt")

        await fixture.service.rebase(onto: base)
        try await fixture.waitUntil { !fixture.service.status.isClean }

        let head = try await fixture.git(["rev-parse", "HEAD"], in: fixture.work)
        #expect(head == original)
        #expect(try fixture.fileContents() == "uncommitted work\n")
        #expect(!fixture.exists("base.txt"))
        #expect(!fixture.service.canRebase)
        #expect(fixture.service.mergeOperation == .none)
    }

    @Test("detached worktrees cannot start a merge or rebase")
    func detachedWorktree() async throws {
        let fixture = try await MergeTests.Fixture()
        defer { fixture.cleanUp() }
        try await fixture.branchAddingFile("base", named: "base.txt", contents: "base\n")
        try await fixture.git(["checkout", "--detach"], in: fixture.work)
        try await fixture.fullRefresh()

        #expect(!fixture.service.canMerge)
        #expect(!fixture.service.canRebase)
    }
}
