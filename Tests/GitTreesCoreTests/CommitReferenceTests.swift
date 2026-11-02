import Foundation
import Testing
@testable import GitTreesCore

@MainActor
@Suite("Branches and tags from history commits")
struct CommitReferenceTests {
    @MainActor
    struct Fixture {
        let git: GitClientIntegrationTests.Fixture
        let service: RepositoryService
        let commit: CommitSummary
        let defaults: UserDefaults
        let defaultsName: String

        init() async throws {
            git = try await GitClientIntegrationTests.Fixture()
            commit = try #require(try await git.client.log(worktree: git.repository, limit: 1).first)
            try git.write("current version\n", to: "README.md")
            try await git.git(["commit", "-am", "current commit", "--quiet"])
            defaultsName = "com.gittrees.commit-reference-tests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: defaultsName)!
            let preferences = PreferencesService(defaults: defaults)
            preferences.autoFetchOnActivation = false
            preferences.historyCurrentBranchOnly = false
            service = RepositoryService(preferences: preferences)
            await service.open(directory: git.repository)
        }

        func create(isTag: Bool, name: String, at hash: String) async throws {
            if isTag {
                try await git.client.createTag(repository: git.repository, name: name, at: hash)
            } else {
                try await git.client.createBranch(repository: git.repository, name: name, at: hash)
            }
        }

        func cleanUp() {
            service.closeRepository()
            defaults.removePersistentDomain(forName: defaultsName)
            git.cleanUp()
        }
    }

    @Test("creation uses the historical commit and preserves checkout, worktrees, index and local changes",
          arguments: [false, true])
    func preservesCheckout(isTag: Bool) async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        try fixture.git.write("staged\n", to: "src/a.txt")
        try await fixture.git.git(["add", "src/a.txt"])
        try fixture.git.write("unstaged\n", to: "README.md")
        try fixture.git.write("untracked\n", to: "notes.txt")
        let before = try await fixture.git.git(["status", "--porcelain=v2", "-z"])
        let worktrees = try await fixture.git.client.worktrees(repository: fixture.git.repository)
        let head = try await fixture.git.client.headCommit(worktree: fixture.git.repository)
        let name = "from-history/topic;literal"

        try await fixture.create(isTag: isTag, name: name, at: fixture.commit.hash)

