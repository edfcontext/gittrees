import Foundation

/// A Git repository, identified by the git directory shared by all of its worktrees.
///
/// Every worktree of the same repository resolves to the same `commonGitDir`, which is
/// what allows the application to group them instead of treating them as unrelated
/// repositories.
public struct Repository: Identifiable, Hashable, Sendable, Codable {
    /// Absolute path of the main (non-linked) worktree. For a bare repository this is
    /// the repository directory itself.
    public var mainWorktreePath: URL
    /// Absolute path of `git rev-parse --git-common-dir`; stable across all worktrees.
    public var commonGitDir: URL
    /// True when the main worktree is a bare repository.
    public var isBare: Bool

    public init(mainWorktreePath: URL, commonGitDir: URL, isBare: Bool) {
        self.mainWorktreePath = mainWorktreePath.standardizedFileURL
        self.commonGitDir = commonGitDir.standardizedFileURL
        self.isBare = isBare
    }

    public var id: String { commonGitDir.path }

    /// Display name, derived from the main worktree directory.
    public var name: String {
        let component = mainWorktreePath.lastPathComponent
        if component == ".git" || component.hasSuffix(".git") {
            let trimmed = component.hasSuffix(".git") ? String(component.dropLast(4)) : component
            return trimmed.isEmpty ? mainWorktreePath.deletingLastPathComponent().lastPathComponent : trimmed
        }
        return component
    }

    /// The directory Git commands should run in when addressing the repository as a whole.
    public var commandDirectory: URL {
        isBare ? commonGitDir : mainWorktreePath
    }
}

/// A repository the user has opened before.
public struct RecentRepository: Identifiable, Hashable, Sendable, Codable {
    public var path: URL
    public var name: String
    public var lastOpened: Date

    public init(path: URL, name: String, lastOpened: Date = Date()) {
        self.path = path.standardizedFileURL
        self.name = name
        self.lastOpened = lastOpened
    }

    public var id: String { path.path }
}
