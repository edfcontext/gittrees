import Foundation
import Testing
@testable import GitTreesCore

/// Cover for merging another branch into the worktree's branch.
///
/// The clean case is the easy half. The half that matters is the conflict: it has to
/// arrive as *files the user can act on* — listed in the status, with the merge known to
/// be in progress — not merely as an error string. That is what makes Use Mine / Use
/// Theirs / Discard and Abort Merge reachable, so these drive `RepositoryService` against
/// a real repository, because only Git can produce a real conflict.
@MainActor
@Suite(
    "Merge a branch",
    .enabled(if: FileManager.default.isExecutableFile(atPath: GitProcessRunner.defaultExecutablePath))
)
struct MergeTests {

    @MainActor
    struct Fixture {
        let root: URL
        let work: URL
        let service: RepositoryService
        private let defaultsName: String
        private let defaults: UserDefaults
        private let runner = GitProcessRunner()

        init() async throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("gittrees-merge-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            work = root.appendingPathComponent("work", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

            defaultsName = "com.gittrees.tests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: defaultsName)!
            service = RepositoryService(preferences: PreferencesService(defaults: defaults))

            // A merge is purely local, so no remote is needed here.
            try await git(["init", "--quiet", "--initial-branch=main"], in: work)
            try await git(["config", "user.email", "tests@example.com"], in: work)
            try await git(["config", "user.name", "GitTrees Tests"], in: work)
            try await git(["config", "commit.gpgsign", "false"], in: work)

            try write("line1\nline2\nline3\n", to: "file.txt")
            try await git(["add", "-A"], in: work)
            try await git(["commit", "--quiet", "--message", "initial"], in: work)

            await service.open(directory: work)
            try await settle()
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: root)
        }

        /// Commits `contents` to `file.txt` on a new `branch`, then returns to `main`.
        func branchChangingFile(_ branch: String, contents: String) async throws {
            try await git(["checkout", "--quiet", "-b", branch], in: work)
            try write(contents, to: "file.txt")
            try await git(["commit", "--quiet", "--all", "--message", "\(branch) change"], in: work)
            try await git(["checkout", "--quiet", "main"], in: work)
            try await fullRefresh()
        }

        /// Commits a brand-new file on a new `branch`, then returns to `main`. Nothing on
        /// `main` touches it, so merging is clean.
        func branchAddingFile(_ branch: String, named name: String, contents: String) async throws {
            try await git(["checkout", "--quiet", "-b", branch], in: work)
            try write(contents, to: name)
            try await git(["add", "-A"], in: work)
            try await git(["commit", "--quiet", "--message", "\(branch) adds \(name)"], in: work)
            try await git(["checkout", "--quiet", "main"], in: work)
            try await fullRefresh()
        }

        /// Commits a colliding change to `file.txt` on the branch that is checked out.
        func commitHere(contents: String) async throws {
            try write(contents, to: "file.txt")
            try await git(["commit", "--quiet", "--all", "--message", "main change"], in: work)
            try await fullRefresh()
        }

        func branch(named name: String) -> Branch? {
            service.branches.first { $0.name == name && $0.kind == .local }
        }

        func write(_ contents: String, to relativePath: String) throws {
            try contents.write(
                to: work.appendingPathComponent(relativePath),
                atomically: true,
                encoding: .utf8
            )
        }

        func fileContents(_ relativePath: String = "file.txt") throws -> String {
            try String(contentsOf: work.appendingPathComponent(relativePath), encoding: .utf8)
        }