        let ref = (isTag ? "refs/tags/" : "refs/heads/") + name
        let target = try await fixture.git.git(["rev-parse", "--verify", ref])
        #expect(target.trimmedStdout == fixture.commit.hash)
        #expect(target.trimmedStdout != head)
        #expect(try await fixture.git.client.currentBranch(worktree: fixture.git.repository) == "main")
        #expect(try await fixture.git.client.headCommit(worktree: fixture.git.repository) == head)
        #expect(try await fixture.git.client.worktrees(repository: fixture.git.repository) == worktrees)
        let after = try await fixture.git.git(["status", "--porcelain=v2", "-z"])
        #expect(after.stdout == before.stdout)
        #expect(try String(contentsOf: fixture.git.repository.appendingPathComponent("README.md"),
                           encoding: .utf8) == "unstaged\n")
        #expect(try String(contentsOf: fixture.git.repository.appendingPathComponent("notes.txt"),
                           encoding: .utf8) == "untracked\n")
    }

    @Test("duplicate names cannot move an existing reference", arguments: [false, true])
    func refusesOverwrite(isTag: Bool) async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let name = "existing"
        try await fixture.create(isTag: isTag, name: name, at: fixture.commit.hash)
        let head = try #require(try await fixture.git.client.headCommit(worktree: fixture.git.repository))
        do {
            try await fixture.create(isTag: isTag, name: name, at: head)
            Issue.record("Creation must refuse an existing name")
        } catch is GitError {}
        let ref = (isTag ? "refs/tags/" : "refs/heads/") + name
        #expect(try await fixture.git.git(["rev-parse", "--verify", ref]).trimmedStdout == fixture.commit.hash)
    }

    @Test("invalid names are rejected instead of interpreted as options or checkout shorthand",
          arguments: [false, true])
    func invalidNames(isTag: Bool) async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let before = try await fixture.git.git(["show-ref"])
        for name in ["", "-bad", "bad name", "bad..name", "@{-1}", "topic.lock", "a\nb"] {
            do {
                try await fixture.create(isTag: isTag, name: name, at: fixture.commit.hash)
                Issue.record("Must refuse invalid name: \(name)")
            } catch GitError.invalidReferenceName(let rejected) {
                #expect(rejected == name)
            }
        }
        #expect(try await fixture.git.git(["show-ref"]).stdout == before.stdout)
    }

    @Test("missing commits and non-commit objects leave refs unchanged", arguments: [false, true])
    func invalidCommits(isTag: Bool) async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let blob = try await fixture.git.git(["rev-parse", "HEAD:README.md"]).trimmedStdout
        let before = try await fixture.git.git(["show-ref"])
        for hash in [String(repeating: "0", count: 40), "--help", blob] {
            do {
                try await fixture.create(isTag: isTag, name: "invalid-target", at: hash)
                Issue.record("Must refuse a target that is not a commit")
            } catch is GitError {}
        }
        #expect(try await fixture.git.git(["show-ref"]).stdout == before.stdout)
    }

    @Test("tag messages select annotated tags and never invoke configured signing", arguments: [false, true])
    func tagMessages(annotated: Bool) async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        try await fixture.git.git(["config", "tag.gpgSign", "true"])
        try await fixture.git.git(["config", "gpg.program", "/nonexistent-gittrees-test-signer"])
        let message = annotated ? "Release from history\n\nLiteral ; $ text" : " \n "
        try await fixture.git.client.createTag(repository: fixture.git.repository, name: "release/v1",
                                               at: fixture.commit.hash, message: message)
        let type = try await fixture.git.git(["cat-file", "-t", "refs/tags/release/v1"])
        #expect(type.trimmedStdout == (annotated ? "tag" : "commit"))
        #expect(try await fixture.git.git(["rev-parse", "refs/tags/release/v1^{commit}"])
            .trimmedStdout == fixture.commit.hash)
        if annotated {
            let contents = try await fixture.git.git(["for-each-ref", "--format=%(contents)", "refs/tags/release/v1"])
            #expect(contents.trimmedStdout == message)
        }
    }

    @Test("a branch and tag may share a name without using the wrong target")
    func independentNamespaces() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let head = try #require(try await fixture.git.client.headCommit(worktree: fixture.git.repository))
        try await fixture.git.client.createBranch(repository: fixture.git.repository, name: "release", at: head)
        try await fixture.git.client.createTag(repository: fixture.git.repository, name: "release", at: fixture.commit.hash)
        #expect(try await fixture.git.git(["rev-parse", "refs/heads/release"]).trimmedStdout == head)
        #expect(try await fixture.git.git(["rev-parse", "refs/tags/release"]).trimmedStdout == fixture.commit.hash)
    }

    @Test("service refreshes branches and history badges without changing selection")
    func serviceRefresh() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let selection = fixture.service.selectedWorktreePath
        let worktrees = fixture.service.worktrees
        #expect(await fixture.service.createBranch(name: "history-branch", at: fixture.commit))
        let branch = try #require(fixture.service.localBranches.first { $0.name == "history-branch" })
        #expect(branch.objectName == fixture.commit.hash)
        #expect(branch.worktreePath == nil)
        #expect(await fixture.service.createTag(name: "history-tag", at: fixture.commit))
        // History loads on a separate task, just as it does after other Git actions.
        for _ in 0..<200 {
            if fixture.service.history.contains(where: {
                $0.hash == fixture.commit.hash && $0.refNames.contains("history-branch")
                    && $0.refNames.contains("tag: history-tag")
            }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let commit = try #require(fixture.service.history.first { $0.hash == fixture.commit.hash })
        #expect(commit.refNames.contains("history-branch"))
        #expect(commit.refNames.contains("tag: history-tag"))
        #expect(fixture.service.selectedWorktreePath == selection)
        #expect(fixture.service.worktrees == worktrees)
        #expect(fixture.service.lastError == nil)
    }

    @Test("service surfaces Git refusals and allows correcting the name")
    func serviceErrors() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        #expect(await fixture.service.createBranch(name: "main", at: fixture.commit) == false)
        #expect(fixture.service.lastError?.title == "Could Not Create Branch")
        fixture.service.lastError = nil
        #expect(await fixture.service.createTag(name: "bad..tag", at: fixture.commit) == false)
        #expect(fixture.service.lastError?.title == "Could Not Create Tag")
        fixture.service.lastError = nil
        #expect(await fixture.service.createTag(name: "valid-tag", at: fixture.commit))
        #expect(await fixture.service.createTag(name: "valid-tag", at: fixture.commit) == false)
        #expect(fixture.service.lastError?.title == "Could Not Create Tag")
    }
}
