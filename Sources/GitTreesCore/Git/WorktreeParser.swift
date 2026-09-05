import Foundation

/// Parses `git worktree list --porcelain -z`.
///
/// In `-z` mode every attribute line is terminated by NUL instead of LF, and worktree
/// records are separated by an empty line — that is, two consecutive NUL bytes. Using
/// `-z` means lock and prune reasons arrive verbatim rather than C-quoted, so no
/// unescaping is needed and paths with spaces or quotes survive intact.
public enum WorktreeParser {
    /// Parse the raw bytes Git produced. Accepts both the `-z` form and, as a fallback,
    /// the newline-separated porcelain form.
    public static func parse(_ data: Data) throws -> [Worktree] {
        let separator: UInt8 = data.contains(0x00) ? 0x00 : 0x0A
        let fields = data
            .split(separator: separator, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        return try parse(fields: fields)
    }

    /// Convenience for tests and for the newline form.
    public static func parse(porcelainText text: String) throws -> [Worktree] {
        try parse(Data(text.utf8))
    }

    static func parse(fields: [String]) throws -> [Worktree] {
        var worktrees: [Worktree] = []
        var current: Attributes?

        func flush() throws {
            guard let attributes = current else { return }
            current = nil
            guard let path = attributes.path else {
                throw GitError.unexpectedOutput(
                    reason: "worktree record without a path",
                    arguments: ["worktree", "list", "--porcelain", "-z"]
                )
            }
            worktrees.append(
                Worktree(
                    path: URL(fileURLWithPath: path),
                    head: attributes.head,
                    branchRef: attributes.branch,
                    isDetached: attributes.detached,
                    isBare: attributes.bare,
                    isLocked: attributes.locked,
                    lockReason: attributes.lockReason,
                    prunableReason: attributes.prunableReason,
                    // Git always reports the main worktree first.
                    isMain: worktrees.isEmpty
                )
            )
        }

        for field in fields {
            if field.isEmpty {
                try flush()
                continue
            }
            if current == nil { current = Attributes() }

            let (key, value) = Self.split(field)
            switch key {
            case "worktree":
                // A `worktree` key always opens a new record, even without a blank
                // separator before it.
                if current?.path != nil {
                    try flush()
                    current = Attributes()
                }
                current?.path = value
            case "HEAD":
                current?.head = value
            case "branch":
                current?.branch = value
            case "detached":
                current?.detached = true
            case "bare":
                current?.bare = true
            case "locked":
                current?.locked = true
                current?.lockReason = (value?.isEmpty ?? true) ? nil : value
            case "prunable":
                current?.prunableReason = (value?.isEmpty ?? true) ? "prunable" : value
            default:
                // Unknown attributes are ignored so a newer Git does not break parsing.
                continue
            }
        }
        try flush()
        return worktrees
    }

    /// Splits `"branch refs/heads/main"` into `("branch", "refs/heads/main")`.
    /// Only the first space separates key from value; the value may contain spaces.
    private static func split(_ field: String) -> (key: String, value: String?) {
        guard let index = field.firstIndex(of: " ") else {
            return (field, nil)
        }
        return (String(field[field.startIndex..<index]), String(field[field.index(after: index)...]))
    }

    private struct Attributes {
        var path: String?
        var head: String?
        var branch: String?
        var detached = false
        var bare = false
        var locked = false
        var lockReason: String?
        var prunableReason: String?
    }
}
