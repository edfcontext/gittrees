import Foundation
import Testing
@testable import GitTreesCore

@MainActor
@Suite("Git Assist", .enabled(if: FileManager.default.isExecutableFile(atPath: GitProcessRunner.defaultExecutablePath)))
struct GitAssistTests {
    @Test("branch diagnosis distinguishes equal, fast-forward, ahead, diverged and unrelated histories")
    func relationships() async throws {
        let fixture = try await MergeTests.Fixture()
        defer { fixture.cleanUp() }
        let client = GitClient()
        try await fixture.git(["branch", "same"], in: fixture.work)
        let identical = try await client.assessBranches(worktree: fixture.work, otherRef: "refs/heads/same")
        #expect(identical.relationship == .identical)
        #expect(!identical.canFastForward)
        try await fixture.branchAddingFile("base", named: "base.txt", contents: "base\n")
        let forward = try await client.assessBranches(worktree: fixture.work, otherRef: "refs/heads/base")
        #expect(forward.relationship == .fastForward)
        #expect(forward.ahead == 0 && forward.behind == 1)
        #expect(forward.canFastForward)
        try await fixture.commitHere(contents: "local\n")
        let ahead = try await client.assessBranches(worktree: fixture.work, otherRef: "refs/heads/same")
        #expect(ahead.relationship == .ahead)
        let diverged = try await client.assessBranches(worktree: fixture.work, otherRef: "refs/heads/base")
        #expect(diverged.relationship == .diverged)
        #expect(diverged.ahead == 1 && diverged.behind == 1)
        #expect(!diverged.canFastForward)
        try await fixture.git(["checkout", "--orphan", "unrelated"], in: fixture.work)
        try await fixture.git(["commit", "--quiet", "--message", "independent root"], in: fixture.work)
        try await fixture.git(["checkout", "main"], in: fixture.work)
        let unrelated = try await client.assessBranches(worktree: fixture.work, otherRef: "refs/heads/unrelated")
        #expect(unrelated.relationship == .unrelated)
    }

    @Test("fast-forward updates only the selected branch without a merge commit")
    func fastForward() async throws {
        let fixture = try await MergeTests.Fixture()
        defer { fixture.cleanUp() }
        try await fixture.branchAddingFile("base", named: "base.txt", contents: "base\n")
        let assessment = try await GitClient().assessBranches(worktree: fixture.work, otherRef: "refs/heads/base")
        try await fixture.service.fastForward(assessment)
        let head = try await fixture.git(["rev-parse", "HEAD"], in: fixture.work)
        let branch = try await fixture.git(["branch", "--show-current"], in: fixture.work)
        #expect(head == assessment.otherHead)
        #expect(branch == "main")
        #expect(try fixture.fileContents("base.txt") == "base\n")
    }

    @Test("fast-forward rejects dirty or stale previews", arguments: ["dirty", "source", "current", "checkout"])
    func staleFastForward(change: String) async throws {
        let fixture = try await MergeTests.Fixture()
        defer { fixture.cleanUp() }
        try await fixture.branchAddingFile("base", named: "base.txt", contents: "base\n")
        let client = GitClient()
        let assessment = try await client.assessBranches(worktree: fixture.work, otherRef: "refs/heads/base")
        switch change {
        case "dirty": try fixture.write("unsaved work\n", to: "file.txt")
        case "source": try await fixture.git(["update-ref", "refs/heads/base", assessment.currentHead], in: fixture.work)
        case "current": try await fixture.commitHere(contents: "new commit\n")
        default: try await fixture.git(["checkout", "-b", "other"], in: fixture.work)
        }
        let head = try await fixture.git(["rev-parse", "HEAD"], in: fixture.work)
        await #expect(throws: GitAssistError.self) { try await client.fastForward(assessment) }
        #expect(try await fixture.git(["rev-parse", "HEAD"], in: fixture.work) == head)
        #expect(!fixture.exists("base.txt"))
    }

