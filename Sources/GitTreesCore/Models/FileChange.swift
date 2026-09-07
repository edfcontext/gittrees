import Foundation

/// A single changed path reported by `git status --porcelain=v2 -z`.
public struct FileChange: Identifiable, Hashable, Sendable {
    /// The per-side status letter Git reports in the XY field.
    public enum Status: Character, Sendable, Hashable, CaseIterable {
        case unmodified = "."
        case modified = "M"
        case typeChanged = "T"
        case added = "A"
        case deleted = "D"
        case renamed = "R"
        case copied = "C"
        case unmerged = "U"

        public init(code: Character) {
            self = Status(rawValue: code) ?? .modified
        }

        public var label: String {
            switch self {
            case .unmodified: "Unmodified"
            case .modified: "Modified"
            case .typeChanged: "Type Changed"
            case .added: "Added"
            case .deleted: "Deleted"
            case .renamed: "Renamed"
            case .copied: "Copied"
            case .unmerged: "Conflicted"
            }
        }
    }

    /// How Git classified the entry as a whole.
    public enum Kind: String, Sendable, Hashable {
        case tracked
        case untracked
        case ignored
        case unmerged
    }

    /// Repository-relative path, using forward slashes as Git reports it.
    public var path: String
    /// Source path for renames and copies.
    public var originalPath: String?
    /// Left-hand XY letter: the difference between HEAD and the index.
    public var indexStatus: Status
    /// Right-hand XY letter: the difference between the index and the working tree.
    public var worktreeStatus: Status
    public var kind: Kind
    /// Similarity score for renames and copies (0-100).
    public var similarity: Int?
    /// Raw XY field, preserved for conflicts where the pair is meaningful (e.g. `DU`).
    public var rawXY: String
    /// True when the entry is a submodule.
    public var isSubmodule: Bool

    public init(
        path: String,
        originalPath: String? = nil,
        indexStatus: Status,
        worktreeStatus: Status,
        kind: Kind = .tracked,
        similarity: Int? = nil,
        rawXY: String = "",
        isSubmodule: Bool = false
    ) {
        self.path = path
        self.originalPath = originalPath
        self.indexStatus = indexStatus
        self.worktreeStatus = worktreeStatus
        self.kind = kind
        self.similarity = similarity
        self.rawXY = rawXY
        self.isSubmodule = isSubmodule
    }

    public var id: String { "\(kind.rawValue):\(path)" }

    /// True when part of this path is in the index and would be included in a commit.
    public var hasStagedChanges: Bool {
        kind == .tracked && indexStatus != .unmodified
    }

    /// True when part of this path differs between the index and the working tree.
    public var hasUnstagedChanges: Bool {
        switch kind {
        case .untracked, .ignored, .unmerged: true
        case .tracked: worktreeStatus != .unmodified
        }
    }

    public var isConflicted: Bool { kind == .unmerged }

    /// The last path component, for dense list rendering.
    public var fileName: String {
        String(path.split(separator: "/").last ?? Substring(path))
    }

    /// The directory portion, for the secondary line in dense list rendering.
    public var directory: String {
        let components = path.split(separator: "/")
        guard components.count > 1 else { return "" }
        return components.dropLast().joined(separator: "/")
    }

    /// Human readable description of the conflict pair for unmerged entries.
    public var conflictDescription: String? {
        guard kind == .unmerged else { return nil }
        switch rawXY {
        case "DD": return "both deleted"
        case "AU": return "added by us"
        case "UD": return "deleted by them"
        case "UA": return "added by them"
        case "DU": return "deleted by us"
        case "AA": return "both added"
        case "UU": return "both modified"
        default: return "conflicted (\(rawXY))"
        }
    }
}

/// The full result of a status query: branch headers plus changed paths.
public struct WorktreeStatus: Sendable, Hashable {
    public var commit: String?
    /// Branch name from `# branch.head`, or `(detached)`.
    public var branch: String?
    /// Upstream from `# branch.upstream`, e.g. `origin/main`.
    public var upstream: String?
    public var ahead: Int?
    public var behind: Int?
    public var changes: [FileChange]

