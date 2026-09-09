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

        func settle() async throws {
            for _ in 0..<200 where service.activeOperation != nil || service.isRefreshing {
                try await Task.sleep(for: .milliseconds(20))
            }
            try await Task.sleep(for: .milliseconds(60))
        }
    }

    @Test("a non-overlapping local edit is stashed, the pull lands, and the edit re-applies")
    func cleanReapply() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }

        try await fixture.pushRemoteChange(line3: "REMOTE-line3")
        // The behind count is what the commit banner reads.
        #expect(fixture.service.status.behind == 1)
        try fixture.localEdit(line1: "LOCAL-line1")
        try await fixture.settle()

        await fixture.service.stashPullAndReapply()
        try await fixture.settle()

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

        let file = try String(contentsOf: fixture.work.appendingPathComponent("file.txt"), encoding: .utf8)
        #expect(file == "line1\nline2\nREMOTE-line3\n")
        #expect(try await fixture.stashCount() == 0)
        #expect(fixture.service.lastError == nil)
        #expect(fixture.service.status.behind == 0)
    }
}
