import Foundation
import Testing
@testable import GitTreesCore

@MainActor
@Suite("Unavailable worktree selection")
struct UnavailableWorktreeTests {
    @MainActor
    struct Fixture {
        let git: GitClientIntegrationTests.Fixture
        let service: RepositoryService
        let linked: URL
        let defaults: UserDefaults
        let defaultsName: String

        init(nested: Bool = false) async throws {
            git = try await GitClientIntegrationTests.Fixture()
            linked = nested
                ? git.repository.appendingPathComponent("nested checkout", isDirectory: true)
                : git.worktreeRoot("linked checkout")
            try await git.client.createWorktree(repository: git.repository, path: linked,
                                               newBranch: "topic", startingAt: "main")
            defaultsName = "com.gittrees.unavailable-worktree-tests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: defaultsName)!
            let preferences = PreferencesService(defaults: defaults)
            preferences.autoFetchOnActivation = false
            preferences.historyCurrentBranchOnly = false
            service = RepositoryService(preferences: preferences)
            await service.open(directory: git.repository)
            try await waitUntil { !service.history.isEmpty }
        }

        func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(15)
            while !condition(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(condition(), "Timed out waiting for repository state")
        }

        func expectUnavailable() {
            #expect(service.lastError == nil)
            #expect(service.status == .empty)
            #expect(service.history.isEmpty)
            #expect(service.mergeOperation == .none)
            #expect(service.selectedFile == nil)
            #expect(service.selectedFileKeys.isEmpty)
        }

        func cleanUp() {
            service.closeRepository()
            defaults.removePersistentDomain(forName: defaultsName)
            git.cleanUp()
        }
    }

    @Test("prunable selections stay visible without repeated status alerts",
          arguments: [false, true])
    func prunableSelection(removeDirectory: Bool) async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let removed = removeDirectory ? fixture.linked : fixture.linked.appendingPathComponent(".git")
        try FileManager.default.removeItem(at: removed)
        await fixture.service.open(directory: fixture.git.repository)
        let stale = try #require(fixture.service.worktrees.first { $0.branchName == "topic" })
        #expect(stale.isPrunable)
        #expect(stale.isMissingOnDisk == removeDirectory)
        fixture.service.selectedWorktreePath = stale.id

        for _ in 0..<3 {
            fixture.service.lastError = nil // Like dismissing the alert and returning to the window.
            fixture.service.refreshSelectedWorktree()
            fixture.service.refreshOnWindowActivation()
            try await Task.sleep(for: .milliseconds(400))
            try await fixture.waitUntil { !fixture.service.isRefreshing }
            fixture.expectUnavailable()
            #expect(fixture.service.selectedWorktreePath == stale.id)
        }
        #expect(try await fixture.git.client.worktrees(repository: fixture.git.repository).contains { $0.id == stale.id })
        if !removeDirectory {
            #expect(try String(contentsOf: fixture.linked.appendingPathComponent("README.md"), encoding: .utf8) == "hello\n")
        }
    }

    @Test("a checkout losing its git file clears loaded state even before metadata reload",
          arguments: [false, true])
    func metadataDisappears(nested: Bool) async throws {
        let fixture = try await Fixture(nested: nested)
        defer { fixture.cleanUp() }
        fixture.service.selectedWorktreePath = fixture.linked.path
        try fixture.git.write("local edit\n", to: "README.md", in: fixture.linked)
        fixture.service.refreshSelectedWorktree()
        try await fixture.waitUntil { !fixture.service.status.isClean }
        let change = try #require(fixture.service.status.unstagedChanges.first)
        fixture.service.selectedFileKeys = [WorktreeStatus.selectionKey(path: change.path, staged: false)]
        fixture.service.focusSelectedFile(resettingSide: true)

        try FileManager.default.removeItem(at: fixture.linked.appendingPathComponent(".git"))
        #expect(fixture.service.selectedWorktree?.isPrunable == false) // The list is still the old snapshot.
        fixture.service.refreshSelectedWorktree()
        try await fixture.service.refreshIdentity()
        try await Task.sleep(for: .milliseconds(200))
        fixture.expectUnavailable()
        #expect(fixture.service.identity == .unknown)
    }

    @Test("repairing a prunable checkout restores normal refresh without changing selection")
    func repairedWorktree() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let gitFile = fixture.linked.appendingPathComponent(".git")
        let original = try Data(contentsOf: gitFile)
        try FileManager.default.removeItem(at: gitFile)
        await fixture.service.open(directory: fixture.git.repository)
        fixture.service.selectedWorktreePath = fixture.linked.path
        try await Task.sleep(for: .milliseconds(200))
        fixture.expectUnavailable()

        try original.write(to: gitFile)
        fixture.service.refresh()
        try await fixture.waitUntil {
            fixture.service.selectedWorktree?.isPrunable == false
                && fixture.service.status.branch == "topic" && !fixture.service.history.isEmpty
        }
        #expect(fixture.service.selectedWorktreePath == fixture.linked.path)
        #expect(fixture.service.status.branch == "topic")
        #expect(fixture.service.lastError == nil)

        fixture.service.selectedWorktreePath = fixture.git.repository.path
        try await fixture.waitUntil { fixture.service.status.branch == "main" && !fixture.service.history.isEmpty }
        #expect(fixture.service.lastError == nil)
    }

    @Test("unexpected status failures in a live checkout are still reported")
    func genuineStatusFailure() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let index = fixture.git.repository.appendingPathComponent(".git/index")
        try Data("broken index".utf8).write(to: index)
        fixture.service.refreshSelectedWorktree()
        try await fixture.waitUntil { fixture.service.lastError != nil }
        #expect(fixture.service.lastError?.title == "Could Not Read Status")
    }
}
