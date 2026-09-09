import Foundation
import Testing
@testable import GitTreesCore

/// End-to-end cover for the creation paths that are a sequence rather than a command.
///
/// `createWorktree` with a transfer stashes, creates, applies and drops — four steps
/// whose ordering is the whole safety story, and which no single argument vector can
/// prove correct. These drive `RepositoryService` itself against real repositories.
@MainActor
@Suite(
    "Creating worktrees through the service",
    .enabled(if: FileManager.default.isExecutableFile(atPath: GitProcessRunner.defaultExecutablePath))
)
struct MoveChangesTests {

    @MainActor
    struct Fixture {
        let root: URL
        let repository: URL
        let service: RepositoryService
        private let defaultsName: String
        private let defaults: UserDefaults
        private let runner = GitProcessRunner()

        init() async throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("gittrees-move-\(UUID().uuidString)", isDirectory: true)
            repository = root.appendingPathComponent("summit repo", isDirectory: true)
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)

            defaultsName = "com.gittrees.tests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: defaultsName)!
            service = RepositoryService(preferences: PreferencesService(defaults: defaults))

            try await git(["init", "--quiet", "--initial-branch=main"])
            try await git(["config", "user.email", "tests@example.com"])
            try await git(["config", "user.name", "GitTrees Tests"])
            try await git(["config", "commit.gpgsign", "false"])
            let excludes = root.appendingPathComponent("empty-excludes", isDirectory: false)
            try "".write(to: excludes, atomically: true, encoding: .utf8)
            try await git(["config", "core.excludesFile", excludes.path])

            try write("hello\n", to: "README.md")
            try write("a\n", to: "src/a.txt")
            try await git(["add", "-A"])
            try await git(["commit", "--quiet", "--message", "initial commit"])

