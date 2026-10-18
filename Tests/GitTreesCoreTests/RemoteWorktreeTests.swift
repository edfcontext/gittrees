import Foundation
import Testing
@testable import GitTreesCore

@MainActor
@Suite("Worktrees from remote branches")
struct RemoteWorktreeTests {
    @MainActor
    struct Fixture {
        let git: GitClientIntegrationTests.Fixture
        let preferences: PreferencesService
        let service: RepositoryService
        let defaults: UserDefaults
        let defaultsName: String

        init(remote: String, branch: String) async throws {
            git = try await GitClientIntegrationTests.Fixture()
            defaultsName = "com.gittrees.remote-worktree-tests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: defaultsName)!
            preferences = PreferencesService(defaults: defaults)
            preferences.autoFetchOnActivation = false
            service = RepositoryService(preferences: preferences)

            let remotePath = git.root.appendingPathComponent("remote.git")
            try await git.git(["init", "--bare", "--quiet", remotePath.path])
            try await git.git(["remote", "add", remote, remotePath.path])
            try await git.git(["config", "branch.autoSetupMerge", "false"])
            try await git.git(["checkout", "--quiet", "-b", "remote-source"])
            try git.write("selected remote commit\n", to: "README.md")
            try await git.git(["add", "README.md"])
            try await git.git(["commit", "--quiet", "-m", "remote change"])
            try await git.git(["push", "--quiet", remote, "HEAD:refs/heads/\(branch)"])
            try await git.git(["checkout", "--quiet", "main"])
            try await git.git(["branch", "-D", "remote-source"])
            await service.open(directory: git.repository)
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: defaultsName)
            git.cleanUp()
        }

        func remoteBranch(_ name: String) throws -> Branch {
            try #require(service.remoteBranches.first { $0.name == name })
        }

        func request(for branch: Branch) throws -> NewWorktreeRequest {
            let repository = try #require(service.repository)
            let mode = service.suggestedWorktreeMode(for: branch)
            let request = NewWorktreeRequest(mode: mode, path: git.root, openInEditor: false)
            return NewWorktreeRequest(
                mode: mode,
                path: WorktreePathSuggester.availablePath(
                    WorktreePathSuggester.suggestedPath(
                        worktreeRoot: preferences.worktreeRoot(for: repository),
                        branch: request.branchName
                    )
                ),
                openInEditor: false
            )
        }
    }

    @Test("selected remote creates an attached tracking branch under the configured root",
          arguments: [false, true])
    func trackingBranch(customRoot: Bool) async throws {
        let fixture = try await Fixture(remote: "upstream", branch: "feature/remote-worktree")
        defer { fixture.cleanUp() }
        let repository = try #require(fixture.service.repository)
        if customRoot {
            fixture.preferences.setWorktreeRoot(
                fixture.git.root.appendingPathComponent("custom worktrees"), for: repository
            )
        }
        // A local branch with the same short name as the remote ref must not change
        // which commit is used. The UI carries the full selected ref throughout.
        try await fixture.git.git(["branch", "upstream/feature/remote-worktree", "main"])
        let branch = try fixture.remoteBranch("upstream/feature/remote-worktree")
        let request = try fixture.request(for: branch)
        #expect(request.mode == .newBranch(
            name: "feature/remote-worktree", startPoint: branch.refName
        ))
        #expect(request.path.path == fixture.preferences.worktreeRoot(for: repository)
            .appendingPathComponent("remote-worktree").path)

        let created = try #require(await fixture.service.createWorktree(request))
        #expect(fixture.service.lastError == nil)
        #expect(!created.isDetached)
        #expect(created.branchName == "feature/remote-worktree")
        #expect(created.head == branch.objectName)
        #expect(fixture.service.selectedWorktree?.id == created.id)
        #expect(fixture.service.branch(for: created)?.upstreamRef == branch.refName)
        #expect(try String(contentsOf: created.path.appendingPathComponent("README.md"),
                           encoding: .utf8) == "selected remote commit\n")
        #expect(try String(contentsOf: fixture.git.repository.appendingPathComponent("README.md"),
                           encoding: .utf8) == "hello\n")
    }

    @Test("a remote whose local name is checked out gets an available new branch")
    func occupiedLocalBranch() async throws {
        let fixture = try await Fixture(remote: "origin", branch: "main")
        defer { fixture.cleanUp() }
        let branch = try fixture.remoteBranch("origin/main")
        let request = try fixture.request(for: branch)
        #expect(request.mode == .newBranch(name: "main-worktree", startPoint: branch.refName))
        let created = try #require(await fixture.service.createWorktree(request))
        #expect(created.branchName == "main-worktree")
        #expect(created.head == branch.objectName)
        #expect(fixture.service.branch(for: created)?.upstreamRef == branch.refName)
        #expect(fixture.service.mainWorktree?.branchName == "main")
    }

    @Test("an existing local branch at another commit is preserved")
    func existingLocalBranch() async throws {
        let fixture = try await Fixture(remote: "origin", branch: "topic")
        defer { fixture.cleanUp() }
        for name in ["topic", "topic-worktree", "topic-worktree-2"] {
            try await fixture.git.git(["branch", name, "main"])
        }
        await fixture.service.open(directory: fixture.git.repository)
        let original = try #require(fixture.service.localBranches.first { $0.name == "topic" })
        let branch = try fixture.remoteBranch("origin/topic")
        let request = try fixture.request(for: branch)
        #expect(request.mode == .newBranch(name: "topic-worktree-3", startPoint: branch.refName))
        let created = try #require(await fixture.service.createWorktree(request))
        #expect(created.head == branch.objectName)
        #expect(fixture.service.branch(for: created)?.upstreamRef == branch.refName)
        #expect(fixture.service.localBranches.first { $0.name == "topic" }?.objectName == original.objectName)
    }

    @Test("an existing parent ref does not block creation from a nested remote branch")
    func parentRefCollision() async throws {
        let fixture = try await Fixture(remote: "origin", branch: "feature/remote-worktree")
        defer { fixture.cleanUp() }
        try await fixture.git.git(["branch", "feature", "main"])
        await fixture.service.open(directory: fixture.git.repository)
        let branch = try fixture.remoteBranch("origin/feature/remote-worktree")
        let request = try fixture.request(for: branch)
        #expect(request.branchName == "feature-remote-worktree-worktree")
        let created = try #require(await fixture.service.createWorktree(request))
        #expect(created.head == branch.objectName)
        #expect(fixture.service.branch(for: created)?.upstreamRef == branch.refName)
    }
}
