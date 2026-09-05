import Foundation

/// Suggests where a new worktree should live, given a repository and a branch name.
///
/// The convention this supports is a sibling worktree root per repository:
///
///     Repository:    ~/Development/nalcus/summit
///     Worktree root: ~/Development/nalcus/worktrees/summit
///     Branch:        feature/zpl-templates
///     Suggestion:    ~/Development/nalcus/worktrees/summit/zpl-templates
public enum WorktreePathSuggester {
    /// Prefixes stripped when turning a branch name into a directory name. These are
    /// conventions, not Git semantics, so the result is only ever a suggestion.
    public static let strippedPrefixes = ["feature/", "feat/", "bugfix/", "fix/", "hotfix/", "chore/", "release/"]

    /// The default worktree root for a repository: `<parent>/worktrees/<repo name>`.
    public static func defaultWorktreeRoot(forRepositoryAt path: URL) -> URL {
        path
            .deletingLastPathComponent()
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent(path.lastPathComponent, isDirectory: true)
    }

    /// Turns `feature/zpl-templates` into `zpl-templates`.
    ///
    /// Only one leading convention prefix is removed; remaining slashes become dashes so
    /// the result is a single directory rather than a nested tree.
    public static func directoryName(forBranch branch: String) -> String {
        var name = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in strippedPrefixes where name.lowercased().hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            break
        }
        name = name.replacingOccurrences(of: "/", with: "-")
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "-. "))
        return name.isEmpty ? "worktree" : name
    }

    /// The suggested directory for a branch under a worktree root.
    public static func suggestedPath(worktreeRoot: URL, branch: String) -> URL {
        worktreeRoot.appendingPathComponent(directoryName(forBranch: branch), isDirectory: true)
    }

    /// Appends `-2`, `-3`, … when the suggested directory is already taken, so the
    /// suggestion is one Git will accept.
    public static func availablePath(_ candidate: URL, fileManager: FileManager = .default) -> URL {
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }
        let parent = candidate.deletingLastPathComponent()
        let base = candidate.lastPathComponent
        for suffix in 2...99 {
            let next = parent.appendingPathComponent("\(base)-\(suffix)", isDirectory: true)
            if !fileManager.fileExists(atPath: next.path) { return next }
        }
        return candidate
    }
}
