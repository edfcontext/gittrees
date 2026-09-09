import Foundation

/// One entry on the stash stack, as reported by `git stash list`.
///
/// The `selector` (`stash@{0}`) is only valid at the moment it was read — pushing or
/// dropping a stash renumbers the rest — so actions address a stash by its `commit`,
/// resolving the current selector at the time they run. A stash is an ordinary commit,
/// which is why the sha is a stable handle.
public struct Stash: Identifiable, Hashable, Sendable {
    /// The reflog selector at read time, e.g. `stash@{0}`.
    public var selector: String
    /// The stash commit's sha — the stable handle used to address it.
    public var commit: String
    /// The branch the stash was created on, when the reflog subject names one.
    public var branch: String?
    /// The human message, without the `On <branch>:` / `WIP on <branch>:` prefix.
    public var message: String
    /// The stash's creation time, when Git supplied a parseable date.
    public var date: Date?

    public init(
        selector: String,
        commit: String,
        branch: String? = nil,
        message: String,
        date: Date? = nil
    ) {
        self.selector = selector
        self.commit = commit
        self.branch = branch
        self.message = message
        self.date = date
    }

    /// The sha is the stable identity across refreshes, where the selector shifts as the
    /// stack changes. It is unique in normal use; two byte-identical stashes committed in
    /// the same second would collide, but producing that takes deliberately scripted
    /// commits rather than anything the UI can do.
    public var id: String { commit }

    /// Short sha for display.
    public var shortCommit: String { String(commit.prefix(7)) }
}
