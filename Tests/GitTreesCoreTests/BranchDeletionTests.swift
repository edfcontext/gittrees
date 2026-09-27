import Foundation
import Testing
@testable import GitTreesCore

@Suite("Branch deletion")
struct BranchDeletionTests {
    @Test("deletes a merged local branch and preserves the remote-tracking branch")
    func mergedBranch() async throws {
        let fixture = try await GitClientIntegrationTests.Fixture()
        defer { fixture.cleanUp() }
        let name = "feature/topic;literal"
        try await fixture.git(["branch", name])
        try await fixture.git(["update-ref", "refs/remotes/origin/\(name)", "HEAD"])
        try await fixture.client.deleteBranch(repository: fixture.repository, name: name)
        let branches = try await fixture.client.branches(repository: fixture.repository)
        #expect(!branches.contains { $0.refName == "refs/heads/\(name)" })
        #expect(branches.contains { $0.refName == "refs/remotes/origin/\(name)" })
        #expect(branches.contains { $0.refName == "refs/heads/main" })
    }

    @Test("unmerged work is kept unless force is explicitly requested")
    func unmergedBranch() async throws {
        let fixture = try await GitClientIntegrationTests.Fixture()
        defer { fixture.cleanUp() }
        try await fixture.git(["checkout", "-b", "unfinished"])
        try await fixture.git(["commit", "--allow-empty", "-m", "unique work"])
        try await fixture.git(["checkout", "main"])
        do {
            try await fixture.client.deleteBranch(repository: fixture.repository, name: "unfinished")
            Issue.record("Normal deletion must refuse unmerged commits")
        } catch is GitError {}
        let before = try await fixture.client.branches(repository: fixture.repository)
        #expect(before.contains { $0.name == "unfinished" })
        try await fixture.client.deleteBranch(repository: fixture.repository, name: "unfinished", force: true)
        let after = try await fixture.client.branches(repository: fixture.repository)
        #expect(!after.contains { $0.name == "unfinished" })
    }

    @Test("force cannot delete a branch checked out in the main or a linked worktree")
    func checkedOutBranches() async throws {
        let fixture = try await GitClientIntegrationTests.Fixture()
        defer { fixture.cleanUp() }
        let linked = fixture.worktreeRoot("linked")
        try await fixture.client.createWorktree(repository: fixture.repository, path: linked,
                                               newBranch: "linked", startingAt: "main")
        for name in ["main", "linked"] {
            do {
                try await fixture.client.deleteBranch(repository: fixture.repository, name: name, force: true)
                Issue.record("Force deletion must refuse a checked-out branch")
            } catch is GitError {}
        }
        let branches = try await fixture.client.branches(repository: fixture.repository)
        #expect(branches.contains { $0.name == "main" })
        #expect(branches.contains { $0.name == "linked" })
        #expect(FileManager.default.fileExists(atPath: linked.path))
    }

    @Test("service refreshes the branch list after deleting and protects checked-out branches")
    @MainActor
    func serviceDeletion() async throws {
        let fixture = try await MergeTests.Fixture()
        defer { fixture.cleanUp() }
        try await fixture.git(["branch", "finished"], in: fixture.work)
        try await fixture.fullRefresh()
        let finished = try #require(fixture.service.localBranches.first { $0.name == "finished" })
        #expect(fixture.service.branchDeletionBlocker(finished) == nil)
        #expect(await fixture.service.deleteBranch(finished))
        #expect(!fixture.service.localBranches.contains { $0.name == "finished" })
        let main = try #require(fixture.service.localBranches.first { $0.name == "main" })
        #expect(fixture.service.branchDeletionBlocker(main) != nil)
        #expect(await fixture.service.deleteBranch(main, force: true) == false)
        #expect(fixture.service.lastError?.title == "Cannot Delete Branch")
    }

    @Test("service reports Git refusals and rejects stale or remote branch requests")
    @MainActor
    func serviceRefusals() async throws {
        let fixture = try await MergeTests.Fixture()
        defer { fixture.cleanUp() }
        try await fixture.branchChangingFile("unfinished", contents: "unique work\n")
        let branch = try #require(fixture.service.localBranches.first { $0.name == "unfinished" })
        #expect(await fixture.service.deleteBranch(branch) == false)
        #expect(fixture.service.lastError?.title == "Could Not Delete Branch")
        #expect(fixture.service.localBranches.contains { $0.name == "unfinished" })
        var stale = branch
        stale.objectName = "old-tip"
        #expect(await fixture.service.deleteBranch(stale, force: true) == false)
        #expect(fixture.service.lastError?.title == "Branch Has Changed")
        let remote = Branch(refName: "refs/remotes/origin/main", name: "origin/main",
                            kind: .remote, objectName: branch.objectName)
        #expect(fixture.service.branchDeletionBlocker(remote) != nil)
        #expect(await fixture.service.deleteBranch(branch, force: true))
    }
}
