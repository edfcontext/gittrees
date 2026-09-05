import Foundation
import Testing
@testable import GitTreesCore

/// Fixtures in this file were captured from a real repository by running
/// `git worktree list --porcelain -z | tr '\0' '|'`, then translating `|` back to NUL.
@Suite("WorktreeParser")
struct WorktreeParserTests {

    /// Builds the NUL-separated byte stream Git actually emits from a readable literal.
    static func porcelainZ(_ text: String) -> Data {
        Data(text.replacingOccurrences(of: "|", with: "\u{0}").utf8)
    }

    static let root = "/tmp/gitfix"

    static let fullFixture = porcelainZ(
        """
        worktree \(root)/summit repo|HEAD 3a41334e2640dc50b4225ebaebeec7e4f84dbd88|branch refs/heads/main||\
        worktree \(root)/detached|HEAD 3a41334e2640dc50b4225ebaebeec7e4f84dbd88|detached||\
        worktree \(root)/gone-tree|HEAD 3a41334e2640dc50b4225ebaebeec7e4f84dbd88|branch refs/heads/feature/ünüsual-nàme|prunable gitdir file points to non-existent location||\
        worktree \(root)/locked-one|HEAD 3a41334e2640dc50b4225ebaebeec7e4f84dbd88|branch refs/heads/develop|locked waiting on a build||\
        worktree \(root)/scanner dir|HEAD 3a41334e2640dc50b4225ebaebeec7e4f84dbd88|branch refs/heads/bugfix/scanner||\
        worktree \(root)/zpl-engine|HEAD 3a41334e2640dc50b4225ebaebeec7e4f84dbd88|branch refs/heads/feature/zpl-engine||
        """
    )

    @Test("a single main worktree is parsed and marked as main")
    func mainWorktree() throws {
        let data = Self.porcelainZ("worktree \(Self.root)/summit|HEAD abc123|branch refs/heads/main||")
        let worktrees = try WorktreeParser.parse(data)

        #expect(worktrees.count == 1)
        let main = try #require(worktrees.first)
        #expect(main.isMain)
        #expect(main.path.path == "\(Self.root)/summit")
        #expect(main.head == "abc123")
        #expect(main.branchRef == "refs/heads/main")
        #expect(main.branchName == "main")
        #expect(!main.isDetached)
        #expect(!main.isLocked)
        #expect(!main.isPrunable)
    }

    @Test("multiple linked worktrees keep Git's order, with only the first marked main")
    func multipleLinkedWorktrees() throws {
        let worktrees = try WorktreeParser.parse(Self.fullFixture)

        #expect(worktrees.count == 6)
        #expect(worktrees.map(\.isMain) == [true, false, false, false, false, false])
        #expect(worktrees[0].branchName == "main")
        #expect(worktrees[5].branchName == "feature/zpl-engine")
    }

    @Test("a detached worktree reports no branch")
    func detachedWorktree() throws {
        let worktrees = try WorktreeParser.parse(Self.fullFixture)
        let detached = try #require(worktrees.first { $0.path.lastPathComponent == "detached" })

        #expect(detached.isDetached)
        #expect(detached.branchRef == nil)
        #expect(detached.branchName == nil)
        #expect(detached.head == "3a41334e2640dc50b4225ebaebeec7e4f84dbd88")
        #expect(detached.displayName == "(detached 3a41334)")
    }

    @Test("a locked worktree keeps the reason verbatim, spaces included")
    func lockedWorktree() throws {
        let worktrees = try WorktreeParser.parse(Self.fullFixture)
        let locked = try #require(worktrees.first { $0.path.lastPathComponent == "locked-one" })

        #expect(locked.isLocked)
        #expect(locked.lockReason == "waiting on a build")
        #expect(locked.branchName == "develop")
    }

    @Test("a lock without a reason is still recognised as locked")
    func lockedWithoutReason() throws {
        let data = Self.porcelainZ(
            "worktree \(Self.root)/main|HEAD abc||worktree \(Self.root)/held|HEAD abc|branch refs/heads/x|locked||"
        )
        let worktrees = try WorktreeParser.parse(data)

        #expect(worktrees[1].isLocked)
        #expect(worktrees[1].lockReason == nil)
    }

    @Test("a prunable worktree carries Git's reason")
    func prunableWorktree() throws {
        let worktrees = try WorktreeParser.parse(Self.fullFixture)
        let prunable = try #require(worktrees.first { $0.path.lastPathComponent == "gone-tree" })

        #expect(prunable.isPrunable)
        #expect(prunable.prunableReason == "gitdir file points to non-existent location")
    }

    @Test("paths with spaces and branches with non-ASCII characters survive parsing")
    func unusualNames() throws {
        let worktrees = try WorktreeParser.parse(Self.fullFixture)

        let spaced = try #require(worktrees.first { $0.path.path.hasSuffix("scanner dir") })
        #expect(spaced.path.lastPathComponent == "scanner dir")
        #expect(spaced.branchName == "bugfix/scanner")

        let accented = try #require(worktrees.first { $0.branchName == "feature/ünüsual-nàme" })
        #expect(accented.branchRef == "refs/heads/feature/ünüsual-nàme")
    }

    @Test("a bare main repository is reported as bare")
    func bareRepository() throws {
        let data = Self.porcelainZ("worktree \(Self.root)/summit.git|bare||worktree \(Self.root)/main|HEAD abc|branch refs/heads/main||")
        let worktrees = try WorktreeParser.parse(data)

        #expect(worktrees[0].isBare)
        #expect(worktrees[0].displayName == "(bare)")
        #expect(!worktrees[1].isBare)
    }

    @Test("unknown attributes from a newer Git are ignored rather than fatal")
    func unknownAttributes() throws {
        let data = Self.porcelainZ("worktree \(Self.root)/summit|HEAD abc|branch refs/heads/main|somethingnew value||")
        let worktrees = try WorktreeParser.parse(data)

        #expect(worktrees.count == 1)
        #expect(worktrees[0].branchName == "main")
    }

    @Test("the newline porcelain form is accepted as a fallback")
    func newlineFallback() throws {
        let text = """
        worktree \(Self.root)/summit
        HEAD abc123
        branch refs/heads/main

        worktree \(Self.root)/other
        HEAD def456
        detached

        """
        let worktrees = try WorktreeParser.parse(porcelainText: text)

        #expect(worktrees.count == 2)
        #expect(worktrees[0].branchName == "main")
        #expect(worktrees[1].isDetached)
    }

    @Test("empty output yields no worktrees")
    func emptyOutput() throws {
        #expect(try WorktreeParser.parse(Data()).isEmpty)
    }

    @Test("a record without a path is rejected")
    func recordWithoutPath() {
        let data = Self.porcelainZ("HEAD abc|branch refs/heads/main||")
        #expect(throws: GitError.self) {
            try WorktreeParser.parse(data)
        }
    }
}
