import Foundation
import Testing
@testable import GitTreesCore

/// Fixtures captured with the same `%00`-separated format `GitClient` uses.
@Suite("BranchParser")
struct BranchParserTests {

    static func format(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\u{0}")
    }

    @Test("local branches carry their worktree path when checked out")
    func localBranchesWithWorktrees() throws {
        let text = Self.format(
            """
            refs/heads/bugfix/scanner|3a41334|||/tmp/gitfix/scanner dir|\u{20}
            refs/heads/develop|3a41334||||\u{20}
            refs/heads/main|3a41334|||/tmp/gitfix/summit repo|*
            """
        )
        let branches = try BranchParser.parse(text: text)

        #expect(branches.count == 3)
        #expect(branches.allSatisfy { $0.kind == .local })

        let scanner = try #require(branches.first { $0.name == "bugfix/scanner" })
        #expect(scanner.worktreePath?.path == "/tmp/gitfix/scanner dir")
        #expect(!scanner.isCurrentHEAD)

        let develop = try #require(branches.first { $0.name == "develop" })
        #expect(develop.worktreePath == nil)

        let main = try #require(branches.first { $0.name == "main" })
        #expect(main.isCurrentHEAD)
    }

    @Test("upstream tracking counts are parsed in both directions")
    func upstreamTracking() throws {
        let text = Self.format(
            """
            refs/heads/ahead|aaa|refs/remotes/origin/ahead|ahead 3||\u{20}
            refs/heads/behind|bbb|refs/remotes/origin/behind|behind 2||\u{20}
            refs/heads/diverged|ccc|refs/remotes/origin/diverged|ahead 3, behind 2||\u{20}
            refs/heads/level|ddd|refs/remotes/origin/level|||\u{20}
            refs/heads/orphan|eee|refs/remotes/origin/orphan|gone||\u{20}
            refs/heads/local-only|fff||||\u{20}
            """
        )
        let branches = try BranchParser.parse(text: text)
        func branch(_ name: String) throws -> Branch {
            try #require(branches.first { $0.name == name })
        }

        let ahead = try branch("ahead")
        #expect(ahead.ahead == 3)
        #expect(ahead.behind == 0)
        #expect(ahead.upstreamName == "origin/ahead")
        #expect(ahead.trackingSummary == "↑3")

        #expect(try branch("behind").behind == 2)

        let diverged = try branch("diverged")
        #expect(diverged.ahead == 3)
        #expect(diverged.behind == 2)
        #expect(diverged.trackingSummary == "↑3 ↓2")

        let level = try branch("level")
        #expect(level.ahead == 0)
        #expect(level.behind == 0)
        #expect(level.trackingSummary == nil)
        #expect(level.hasUpstream)

        let orphan = try branch("orphan")
        #expect(orphan.upstreamIsGone)
        #expect(orphan.trackingSummary == "upstream gone")

        let localOnly = try branch("local-only")
        #expect(!localOnly.hasUpstream)
        #expect(localOnly.ahead == nil)
    }

    @Test("remote branches are classified as remote and origin/HEAD is skipped")
    func remoteBranches() throws {
        let text = Self.format(
            """
            refs/heads/main|aaa|refs/remotes/origin/main|||*
            refs/remotes/origin/HEAD|aaa||||\u{20}
            refs/remotes/origin/main|aaa||||\u{20}
            refs/remotes/upstream/main|bbb||||\u{20}
            """
        )
        let branches = try BranchParser.parse(text: text)

        #expect(branches.count == 3)
        #expect(!branches.contains { $0.refName == "refs/remotes/origin/HEAD" })

        let remote = try #require(branches.first { $0.refName == "refs/remotes/origin/main" })
        #expect(remote.kind == .remote)
        #expect(remote.name == "origin/main")
    }

    @Test("branch names containing non-ASCII characters round-trip")
    func unusualBranchNames() throws {
        let text = Self.format("refs/heads/feature/ünüsual-nàme|aaa||||\u{20}")
        let branches = try BranchParser.parse(text: text)

        #expect(branches.first?.name == "feature/ünüsual-nàme")
    }

    @Test("a truncated record is reported rather than silently mis-parsed")
    func malformedRecord() {
        #expect(throws: GitError.self) {
            try BranchParser.parse(text: Self.format("refs/heads/main|aaa|"))
        }
    }

    @Test("empty output yields no branches")
    func emptyOutput() throws {
        #expect(try BranchParser.parse(text: "").isEmpty)
    }
}
