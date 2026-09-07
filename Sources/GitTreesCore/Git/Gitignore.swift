import Foundation

/// Patterns and writes for Git's ignore files.
///
/// GitTrees edits these files itself rather than going through Git: ignore rules are
/// ordinary text, and `git` has no command that appends a path. Anchored patterns are
/// used wherever a rule is meant to be exact, so `README.md` does not ignore every
/// README in the tree.
public enum Gitignore {
    public static let fileName = ".gitignore"

    /// Which ignore file a rule is written to.
    ///
    /// The distinction matters more than it looks: `.gitignore` is a tracked file, so a
    /// rule added there is committed and imposed on everyone who clones the repository,
    /// while `info/exclude` never leaves the machine.
    public enum Destination: String, CaseIterable, Identifiable, Sendable, Hashable {
        /// `<worktree>/.gitignore` — versioned and shared.
        case repository
        /// `<common git dir>/info/exclude` — private to this clone.
        case local

        public var id: String { rawValue }

        /// Short label, as the file is normally referred to.
        public var displayName: String {
            switch self {
            case .repository: Gitignore.fileName
            case .local: ".git/info/exclude"
            }
        }

        /// What choosing this destination means, for the sheet's subtitle.
        public var summary: String {
            switch self {
            case .repository:
                "Committed with the repository. Everyone who clones it gets the rule."
            case .local:
                "Private to this clone and never committed. Applies to every worktree."
            }
        }
    }

    /// The ignore file a destination resolves to.
    ///
    /// Git reads `info/exclude` from the *common* git directory, not from a linked
    /// worktree's own git directory — a rule written there is repository-wide. (A file
    /// placed in `.git/worktrees/<name>/info/exclude` is simply never read.)
    public static func fileURL(
        for destination: Destination,
        worktree: URL,
        commonGitDir: URL
    ) -> URL {
        switch destination {
        case .repository:
            worktree.appendingPathComponent(fileName, isDirectory: false)
        case .local:
            commonGitDir
                .appendingPathComponent("info", isDirectory: true)
                .appendingPathComponent("exclude", isDirectory: false)
        }
    }

    // MARK: - Patterns

    /// A pattern that matches `path` and nothing else.
    ///
    /// `path` is the repository-relative path Git reports (forward slashes). Glob
    /// metacharacters are escaped so a file named `file[1].txt` is taken literally.
    public static func pattern(forPath path: String) -> String {
        "/" + escape(trimSlashes(path))
    }

    /// A pattern that matches one directory, at this exact path, and everything under it.
    public static func pattern(forDirectory path: String) -> String {
        "/" + escape(trimSlashes(path)) + "/"
    }

    /// A pattern that matches any directory with this name, at any depth.
    ///
    /// This is the `node_modules/` shape: the rule follows the name rather than the
    /// position, so it catches the folder wherever it turns up.
    public static func pattern(forDirectoryNamed name: String) -> String {
        escapingLeadingSyntax(escape(lastComponent(of: name))) + "/"
    }

    /// A pattern that matches any file with this name, at any depth.
    public static func pattern(forNameOf path: String) -> String {
        escapingLeadingSyntax(escape(lastComponent(of: path)))
    }

    /// A pattern matching every file sharing this path's extension, at any depth, or
    /// nil when the path has no extension to key on.
    public static func pattern(forExtensionOf path: String) -> String? {
        let name = lastComponent(of: path)
        // A leading dot is a dotfile (`.env`), not an extension.
        guard let dot = name.dropFirst().lastIndex(of: "."), dot != name.startIndex else { return nil }
        let ext = String(name[name.index(after: dot)...])
        guard !ext.isEmpty else { return nil }
        return "*." + escape(ext)
    }

    /// The folders containing `path`, from the innermost outwards.
    ///
    /// `src/generated/api/client.ts` yields `src/generated/api`, `src/generated`, `src`.
    /// A path at the top level has none, which is the one case with no folder to offer.
    public static func ancestorFolders(of path: String) -> [String] {
        let components = trimSlashes(path).split(separator: "/").map(String.init).dropLast()
        guard !components.isEmpty else { return [] }
        return (1...components.count)
            .reversed()
            .map { components.prefix($0).joined(separator: "/") }
    }

    // MARK: - Writing

    /// Appends `pattern` to `<worktree>/.gitignore`, creating the file if needed.
    @discardableResult
    public static func append(pattern: String, inWorktree worktree: URL) throws -> Bool {
        try append(pattern: pattern, to: worktree.appendingPathComponent(fileName, isDirectory: false))
    }

    /// Appends `pattern` to an ignore file, creating the file and its directory if needed.
    ///
    /// Returns false when an identical pattern is already present, so ignoring the same
    /// path twice is a no-op rather than a duplicate line.
    @discardableResult
    public static func append(pattern: String, to fileURL: URL) throws -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        if contains(pattern: trimmed, in: fileURL) { return false }
        let existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""

        var next = existing
        if !next.isEmpty, !next.hasSuffix("\n") {
            next.append("\n")
        }
        next.append(trimmed)
        next.append("\n")

        // `info/exclude` lives in a directory Git creates on demand, so it can be absent
        // in a repository that has never had one.
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try next.write(to: fileURL, atomically: true, encoding: .utf8)
        return true
    }

    /// True when `fileURL` already has this exact rule on a line of its own.
    ///
    /// A literal line match, not an evaluation of Git's rules: the question is whether
    /// writing this line would duplicate one, which is the only thing the callers — the
    /// duplicate guard in `append`, and the offer to add a rule that may already be
    /// there — actually need to know. A missing file simply contains nothing.
    public static func contains(pattern: String, in fileURL: URL) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        guard let existing = try? String(contentsOf: fileURL, encoding: .utf8) else { return false }
        return existing
            .split(separator: "\n", omittingEmptySubsequences: false)
            .contains { $0.trimmingCharacters(in: .whitespaces) == trimmed }
    }

    // MARK: - Text

    private static func trimSlashes(_ path: String) -> String {
        var trimmed = path
        while trimmed.hasPrefix("/") { trimmed.removeFirst() }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    private static func lastComponent(of path: String) -> String {
        let components = trimSlashes(path).split(separator: "/")
        return components.last.map(String.init) ?? trimSlashes(path)
    }

    /// `#` starts a comment and `!` a negation, but only in the first column. An
    /// anchored pattern begins with a slash and is never exposed to either; an
    /// unanchored one starts the line itself, so it is.
    private static func escapingLeadingSyntax(_ pattern: String) -> String {
        (pattern.hasPrefix("#") || pattern.hasPrefix("!")) ? "\\" + pattern : pattern
    }

    /// Escapes the glob metacharacters, so a path is matched as the literal text it is.
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