    @Test("Fetch & Recheck fetches the compared branch's remote even when another remote is selected")
    func fetchComparedRemote() async throws {
        let fixture = try await MergeTests.Fixture()
        defer { fixture.cleanUp() }
        try await fixture.branchAddingFile("base", named: "base.txt", contents: "base\n")
        let remote = fixture.root.appendingPathComponent("remote.git")
        try await fixture.git(["clone", "--bare", fixture.work.path, remote.path], in: fixture.root)
        try await fixture.git(["remote", "add", "origin", remote.path], in: fixture.work)
        try await fixture.git(["remote", "add", "other", fixture.root.appendingPathComponent("missing.git").path], in: fixture.work)
        try await fixture.git(["fetch", "origin"], in: fixture.work)
        try await fixture.fullRefresh()
        let compared = try #require(fixture.service.remoteBranches.first { $0.name == "origin/main" })
        let base = try await fixture.git(["rev-parse", "base"], in: fixture.work)
        try await fixture.git(["update-ref", "refs/heads/main", base], in: remote)
        fixture.service.selectedRemote = "other"

        try await fixture.service.fetchForAssist(worktree: try #require(fixture.service.selectedWorktree), branch: compared)

        #expect(try await fixture.git(["rev-parse", "origin/main"], in: fixture.work) == base)
        #expect(fixture.service.selectedRemote == "other")
    }

    private func conflictingFixture() async throws -> MergeTests.Fixture {
        let fixture = try await MergeTests.Fixture()
        try await fixture.branchChangingFile("base", contents: "line1\nline2\nBASE\n")
        try await fixture.commitHere(contents: "line1\nline2\nLOCAL\n")
        await fixture.service.merge(try #require(fixture.branch(named: "base")))
        try await fixture.waitUntil { !fixture.service.status.conflicts.isEmpty }
        return fixture
    }

    @Test("review is read-only and applying preserves outside edits, stages only the file, and does not commit")
    func reviewAndApply() async throws {
        let fixture = try await conflictingFixture()
        defer { fixture.cleanUp() }
        let working = try fixture.fileContents().replacingOccurrences(of: "line1", with: "user's outside edit")
        try fixture.write(working, to: "file.txt")
        let client = GitClient()
        let snapshot = try await client.conflictSnapshot(worktree: fixture.work, path: "file.txt")
        let proposal = try await client.conflictProposal(snapshot: snapshot,
            replacements: [ConflictReplacement(id: 0, text: "LOCAL and BASE\n")], explanation: "Keep both changes")
        #expect(try fixture.fileContents() == working)
        #expect(proposal.diff.contains("+LOCAL and BASE"))
        #expect(proposal.resolvedText == "user's outside edit\nline2\nLOCAL and BASE\n")
        try fixture.write("unrelated local work", to: "untracked.txt")
        try await fixture.service.applyConflictProposal(proposal)
        let status = try await client.statusSummary(worktree: fixture.work)
        #expect(status.conflicts.isEmpty)
        #expect(status.stagedChanges.map(\.path) == ["file.txt"])
        #expect(status.unstagedChanges.contains(where: { $0.path == "untracked.txt" }))
        #expect(try await fixture.git(["rev-parse", "HEAD"], in: fixture.work) == snapshot.head)
        #expect(try await client.inProgressOperation(worktree: fixture.work) == .merge)
    }

    @Test("applying rejects changed file, changed index, and an aborted operation", arguments: ["file", "index", "abort"])
    func staleProposal(change: String) async throws {
        let fixture = try await conflictingFixture()
        defer { fixture.cleanUp() }
        let client = GitClient()
        let snapshot = try await client.conflictSnapshot(worktree: fixture.work, path: "file.txt")
        let proposal = try await client.conflictProposal(snapshot: snapshot,
            replacements: [ConflictReplacement(id: 0, text: "resolution\n")], explanation: "Test")
        switch change {
        case "file": try fixture.write(snapshot.workingText + "new edit\n", to: "file.txt")
        case "index": try await fixture.git(["add", "file.txt"], in: fixture.work)
        default: try await fixture.git(["merge", "--abort"], in: fixture.work)
        }
        let before = try fixture.fileContents()
        await #expect(throws: GitAssistError.self) { try await client.applyConflictProposal(proposal) }
        #expect(try fixture.fileContents() == before)
    }

    @Test("a model that silently selects just one changed side cannot produce an applicable proposal", arguments: [false, true])
    func rejectsWholeSideCopy(outsideEdit: Bool) async throws {
        let fixture = try await conflictingFixture()
        defer { fixture.cleanUp() }
        let client = GitClient()
        if outsideEdit {
            try fixture.write(try fixture.fileContents().replacingOccurrences(of: "line1", with: "outside edit"), to: "file.txt")
        }
        let snapshot = try await client.conflictSnapshot(worktree: fixture.work, path: "file.txt")
        await #expect(throws: GitAssistError.self) {
            try await client.conflictProposal(snapshot: snapshot, replacements: [.init(id: 0, text: "LOCAL\n")], explanation: "Incorrectly claimed to combine both")
        }
        #expect(try fixture.fileContents() == snapshot.workingText)
    }

    @Test("a rebase suggestion reads the correct index sides and stages without advancing the rebase")
    func rebaseProposal() async throws {
        let fixture = try await MergeTests.Fixture()
        defer { fixture.cleanUp() }
        try await fixture.branchChangingFile("base", contents: "line1\nline2\nBASE\n")
        try await fixture.commitHere(contents: "line1\nline2\nLOCAL\n")
        _ = try? await fixture.git(["rebase", "base"], in: fixture.work)
        let client = GitClient()
        let snapshot = try await client.conflictSnapshot(worktree: fixture.work, path: "file.txt")
        #expect(snapshot.operation == .rebase)
        #expect(snapshot.ours.contains("BASE"))
        #expect(snapshot.theirs.contains("LOCAL"))
        let proposal = try await client.conflictProposal(snapshot: snapshot,
            replacements: [.init(id: 0, text: "LOCAL and BASE\n")], explanation: "Combined")
        try await client.applyConflictProposal(proposal)
        #expect(try await client.inProgressOperation(worktree: fixture.work) == .rebase)
        #expect(try await client.statusSummary(worktree: fixture.work).conflicts.isEmpty)
        _ = try await client.continueRebase(worktree: fixture.work)
        #expect(try await client.inProgressOperation(worktree: fixture.work) == .none)
        #expect(try await fixture.git(["branch", "--show-current"], in: fixture.work) == "main")
        #expect(try fixture.fileContents() == "line1\nline2\nLOCAL and BASE\n")
    }

    @Test("unsupported conflict inputs are rejected before generation", arguments: ["binary", "large", "symlink", "lockfile"])
    func unsupportedInput(kind: String) async throws {
        let fixture = try await conflictingFixture()
        defer { fixture.cleanUp() }
        switch kind {
        case "binary": try Data([0, 1, 2]).write(to: fixture.work.appendingPathComponent("file.txt"))
        case "large": try fixture.write(String(repeating: "x", count: 13_000), to: "file.txt")
        case "symlink":
            try FileManager.default.removeItem(at: fixture.work.appendingPathComponent("file.txt"))
            try FileManager.default.createSymbolicLink(atPath: fixture.work.appendingPathComponent("file.txt").path,
                                                       withDestinationPath: "/tmp/unrelated-file")
        default: break
        }
        await #expect(throws: GitAssistError.self) {
            try await GitClient().conflictSnapshot(worktree: fixture.work, path: kind == "lockfile" ? "package-lock.json" : "file.txt")
        }
    }

