import Foundation
import Testing
@testable import GitTreesCore

@Suite("CommitMessageDrafter")
struct CommitMessageDrafterTests {

    /// A staged change with the given index status — the side a commit would include.
    private func staged(_ path: String, _ status: FileChange.Status, original: String? = nil) -> FileChange {
        FileChange(
            path: path,
            originalPath: original,
            indexStatus: status,
            worktreeStatus: .unmodified,
            kind: .tracked
        )
    }

    @Test("an empty or unmodified set drafts an empty subject")
    func emptyWhenNothingToDescribe() {
        #expect(CommitMessageDrafter.draft(for: []) == "")
        // A truly unmodified entry carries nothing to describe.
        let unmodified = FileChange(path: "a.txt", indexStatus: .unmodified, worktreeStatus: .unmodified)
        #expect(CommitMessageDrafter.draft(for: [unmodified]) == "")
    }

    @Test("a file changed only in the working tree is summarized by that side")
    func worktreeSideIsSummarized() {
        // This is what Stage All passes: files not yet staged, so the change is on the
        // working-tree side. They must still be described (the bug was they were dropped).
        let modified = FileChange(path: "src/App.swift", indexStatus: .unmodified, worktreeStatus: .modified)
        #expect(CommitMessageDrafter.draft(for: [modified]) == "Update App.swift")

        let untracked = FileChange(path: "New.swift", indexStatus: .unmodified, worktreeStatus: .added, kind: .untracked)
        #expect(CommitMessageDrafter.draft(for: [untracked]) == "Add New.swift")

        let both = [modified, untracked]
        #expect(CommitMessageDrafter.draft(for: both) == "Update App.swift and New.swift")
    }

    @Test("one file names the file and the action")
    func singleFile() {
        #expect(CommitMessageDrafter.draft(for: [staged("Sources/App/CommitView.swift", .modified)])
            == "Update CommitView.swift")
        #expect(CommitMessageDrafter.draft(for: [staged("README.md", .added)]) == "Add README.md")
        #expect(CommitMessageDrafter.draft(for: [staged("old.txt", .deleted)]) == "Delete old.txt")
    }

    @Test("a rename names both ends")
    func rename() {
        let change = staged("Sources/New.swift", .renamed, original: "Sources/Old.swift")
        #expect(CommitMessageDrafter.draft(for: [change]) == "Rename Old.swift to New.swift")
    }

    @Test("two or three files are listed by name with the shared verb")
    func fewFilesListed() {
        let two = [staged("a/One.swift", .modified), staged("b/Two.swift", .modified)]
        #expect(CommitMessageDrafter.draft(for: two) == "Update One.swift and Two.swift")

        let three = [
            staged("A.swift", .added),
            staged("B.swift", .added),
            staged("C.swift", .added)
        ]
        #expect(CommitMessageDrafter.draft(for: three) == "Add A.swift, B.swift and C.swift")
    }

    @Test("mixed actions fall back to Update")
    func mixedActions() {
        let mixed = [staged("A.swift", .added), staged("B.swift", .deleted)]
        #expect(CommitMessageDrafter.draft(for: mixed) == "Update A.swift and B.swift")
    }

    @Test("many files of one type are counted by that extension")
    func manyFilesOneType() {
        let changes = (1...5).map { staged("Sources/Services/File\($0).swift", .modified) }
        #expect(CommitMessageDrafter.draft(for: changes) == "Update 5 swift files")
    }

    @Test("many files are grouped by extension, most common first")
    func manyFilesGroupedByType() {
        let changes =
            (1...13).map { staged("web/f\($0).ts", .modified) }
            + (1...12).map { staged("api/F\($0).java", .modified) }
            + (1...2).map { staged("docs/d\($0).md", .modified) }
        #expect(CommitMessageDrafter.draft(for: changes) == "Update 13 ts, 12 java and 2 md files")
    }

    @Test("beyond three types, the rest fold into an \"other\" tally")
    func manyTypesFoldToOther() {
        let changes =
            (1...13).map { staged("f\($0).ts", .modified) }
            + (1...12).map { staged("F\($0).java", .modified) }
            + (1...3).map { staged("d\($0).md", .modified) }
            + (1...2).map { staged("g\($0).go", .modified) }
            + [staged("h.rb", .modified)]
        // Top three named; go + rb collapse into "3 other".
        #expect(CommitMessageDrafter.draft(for: changes) == "Update 13 ts, 12 java, 3 md and 3 other files")
    }

    @Test("extensionless files count toward \"other\" alongside typed ones")
    func extensionlessCountAsOther() {
        let changes = [
            staged("src/A.ts", .modified),
            staged("src/B.ts", .modified),
            staged("src/C.ts", .modified),
            staged("Makefile", .modified),
            staged("LICENSE", .modified)
        ]
        #expect(CommitMessageDrafter.draft(for: changes) == "Update 3 ts and 2 other files")
    }

    @Test("with no extensions at all it falls back to a count in the shared directory")
    func extensionlessFallsBackToCount() {
        let changes = [
            staged("bin/run", .modified),
            staged("bin/build", .modified),
            staged("bin/test", .modified),
            staged("bin/deploy", .modified)
        ]
        #expect(CommitMessageDrafter.draft(for: changes) == "Update 4 files in bin")
    }
}
