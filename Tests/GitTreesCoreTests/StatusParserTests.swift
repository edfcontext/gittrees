import Foundation
import Testing
@testable import GitTreesCore

/// Fixtures captured from real repositories with
/// `git status --porcelain=v2 -z --branch --untracked-files=all | tr '\0' '|'`.
@Suite("StatusParser")
struct StatusParserTests {

    static func porcelainZ(_ text: String) -> Data {
        Data(text.replacingOccurrences(of: "|", with: "\u{0}").utf8)
    }

    /// One repository containing a modified file, a deleted file, a rename with a
    /// space in the path, a staged addition and an untracked file.
    static let mixedFixture = porcelainZ(
        """
        # branch.oid 3a41334e2640dc50b4225ebaebeec7e4f84dbd88|# branch.head main|\
        1 .M N... 100644 100644 100644 ce013625030ba8dba906f756967f9e9ca394464a ce013625030ba8dba906f756967f9e9ca394464a README.md|\
        1 .D N... 100644 100644 000000 61780798228d17af2d34fce4cfbdf35556832472 61780798228d17af2d34fce4cfbdf35556832472 src/b.txt|\
        2 RM N... 100644 100644 100644 78981922613b2afb6025042ff6bd878ac1994e85 78981922613b2afb6025042ff6bd878ac1994e85 R100 src/renamed a.txt|src/a.txt|\
        1 A. N... 000000 100644 100644 0000000000000000000000000000000000000000 19d9cc8584ac2c7dcf57d2680375e80f099dc481 staged.txt|\
        ? docs/new note.md|
        """
    )

    /// A repository mid-merge, with an add/add and a content conflict.
    static let conflictFixture = porcelainZ(
        """
        # branch.oid bb6b7a9d39ae7c5c3040e621c9cc162fe3ea99ba|# branch.head main|\
        1 D. N... 100644 000000 000000 abaddc0b9edd523c69166a2c9f3a9e31a4c873e3 0000000000000000000000000000000000000000 gone.txt|\
        u AA N... 000000 100644 100644 100644 0000000000000000000000000000000000000000 351be5bf6e17c59ea560546d69654115ecb2fd8d 76d4bb83f8dab3933a481bd2d65fbcc1283ef9b7 both.txt|\
        u UU N... 100644 100644 100644 100644 df967b96a579e45a18b8251732d16804b2e56a55 b19a1e93bec1317dc6097229e12afaffbfa74dc2 950b81b7eee953d050aa05a641f8e056c85dd1bd f.txt|
        """
    )

    @Test("branch headers are read from the # lines")
    func branchHeaders() throws {
        let data = Self.porcelainZ(
            "# branch.oid abc123|# branch.head feature/zpl|# branch.upstream origin/feature/zpl|# branch.ab +2 -3|"
        )
        let status = try StatusParser.parse(data)

        #expect(status.commit == "abc123")
        #expect(status.branch == "feature/zpl")
        #expect(status.upstream == "origin/feature/zpl")
        #expect(status.ahead == 2)
        #expect(status.behind == 3)
        #expect(status.isClean)
    }

    @Test("an unborn HEAD reports no commit")
    func unbornHead() throws {
        let status = try StatusParser.parse(Self.porcelainZ("# branch.oid (initial)|# branch.head main|"))

        #expect(status.commit == nil)
        #expect(status.branch == "main")
    }

    @Test("a detached HEAD is recognised")
    func detachedHead() throws {
        let status = try StatusParser.parse(Self.porcelainZ("# branch.oid abc|# branch.head (detached)|"))

        #expect(status.isDetached)
    }

    @Test("a file modified in the working tree only is unstaged")
    func modifiedFile() throws {
        let status = try StatusParser.parse(Self.mixedFixture)
        let readme = try #require(status.changes.first { $0.path == "README.md" })

        #expect(readme.indexStatus == .unmodified)
        #expect(readme.worktreeStatus == .modified)
        #expect(readme.hasUnstagedChanges)
        #expect(!readme.hasStagedChanges)
        #expect(readme.kind == .tracked)
    }

