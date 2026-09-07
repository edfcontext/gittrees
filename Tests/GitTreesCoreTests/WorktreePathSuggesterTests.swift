import Foundation
import Testing
@testable import GitTreesCore

@Suite("WorktreePathSuggester")
struct WorktreePathSuggesterTests {

    @Test("the default worktree root is a .worktrees directory beside the repository")
    func defaultRoot() {
        let repository = URL(fileURLWithPath: "/Users/me/Development/nalcus/summit")
        let root = WorktreePathSuggester.defaultWorktreeRoot(forRepositoryAt: repository)

        // The repository name is not a level of its own: the branch directory inside
        // `worktrees` is what names the checkout.
        #expect(root.path == "/Users/me/Development/nalcus/.worktrees")
    }

    @Test(
        "conventional prefixes are stripped from the suggested directory name",
        arguments: [
            ("feature/zpl-templates", "zpl-templates"),
            ("feat/metrics", "metrics"),
            ("bugfix/scanner", "scanner"),
            ("fix/off-by-one", "off-by-one"),
            ("hotfix/crash", "crash"),
            ("chore/deps", "deps"),
            ("release/2.1", "2.1")
        ]
    )
    func strippedPrefixes(branch: String, expected: String) {
        #expect(WorktreePathSuggester.directoryName(forBranch: branch) == expected)
    }

    @Test("only the leading prefix is stripped and remaining slashes become dashes")
    func nestedBranchNames() {
        #expect(WorktreePathSuggester.directoryName(forBranch: "feature/label/engine") == "label-engine")
        #expect(WorktreePathSuggester.directoryName(forBranch: "team/feature/x") == "team-feature-x")
    }

    @Test("branches without a known prefix keep their name")
    func plainBranchNames() {
        #expect(WorktreePathSuggester.directoryName(forBranch: "main") == "main")
        #expect(WorktreePathSuggester.directoryName(forBranch: "ünüsual-nàme") == "ünüsual-nàme")
    }

    @Test("a name that would be empty falls back to a usable directory name")
    func degenerateNames() {
        #expect(WorktreePathSuggester.directoryName(forBranch: "feature/") == "worktree")
        #expect(WorktreePathSuggester.directoryName(forBranch: "   ") == "worktree")
    }

    @Test("the suggested path joins the root and the derived directory name")
    func suggestedPath() {
        let repository = URL(fileURLWithPath: "/Users/me/Development/nalcus/summit")
        let root = WorktreePathSuggester.defaultWorktreeRoot(forRepositoryAt: repository)
        let path = WorktreePathSuggester.suggestedPath(worktreeRoot: root, branch: "feature/zpl-templates")

        #expect(path.path == "/Users/me/Development/nalcus/.worktrees/zpl-templates")
    }

    @Test("a configured root is joined the same way, whatever shape it has")
    func suggestedPathUnderACustomRoot() {
        let root = URL(fileURLWithPath: "/Volumes/Scratch/summit-trees")
        let path = WorktreePathSuggester.suggestedPath(worktreeRoot: root, branch: "bugfix/scanner")

        #expect(path.path == "/Volumes/Scratch/summit-trees/scanner")
    }

    @Test("an existing directory makes the suggestion fall through to a free name")
    func availablePathAvoidsCollisions() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gittrees-suggest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let taken = base.appendingPathComponent("scanner", isDirectory: true)
        try FileManager.default.createDirectory(at: taken, withIntermediateDirectories: true)

        #expect(WorktreePathSuggester.availablePath(taken).lastPathComponent == "scanner-2")

        let free = base.appendingPathComponent("engine", isDirectory: true)
        #expect(WorktreePathSuggester.availablePath(free) == free)
    }
}
