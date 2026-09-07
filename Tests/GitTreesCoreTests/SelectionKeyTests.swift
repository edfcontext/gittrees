import Foundation
import Testing
@testable import GitTreesCore

/// The identity the Changes list selects by.
///
/// A path alone would be ambiguous — a partially staged file is two rows — and it would
/// also make a refresh lose the selection every time a file moved between the staged and
/// unstaged sections. These cover both.
@Suite("Changes selection keys")
struct SelectionKeyTests {

    /// A partially staged file: in the index *and* modified again in the working tree.
    static func partiallyStaged(_ path: String) -> FileChange {
        FileChange(path: path, indexStatus: .modified, worktreeStatus: .modified)
    }

    static func staged(_ path: String) -> FileChange {
        FileChange(path: path, indexStatus: .modified, worktreeStatus: .unmodified)
    }

    static func unstaged(_ path: String) -> FileChange {
        FileChange(path: path, indexStatus: .unmodified, worktreeStatus: .modified)
    }

    @Test("a key round-trips through its side and path")
    func keyRoundTrip() {
        let key = WorktreeStatus.selectionKey(path: "src/a.txt", staged: true)
        let selection = WorktreeStatus.selection(fromKey: key)

        #expect(selection?.path == "src/a.txt")
        #expect(selection?.staged == true)
        // A colon in the path is not a separator: only the first one is.
        let odd = WorktreeStatus.selectionKey(path: "notes/12:30.md", staged: false)
        #expect(WorktreeStatus.selection(fromKey: odd)?.path == "notes/12:30.md")
        #expect(WorktreeStatus.selection(fromKey: "nonsense") == nil)
    }

    @Test("a partially staged file is two selectable rows")
    func partiallyStagedFileIsTwoRows() {
        let status = WorktreeStatus(changes: [Self.partiallyStaged("src/a.txt")])

        #expect(status.selectionKeys == ["staged:src/a.txt", "worktree:src/a.txt"])
        #expect(status.change(forSelectionKey: "staged:src/a.txt")?.path == "src/a.txt")
        #expect(status.change(forSelectionKey: "worktree:src/a.txt")?.path == "src/a.txt")
    }

    @Test("conflicted and untracked entries are selectable on the working-tree side only")
    func conflictsAndUntrackedRows() {
        let status = WorktreeStatus(changes: [
            FileChange(path: "merged.txt", indexStatus: .unmerged, worktreeStatus: .unmerged, kind: .unmerged, rawXY: "UU"),
            FileChange(path: "new.txt", indexStatus: .unmodified, worktreeStatus: .added, kind: .untracked)
        ])

        #expect(status.selectionKeys == ["worktree:merged.txt", "worktree:new.txt"])
        #expect(status.change(forSelectionKey: "staged:new.txt") == nil)
    }

    @Test("a selection follows a file that moves between the two sections")
    func selectionFollowsAFileAcrossTheIndex() {
        let before = WorktreeStatus(changes: [Self.unstaged("src/a.txt")])
        let after = WorktreeStatus(changes: [Self.staged("src/a.txt")])

        // Staged from somewhere else — the row moved, but "this file" did not.
        #expect(after.survivingSelectionKey(for: "worktree:src/a.txt") == "staged:src/a.txt")
        // And back again.
        #expect(before.survivingSelectionKey(for: "staged:src/a.txt") == "worktree:src/a.txt")
    }

    @Test("a row that is still there keeps its own side")
    func selectionPrefersItsOwnSide() {
        let status = WorktreeStatus(changes: [Self.partiallyStaged("src/a.txt")])

        // Both sides exist, so neither key is nudged onto the other.
        #expect(status.survivingSelectionKey(for: "worktree:src/a.txt") == "worktree:src/a.txt")
        #expect(status.survivingSelectionKey(for: "staged:src/a.txt") == "staged:src/a.txt")
    }

    @Test("a path with no changes left drops out of the selection")
    func committedPathsDropOut() {
        let status = WorktreeStatus(changes: [Self.unstaged("src/b.txt")])

        #expect(status.survivingSelectionKey(for: "staged:src/a.txt") == nil)
        #expect(WorktreeStatus.empty.survivingSelectionKey(for: "worktree:src/b.txt") == nil)
    }
}