    @Test("a file added to the index is staged and not also unstaged")
    func stagedFile() throws {
        let status = try StatusParser.parse(Self.mixedFixture)
        let staged = try #require(status.changes.first { $0.path == "staged.txt" })

        #expect(staged.indexStatus == .added)
        #expect(staged.worktreeStatus == .unmodified)
        #expect(staged.hasStagedChanges)
        #expect(!staged.hasUnstagedChanges)
        #expect(status.stagedChanges.map(\.path).contains("staged.txt"))
    }

    @Test("a deletion in the working tree is reported as deleted")
    func deletedFile() throws {
        let status = try StatusParser.parse(Self.mixedFixture)
        let deleted = try #require(status.changes.first { $0.path == "src/b.txt" })

        #expect(deleted.worktreeStatus == .deleted)
        #expect(deleted.hasUnstagedChanges)
    }

    @Test("a rename keeps both paths, including one containing a space")
    func renamedFile() throws {
        let status = try StatusParser.parse(Self.mixedFixture)
        let renamed = try #require(status.changes.first { $0.path == "src/renamed a.txt" })

        #expect(renamed.indexStatus == .renamed)
        #expect(renamed.worktreeStatus == .modified)
        #expect(renamed.originalPath == "src/a.txt")
        #expect(renamed.similarity == 100)
        // The extra NUL-terminated original-path field must not be read as its own entry.
        #expect(!status.changes.contains { $0.path == "src/a.txt" })
    }

    @Test("an untracked file is listed separately from tracked changes")
    func untrackedFile() throws {
        let status = try StatusParser.parse(Self.mixedFixture)
        let untracked = try #require(status.changes.first { $0.kind == .untracked })

        #expect(untracked.path == "docs/new note.md")
        #expect(untracked.fileName == "new note.md")
        #expect(untracked.directory == "docs")
        #expect(untracked.hasUnstagedChanges)
        #expect(!untracked.hasStagedChanges)
    }

    @Test("ignored entries are tagged and never counted as changes to commit")
    func ignoredFile() throws {
        let status = try StatusParser.parse(Self.porcelainZ("! build/output.o|"))
        let ignored = try #require(status.changes.first)

        #expect(ignored.kind == .ignored)
        #expect(!ignored.hasStagedChanges)
    }

    @Test("merge conflicts are parsed with their conflict pair")
    func mergeConflicts() throws {
        let status = try StatusParser.parse(Self.conflictFixture)

        #expect(status.conflicts.count == 2)
        let bothAdded = try #require(status.changes.first { $0.path == "both.txt" })
        #expect(bothAdded.isConflicted)
        #expect(bothAdded.rawXY == "AA")
        #expect(bothAdded.conflictDescription == "both added")

        let bothModified = try #require(status.changes.first { $0.path == "f.txt" })
        #expect(bothModified.rawXY == "UU")
        #expect(bothModified.conflictDescription == "both modified")

        // Conflicts are excluded from the ordinary unstaged list so they can be
        // surfaced on their own.
        #expect(!status.unstagedChanges.contains { $0.isConflicted })
    }

    @Test("a staged deletion alongside conflicts is still a normal staged change")
    func stagedDeletionDuringMerge() throws {
        let status = try StatusParser.parse(Self.conflictFixture)
        let gone = try #require(status.changes.first { $0.path == "gone.txt" })

        #expect(gone.indexStatus == .deleted)
        #expect(gone.hasStagedChanges)
    }

    @Test("a submodule entry is flagged")
    func submoduleEntry() throws {
        let data = Self.porcelainZ(
            "1 .M SC.. 160000 160000 160000 aaaa bbbb vendor/lib|"
        )
        let status = try StatusParser.parse(data)

        #expect(status.changes.first?.isSubmodule == true)
    }

    @Test("the dirty summary counts the categories the removal warning shows")
    func dirtySummary() throws {
        let status = try StatusParser.parse(Self.mixedFixture)
        let summary = status.dirtySummary

        #expect(summary.contains("3 modified files"))
        #expect(summary.contains("1 deleted file"))
        #expect(summary.contains("1 untracked file"))
    }

    @Test("clean output produces no changes")
    func cleanWorktree() throws {
        let status = try StatusParser.parse(Self.porcelainZ("# branch.oid abc|# branch.head main|"))

        #expect(status.isClean)
        #expect(status.dirtySummary.isEmpty)
    }
}