    @Test("conflict replacement preserves CRLF, multiple blocks, and a final line without newline")
    func parser() throws {
        let text = "before\r\n<<<<<<< HEAD\r\nleft\r\n||||||| base\r\nold\r\n=======\r\nright\r\n>>>>>>> other\r\nbetween\r\n<<<<<<< HEAD\r\nx\r\n=======\r\ny\r\n>>>>>>> other\r\nafter"
        let document = try ConflictDocument(text)
        let resolved = try document.applying([.init(id: 1, text: "second\n"), .init(id: 0, text: "first")])
        #expect(resolved == "before\r\nfirst\r\nbetween\r\nsecond\r\nafter")
        #expect(throws: GitAssistError.self) { try document.applying([.init(id: 0, text: "incomplete")]) }
        #expect(throws: GitAssistError.self) { try document.applying([.init(id: 0, text: "a"), .init(id: 0, text: "b")]) }
        #expect(throws: GitAssistError.self) { try document.applying([.init(id: 0, text: "<<<<<<< HEAD"), .init(id: 1, text: "b")]) }
    }

    @Test("malformed conflict markers fail closed", arguments: ["plain text", "<<<<<<< HEAD\na\n=======\nb\n", "=======\n", "<<<<<<< HEAD\n<<<<<<< nested\n"])
    func malformed(text: String) {
        #expect(throws: GitAssistError.self) { try ConflictDocument(text) }
    }

    @Test("live Git Assist on-device explanation", .enabled(if: ProcessInfo.processInfo.environment["GITTREES_TEST_APPLE_INTELLIGENCE"] == "1"))
    func liveExplanation() async throws {
        let fixture = try await MergeTests.Fixture()
        defer { fixture.cleanUp() }
        try await fixture.branchAddingFile("base", named: "base.txt", contents: "base\n")
        let assessment = try await GitClient().assessBranches(worktree: fixture.work, otherRef: "refs/heads/base")
        let explanation = try await AppleIntelligenceGitAssistant.explain(assessment)
        #expect(!explanation.isEmpty)
        print("Git Assist explanation: \(explanation)")
    }

    @Test("live on-device conflict suggestion", .enabled(if: ProcessInfo.processInfo.environment["GITTREES_TEST_APPLE_INTELLIGENCE"] == "1"))
    func liveConflictSuggestion() async throws {
        let fixture = try await MergeTests.Fixture()
        defer { fixture.cleanUp() }
        try await fixture.commitHere(contents: "let options = Options(timeout: 10, retries: 0)\n")
        try await fixture.branchChangingFile("base", contents: "let options = Options(timeout: 30, retries: 0)\n")
        try await fixture.commitHere(contents: "let options = Options(timeout: 10, retries: 3)\n")
        await fixture.service.merge(try #require(fixture.branch(named: "base")))
        try await fixture.waitUntil { !fixture.service.status.conflicts.isEmpty }
        let snapshot = try await GitClient().conflictSnapshot(worktree: fixture.work, path: "file.txt")
        do {
            let suggestion = try await AppleIntelligenceGitAssistant.suggest(snapshot)
            let proposal = try await GitClient().conflictProposal(snapshot: snapshot,
                replacements: suggestion.replacements, explanation: suggestion.explanation)
            #expect(proposal.resolvedText.contains("timeout: 30"))
            #expect(proposal.resolvedText.contains("retries: 3"))
            print("Git Assist suggested code: \(proposal.resolvedText)")
            print("Git Assist conflict explanation: \(suggestion.explanation)")
        } catch GitAssistError.unsupported(let reason) {
            // Abstention and rejected whole-side copies are supported outcomes, not a
            // successful code resolution. Keep this visible in the live test output.
            print("Git Assist did NOT resolve the sample: \(reason)")
        }
        #expect(try fixture.fileContents() == snapshot.workingText)
    }
}
