import Foundation

/// Patterns and writes for a worktree's `.gitignore`.
///
/// GitTrees edits the file itself rather than going through Git: ignore rules are
/// ordinary text, and `git` has no command that appends a path. The pattern is
/// anchored at the repository root so `README.md` does not ignore every README.
public enum Gitignore {
    public static let fileName = ".gitignore"

    /// A gitignore pattern that matches `path` and nothing else.
    ///
    /// `path` is the repository-relative path Git reports (forward slashes). Glob
    /// metacharacters are escaped so a file named `file[1].txt` is taken literally.
    public static func pattern(forPath path: String) -> String {
        "/" + escape(trimSlashes(path))
    }

    /// A gitignore pattern that matches a directory and everything under it.
    public static func pattern(forDirectory path: String) -> String {
        let escaped = escape(trimSlashes(path))
        return escaped.hasSuffix("/") ? "/" + escaped : "/" + escaped + "/"
    }

    /// Appends `pattern` to `<worktree>/.gitignore`, creating the file if needed.
    ///
    /// Returns false when an identical pattern is already present, so a second
    /// ignore of the same path is a no-op rather than a duplicate line.
    @discardableResult
    public static func append(pattern: String, inWorktree worktree: URL) throws -> Bool {
        let url = worktree.appendingPathComponent(fileName, isDirectory: false)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let alreadyPresent = existing
            .split(separator: "\n", omittingEmptySubsequences: false)
            .contains { $0.trimmingCharacters(in: .whitespaces) == pattern }
        if alreadyPresent { return false }

        var next = existing
        if !next.isEmpty, !next.hasSuffix("\n") {
            next.append("\n")
        }
        next.append(pattern)
        next.append("\n")
        try next.write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    private static func trimSlashes(_ path: String) -> String {
        var trimmed = path
        while trimmed.hasPrefix("/") { trimmed.removeFirst() }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    private static func escape(_ path: String) -> String {
        var escaped = ""
        for character in path {
            switch character {
            case "*", "?", "[", "\\":
                escaped.append("\\")
                escaped.append(character)
            default:
                escaped.append(character)
            }
        }
        if escaped.hasSuffix(" ") {
            escaped = String(escaped.dropLast()) + "\\ "
        }
        return escaped
    }
}
