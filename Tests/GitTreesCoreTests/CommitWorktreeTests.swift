import Foundation
import Testing
@testable import GitTreesCore

@MainActor
@Suite("Worktrees from history commits")
struct CommitWorktreeTests {
    @MainActor
    struct Fixture {
        let git: GitClientIntegrationTests.Fixture
        let service: RepositoryService
        let preferences: PreferencesService
        let commit: CommitSummary
        let defaults: UserDefaults
        let defaultsName: String

        init() async throws {
            git = try await GitClientIntegrationTests.Fixture()
            defaultsName = "com.gittrees.commit-worktree-tests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: defaultsName)!
            preferences = PreferencesService(defaults: defaults)
            preferences.autoFetchOnActivation = false
            preferences.historyCurrentBranchOnly = false
            service = RepositoryService(preferences: preferences)

            // The selected commit is behind HEAD and has no branch or tag of its own.
            try git.write("historical version\n", to: "README.md")
            try await git.git(["commit", "-am", "historical commit", "--quiet"])
            let history = try await git.client.log(worktree: git.repository, limit: 1)
            commit = try #require(history.first)
            try git.write("current version\n", to: "README.md")
            try await git.git(["commit", "-am", "current commit", "--quiet"])
            await service.open(directory: git.repository)
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: defaultsName)
            git.cleanUp()
        }

        func request(mode: NewWorktreeRequest.Mode) throws -> NewWorktreeRequest {
            let repository = try #require(service.repository)
            var request = NewWorktreeRequest(mode: mode, path: git.root, openInEditor: false)
            request.path = WorktreePathSuggester.availablePath(
                WorktreePathSuggester.suggestedPath(
                    worktreeRoot: preferences.worktreeRoot(for: repository),
                    branch: request.checkoutName
                )
            )
            return request
        }
    }

    @Test("a detached worktree uses the exact historical commit and preserves dirty source state",
          arguments: [false, true])
    func detachedCommit(customRoot: Bool) async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let repository = try #require(fixture.service.repository)
        if customRoot {
            fixture.preferences.setWorktreeRoot(
                fixture.git.root.appendingPathComponent("custom worktrees"), for: repository
            )
        }
        try fixture.git.write("staged change\n", to: "src/a.txt")
        try await fixture.git.git(["add", "src/a.txt"])
        try fixture.git.write("unstaged change\n", to: "README.md")
        try fixture.git.write("untracked\n", to: "notes.txt")
        let sourceStatus = try await fixture.git.client.statusSummary(worktree: fixture.git.repository)
        let sourceHead = try await fixture.git.client.headCommit(worktree: fixture.git.repository)
        let branches = fixture.service.localBranches
        let request = try fixture.request(mode: .detachedCommit(fixture.commit.hash))
        #expect(request.branchName.isEmpty)
        #expect(request.path == fixture.preferences.worktreeRoot(for: repository)
            .appendingPathComponent("commit-\(fixture.commit.hash.prefix(12))", isDirectory: true))

        let created = try #require(await fixture.service.createWorktree(request))
        #expect(fixture.service.lastError == nil)
        #expect(created.isDetached)
        #expect(created.branchName == nil)
        #expect(created.head == fixture.commit.hash)
        #expect(fixture.service.selectedWorktree?.id == created.id)
        #expect(fixture.service.localBranches == branches)
        #expect(try String(contentsOf: created.path.appendingPathComponent("README.md"),
                           encoding: .utf8) == "historical version\n")
        #expect(try await fixture.git.client.isDirty(worktree: created.path) == false)
        #expect(try await fixture.git.client.headCommit(worktree: fixture.git.repository) == sourceHead)
        let after = try await fixture.git.client.statusSummary(worktree: fixture.git.repository)
        #expect(after == sourceStatus)
        #expect(try String(contentsOf: fixture.git.repository.appendingPathComponent("README.md"),
                           encoding: .utf8) == "unstaged change\n")
    }

    @Test("a new branch can start at the selected historical commit")
    func newBranchAtCommit() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let request = try fixture.request(mode: .newBranch(
            name: "feature/from-history", startPoint: fixture.commit.hash
        ))
        let created = try #require(await fixture.service.createWorktree(request))
        #expect(fixture.service.lastError == nil)
        #expect(!created.isDetached)
        #expect(created.branchName == "feature/from-history")
        #expect(created.head == fixture.commit.hash)
        #expect(fixture.service.mainWorktree?.branchName == "main")
    }

    @Test("an invalid commit fails without creating a worktree or changing selection")
    func invalidCommit() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let selection = fixture.service.selectedWorktreePath
        let worktrees = fixture.service.worktrees
        let request = try fixture.request(mode: .detachedCommit(String(repeating: "0", count: 40)))
        #expect(await fixture.service.createWorktree(request) == nil)
        #expect(fixture.service.lastError?.title == "Could Not Create Worktree")
        #expect(fixture.service.worktrees == worktrees)
        #expect(fixture.service.selectedWorktreePath == selection)
        #expect(!FileManager.default.fileExists(atPath: request.path.path))
    }

    @Test("explicit move and copy also work with a detached historical checkout",
          arguments: [NewWorktreeRequest.UncommittedChanges.move, .copy])
    func transferToCommit(changes: NewWorktreeRequest.UncommittedChanges) async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        try fixture.git.write("staged change\n", to: "src/a.txt")
        try await fixture.git.git(["add", "src/a.txt"])
        var request = try fixture.request(mode: .detachedCommit(fixture.commit.hash))
        request.uncommittedChanges = changes
        let created = try #require(await fixture.service.createWorktree(request))
        #expect(fixture.service.lastError == nil)
        #expect(created.isDetached)
        #expect(created.head == fixture.commit.hash)
        let targetStatus = try await fixture.git.client.statusSummary(worktree: created.path)
        #expect(targetStatus.stagedChanges.map(\.path) == ["src/a.txt"])
        #expect(try String(contentsOf: created.path.appendingPathComponent("src/a.txt"),
                           encoding: .utf8) == "staged change\n")
        #expect(try await fixture.git.client.isDirty(worktree: fixture.git.repository) == (changes == .copy))
        let stashes = try await fixture.git.git(["stash", "list"])
        #expect(stashes.stdout.isEmpty)
    }
}