            await service.open(directory: repository)
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: root)
        }

        func git(_ arguments: [String], in directory: URL? = nil) async throws {
            _ = try await runner.run(
                GitCommand(
                    arguments,
                    workingDirectory: directory ?? repository,
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

        /// Everything the transfer has to carry: a staged file, an unstaged one, and an
        /// untracked file in a directory that does not exist in the new worktree yet.
        func makeDirty() async throws {
            try write("hello\nunstaged\n", to: "README.md")
            try write("a\nstaged\n", to: "src/a.txt")
            try await git(["add", "src/a.txt"])
            try write("todo\n", to: "notes/todo.md")
            service.refreshSelectedWorktree()
            try await settle()
        }

        /// The service refreshes off the main actor; this waits for the state to land.
        func settle() async throws {
            for _ in 0..<200 where service.activeOperation != nil || service.isRefreshing {
                try await Task.sleep(for: .milliseconds(20))
            }
            try await Task.sleep(for: .milliseconds(60))
        }

        func request(
            branch: String,
            directory: String,
            changes: NewWorktreeRequest.UncommittedChanges,
            ignoreRule: String? = nil
        ) -> NewWorktreeRequest {
            NewWorktreeRequest(
                mode: .newBranch(name: branch, startPoint: "main"),
                path: root.appendingPathComponent(directory, isDirectory: true),
                openInEditor: false,
                uncommittedChanges: changes,
                ignoreRule: ignoreRule
            )
        }

        var localExclude: URL {
            repository
                .appendingPathComponent(".git/info", isDirectory: true)
                .appendingPathComponent("exclude", isDirectory: false)
        }

        func status(of worktree: URL) async throws -> WorktreeStatus {
            try await GitClient().statusSummary(worktree: worktree)
        }

        func stashCount() async throws -> Int {
            let result = try await runner.run(
                GitCommand(["stash", "list"], workingDirectory: repository)
            )
            return result.stdoutText.split(separator: "\n").count
        }
    }

    @Test("moving takes the work across and leaves the source worktree clean")
    func moveLeavesSourceClean() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        try await fixture.makeDirty()

        let created = await fixture.service.createWorktree(
            fixture.request(branch: "feature/moved", directory: "moved work", changes: .move)
        )

        let worktree = try #require(created)
        let moved = try await fixture.status(of: worktree.path)
        // The staged/unstaged split survives, which is the point of going through a stash
        // rather than a patch.
        #expect(moved.stagedChanges.map(\.path) == ["src/a.txt"])
        #expect(moved.unstagedChanges.map(\.path).sorted() == ["README.md", "notes/todo.md"])

        #expect(try await fixture.status(of: fixture.repository).isClean)
        // The stash was a transport, not a record: nothing is left behind.
        #expect(try await fixture.stashCount() == 0)
        #expect(fixture.service.lastError == nil)
    }

    @Test("copying leaves the same work in both worktrees")
    func copyKeepsSourceChanges() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        try await fixture.makeDirty()

        let created = await fixture.service.createWorktree(
            fixture.request(branch: "feature/copied", directory: "copied work", changes: .copy)
        )

        let worktree = try #require(created)
        let copied = try await fixture.status(of: worktree.path)
        let source = try await fixture.status(of: fixture.repository)

        #expect(copied.stagedChanges.map(\.path) == ["src/a.txt"])
        #expect(source.stagedChanges.map(\.path) == ["src/a.txt"])
        #expect(copied.unstagedChanges.map(\.path).sorted() == ["README.md", "notes/todo.md"])
        #expect(source.unstagedChanges.map(\.path).sorted() == ["README.md", "notes/todo.md"])
        #expect(try await fixture.stashCount() == 0)
    }

    @Test("a worktree that cannot be created puts the changes back where they were")
    func failedCreationRestoresTheSource() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        try await fixture.makeDirty()
        let before = try await fixture.status(of: fixture.repository)

        // Git refuses a path that already exists, so the failure lands after the stash
        // has already emptied the source worktree — the case that must not lose work.
        let occupied = fixture.root.appendingPathComponent("occupied", isDirectory: true)
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        try "in the way\n".write(
            to: occupied.appendingPathComponent("file.txt"),
            atomically: true,
            encoding: .utf8
        )

        let created = await fixture.service.createWorktree(
            fixture.request(branch: "feature/doomed", directory: "occupied", changes: .move)
        )

        #expect(created == nil)
        #expect(fixture.service.lastError != nil)

        let after = try await fixture.status(of: fixture.repository)
        #expect(after.stagedChanges.map(\.path) == before.stagedChanges.map(\.path))
        #expect(after.unstagedChanges.map(\.path).sorted() == before.unstagedChanges.map(\.path).sorted())
        #expect(try await fixture.stashCount() == 0)
    }

    @Test("the worktree root rule lands in the local exclude, exactly once")
    func ignoreRuleIsWrittenOnce() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let rule = Gitignore.pattern(forDirectoryNamed: ".worktrees")

        #expect(await fixture.service.createWorktree(
            fixture.request(branch: "feature/one", directory: "one", changes: .leave, ignoreRule: rule)
        ) != nil)
        #expect(Gitignore.contains(pattern: rule, in: fixture.localExclude))
        // The file Git ships with is appended to, not replaced.
        let contents = try String(contentsOf: fixture.localExclude, encoding: .utf8)
        #expect(contents.contains("#"))

        // A second worktree must not add the rule again.
        #expect(await fixture.service.createWorktree(
            fixture.request(branch: "feature/two", directory: "two", changes: .leave, ignoreRule: rule)
        ) != nil)
        let lines = try String(contentsOf: fixture.localExclude, encoding: .utf8)
            .split(separator: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces) == rule }
        #expect(lines.count == 1)
    }

    @Test("a worktree that is never created leaves no ignore rule behind")
    func ignoreRuleIsNotWrittenWhenCreationFails() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let rule = Gitignore.pattern(forDirectoryNamed: ".worktrees")

        let occupied = fixture.root.appendingPathComponent("occupied", isDirectory: true)
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        try "in the way\n".write(
            to: occupied.appendingPathComponent("file.txt"),
            atomically: true,
            encoding: .utf8
        )

        let created = await fixture.service.createWorktree(
            fixture.request(branch: "feature/doomed", directory: "occupied", changes: .leave, ignoreRule: rule)
        )

        #expect(created == nil)
        #expect(Gitignore.contains(pattern: rule, in: fixture.localExclude) == false)
    }

    @Test("leaving the changes alone creates an ordinary, clean worktree")
    func leavingChangesIsUnchangedBehaviour() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        try await fixture.makeDirty()

        let created = await fixture.service.createWorktree(
            fixture.request(branch: "feature/plain", directory: "plain work", changes: .leave)
        )

        let worktree = try #require(created)
        #expect(try await fixture.status(of: worktree.path).isClean)
        #expect(!(try await fixture.status(of: fixture.repository).isClean))
        #expect(try await fixture.stashCount() == 0)
    }

    // MARK: - Stash panel

    @Test("creating a stash clears the worktree and lists the entry with its message")
    func createStashListsAndClears() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        try await fixture.makeDirty()

        await fixture.service.createStash(message: "my saved work", includeUntracked: true)
        try await fixture.settle()

        #expect(try await fixture.status(of: fixture.repository).isClean)
        #expect(fixture.service.stashes.count == 1)
        let stash = try #require(fixture.service.stashes.first)
        #expect(stash.message == "my saved work")
        #expect(stash.branch == "main")
        // The new stash is selected so its diff shows immediately.
        #expect(fixture.service.selectedStashID == stash.id)
        #expect(fixture.service.lastError == nil)
    }

    @Test("an empty message falls back to the suggested default")
    func createStashDefaultsMessage() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        try await fixture.makeDirty()

        await fixture.service.createStash(message: "   ", includeUntracked: true)
        try await fixture.settle()

        #expect(fixture.service.stashes.first?.message == fixture.service.suggestedStashMessage)
    }

    @Test("dropping a stash removes it from the list")
    func dropStashRemovesEntry() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        try await fixture.makeDirty()
        await fixture.service.createStash(message: "to drop", includeUntracked: true)
        try await fixture.settle()
        let stash = try #require(fixture.service.stashes.first)

        await fixture.service.dropStash(stash)
        try await fixture.settle()

        #expect(fixture.service.stashes.isEmpty)
        #expect(fixture.service.selectedStashID == nil)
        #expect(try await fixture.stashCount() == 0)
    }

    @Test("applying a stash restores the changes and keeps it on the stack")
    func applyStashRestoresAndKeeps() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        try await fixture.makeDirty()
        await fixture.service.createStash(message: "to apply", includeUntracked: true)
        try await fixture.settle()
        #expect(try await fixture.status(of: fixture.repository).isClean)
        let stash = try #require(fixture.service.stashes.first)

        await fixture.service.applyStash(stash)
        try await fixture.settle()

        // The work is back in the worktree, and Apply (not Pop) leaves the stash in place.
        #expect(!(try await fixture.status(of: fixture.repository).isClean))
        #expect(fixture.service.stashes.count == 1)
        #expect(fixture.service.lastError == nil)
    }
}