        func exists(_ relativePath: String) -> Bool {
            FileManager.default.fileExists(atPath: work.appendingPathComponent(relativePath).path)
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

        /// A full reload so `branches` reflects newly created refs.
        func fullRefresh() async throws {
            service.refresh()
            try await Task.sleep(for: .milliseconds(60))
            try await settle()
        }

        func settle() async throws {
            for _ in 0..<200 where service.activeOperation != nil || service.isRefreshing {
                try await Task.sleep(for: .milliseconds(20))
            }
            try await Task.sleep(for: .milliseconds(60))
        }

        /// Waits until an observed condition holds — the selected-worktree status read
        /// lands in a task the operation does not await, so `settle()` cannot see it.
        func waitUntil(_ condition: @MainActor () -> Bool, timeoutMs: Int = 5000) async throws {
            for _ in 0..<(timeoutMs / 20) {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    @Test("the branch already checked out here is not offered as a merge source")
    func candidatesExcludeCurrentBranch() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        try await fixture.branchAddingFile("feature", named: "other.txt", contents: "from feature\n")

        let names = fixture.service.mergeCandidates.map(\.name)
        #expect(names.contains("feature"))
        #expect(!names.contains("main"))
        #expect(fixture.service.canMerge)
    }

    @Test("a clean merge brings the other branch's work in, with no conflicts")
    func cleanMerge() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        try await fixture.branchAddingFile("feature", named: "other.txt", contents: "from feature\n")
        let feature = try #require(fixture.branch(named: "feature"))

        await fixture.service.merge(feature)
        try await fixture.waitUntil { fixture.exists("other.txt") }

        #expect(fixture.exists("other.txt"))
        #expect(fixture.service.status.conflicts.isEmpty)
        #expect(fixture.service.mergeOperation == .none)
    }

    @Test("a conflicting merge surfaces the conflicted files and an abortable merge")
    func conflictingMergeSurfacesFiles() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        // Both branches rewrite line 3 of the same file, so the merge must collide.
        try await fixture.branchChangingFile("feature", contents: "line1\nline2\nFEATURE-3\n")
        try await fixture.commitHere(contents: "line1\nline2\nMAIN-3\n")
        let feature = try #require(fixture.branch(named: "feature"))

        await fixture.service.merge(feature)
        try await fixture.waitUntil { !fixture.service.status.conflicts.isEmpty }

        // The point of the feature: the conflict is a list of files, not just an error.
        let allConflicted = fixture.service.status.conflicts.allSatisfy(\.isConflicted)
        #expect(fixture.service.status.conflicts.map(\.path) == ["file.txt"])
        #expect(allConflicted)
        #expect(fixture.service.mergeOperation == .merge)
        // A second merge cannot start until this one is resolved or abandoned.
        #expect(!fixture.service.canMerge)
    }

    @Test("Use Theirs resolves a merge conflict to the merged branch's side")
    func resolveConflictTakingTheirs() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        try await fixture.branchChangingFile("feature", contents: "line1\nline2\nFEATURE-3\n")
        try await fixture.commitHere(contents: "line1\nline2\nMAIN-3\n")
        let feature = try #require(fixture.branch(named: "feature"))
        await fixture.service.merge(feature)
        try await fixture.waitUntil { !fixture.service.status.conflicts.isEmpty }
        let change = try #require(fixture.service.status.conflicts.first)

        await fixture.service.resolveConflicts([change], keeping: .theirs)
        try await fixture.waitUntil { fixture.service.status.conflicts.isEmpty }

        let resolved = try fixture.fileContents()
        #expect(fixture.service.status.conflicts.isEmpty)
        #expect(resolved == "line1\nline2\nFEATURE-3\n")
    }

    @Test("Abort Merge puts the branch back as it was")
    func abortRestoresTheBranch() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        try await fixture.branchChangingFile("feature", contents: "line1\nline2\nFEATURE-3\n")
        try await fixture.commitHere(contents: "line1\nline2\nMAIN-3\n")
        let feature = try #require(fixture.branch(named: "feature"))
        await fixture.service.merge(feature)
        try await fixture.waitUntil { !fixture.service.status.conflicts.isEmpty }

        await fixture.service.abortMerge()
        try await fixture.waitUntil { fixture.service.mergeOperation == .none }

        let restored = try fixture.fileContents()
        #expect(fixture.service.status.conflicts.isEmpty)
        #expect(fixture.service.mergeOperation == .none)
        #expect(restored == "line1\nline2\nMAIN-3\n")
    }
}