    public init(
        commit: String? = nil,
        branch: String? = nil,
        upstream: String? = nil,
        ahead: Int? = nil,
        behind: Int? = nil,
        changes: [FileChange] = []
    ) {
        self.commit = commit
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.changes = changes
    }

    public static let empty = WorktreeStatus()

    public var isDetached: Bool { branch == "(detached)" }

    public var stagedChanges: [FileChange] { changes.filter(\.hasStagedChanges) }
    public var unstagedChanges: [FileChange] { changes.filter { $0.hasUnstagedChanges && !$0.isConflicted } }
    public var conflicts: [FileChange] { changes.filter(\.isConflicted) }
    public var isClean: Bool { changes.isEmpty }

    // MARK: - Selection

    /// Identifies one row of the Changes list.
    ///
    /// A path is not enough: the same file appears in both the staged and unstaged
    /// sections when part of it is in the index and part is not, and the two rows show
    /// different diffs. Which side of the index the row is on is part of its identity.
    public static func selectionKey(path: String, staged: Bool) -> String {
        "\(staged ? "staged" : "worktree"):\(path)"
    }

    /// Splits a selection key back into the side and the path it names.
    public static func selection(fromKey key: String) -> (path: String, staged: Bool)? {
        guard let separator = key.firstIndex(of: ":") else { return nil }
        let side = key[key.startIndex..<separator]
        guard side == "staged" || side == "worktree" else { return nil }
        return (String(key[key.index(after: separator)...]), side == "staged")
    }

    /// Every row the Changes list would show, as selection keys.
    public var selectionKeys: Set<String> {
        var keys: Set<String> = []
        for change in stagedChanges {
            keys.insert(WorktreeStatus.selectionKey(path: change.path, staged: true))
        }
        for change in unstagedChanges + conflicts {
            keys.insert(WorktreeStatus.selectionKey(path: change.path, staged: false))
        }
        return keys
    }

    /// The change a selection key names, or nil when the row is gone.
    public func change(forSelectionKey key: String) -> FileChange? {
        guard selectionKeys.contains(key),
              let selection = WorktreeStatus.selection(fromKey: key)
        else { return nil }
        return changes.first { $0.path == selection.path }
    }

    /// Where a selection should sit after a refresh.
    ///
    /// A row that is still there keeps its key. A path that only moved between the two
    /// sections — staged elsewhere, or unstaged elsewhere — follows the file rather than
    /// dropping the selection, which is what the user means by "this file". A path with
    /// no changes left has nothing to select.
    public func survivingSelectionKey(for key: String) -> String? {
        guard let selection = WorktreeStatus.selection(fromKey: key) else { return nil }
        if selectionKeys.contains(key) { return key }
        let flipped = WorktreeStatus.selectionKey(path: selection.path, staged: !selection.staged)
        return selectionKeys.contains(flipped) ? flipped : nil
    }

    /// Counts used by the "cannot remove worktree" warning.
    public var dirtySummary: [String] {
        var parts: [String] = []
        let tracked = changes.filter { $0.kind == .tracked }
        let modified = tracked.filter { $0.indexStatus != .deleted && $0.worktreeStatus != .deleted }.count
        let deleted = tracked.filter { $0.indexStatus == .deleted || $0.worktreeStatus == .deleted }.count
        let untracked = changes.filter { $0.kind == .untracked }.count
        let conflicted = conflicts.count
        if modified > 0 { parts.append("\(modified) modified file\(modified == 1 ? "" : "s")") }
        if deleted > 0 { parts.append("\(deleted) deleted file\(deleted == 1 ? "" : "s")") }
        if untracked > 0 { parts.append("\(untracked) untracked file\(untracked == 1 ? "" : "s")") }
        if conflicted > 0 { parts.append("\(conflicted) conflicted file\(conflicted == 1 ? "" : "s")") }
        return parts
    }
}
