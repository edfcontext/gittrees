import Foundation

/// A single Git worktree — either the repository's main worktree or a linked worktree.
///
/// Mirrors the attributes reported by `git worktree list --porcelain -z`.
public struct Worktree: Identifiable, Hashable, Sendable {
    /// Absolute path of the worktree on disk.
    public var path: URL
    /// The commit currently checked out, when known.
    public var head: String?
    /// Fully qualified ref (`refs/heads/feature/x`) when a branch is checked out.
    public var branchRef: String?
    /// True when the worktree has a detached HEAD.
    public var isDetached: Bool
    /// True when this entry is a bare repository rather than a checkout.
    public var isBare: Bool
    /// True when `git worktree lock` has been applied.
    public var isLocked: Bool
    /// Reason recorded with the lock, when one was supplied.
    public var lockReason: String?
    /// Non-nil when Git considers the worktree prunable; the value is Git's reason.
    public var prunableReason: String?
    /// True for the repository's main worktree (always the first entry Git reports).
    public var isMain: Bool

    public init(
        path: URL,
        head: String? = nil,
        branchRef: String? = nil,
        isDetached: Bool = false,
        isBare: Bool = false,
        isLocked: Bool = false,
        lockReason: String? = nil,
        prunableReason: String? = nil,
        isMain: Bool = false
    ) {
        self.path = path.standardizedFileURL
        self.head = head
        self.branchRef = branchRef
        self.isDetached = isDetached
        self.isBare = isBare
        self.isLocked = isLocked
        self.lockReason = lockReason
        self.prunableReason = prunableReason
        self.isMain = isMain
    }

    public var id: String { path.path }

    /// Short branch name (`feature/x`), or nil when detached or bare.
    public var branchName: String? {
        guard let branchRef else { return nil }
        return RefName.shortenLocal(branchRef)
    }

    public var isPrunable: Bool { prunableReason != nil }

    /// True when the recorded path is no longer present on disk.
    public var isMissingOnDisk: Bool {
        !FileManager.default.fileExists(atPath: path.path)
    }

    /// A short label for the worktree suitable for lists.
    public var displayName: String {
        if isBare { return "(bare)" }
        if let branchName { return branchName }
        if let head, isDetached { return "(detached \(String(head.prefix(7))))" }
        return path.lastPathComponent
    }
}

/// Helpers for translating between fully qualified and short ref names.
public enum RefName {
    public static let localPrefix = "refs/heads/"
    public static let remotePrefix = "refs/remotes/"
    public static let tagPrefix = "refs/tags/"

    /// `refs/heads/feature/x` -> `feature/x`; `refs/remotes/origin/main` -> `origin/main`.
    public static func shortenLocal(_ ref: String) -> String {
        if ref.hasPrefix(localPrefix) { return String(ref.dropFirst(localPrefix.count)) }
        if ref.hasPrefix(remotePrefix) { return String(ref.dropFirst(remotePrefix.count)) }
        if ref.hasPrefix(tagPrefix) { return String(ref.dropFirst(tagPrefix.count)) }
        return ref
    }

    public static func qualifyLocal(_ name: String) -> String {
        name.hasPrefix("refs/") ? name : localPrefix + name
    }
}
