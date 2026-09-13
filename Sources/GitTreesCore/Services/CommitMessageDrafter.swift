import Foundation

/// Drafts a short, editable commit subject from the staged changes.
///
/// Deliberately a local heuristic, not a model: it reads the same staged `FileChange`
/// list the UI already has — no extra Git call, no network, nothing to install — and
/// produces an imperative one-liner ("Update CommitView.swift", "Add 4 files in
/// Sources/GitTreesCore") that the user commits or rewrites.
public enum CommitMessageDrafter {

    /// A short subject for `changes` — whatever set the caller means to commit — or an
    /// empty string when there is nothing to describe.
    ///
    /// The caller decides which files belong (the staged set, or the set Stage All is
    /// about to stage); this summarizes all of them, reading each file's changed side
    /// rather than assuming it is already staged.
    public static func draft(for changes: [FileChange]) -> String {
        let relevant = changes.filter { effectiveStatus(of: $0) != nil }
        guard !relevant.isEmpty else { return "" }
        return relevant.count == 1 ? summarize(relevant[0]) : summarize(relevant)
    }

    /// The meaningful change for a file, preferring the staged side but falling back to
    /// the working-tree side for a file not yet staged (as during Stage All). Nil when
    /// the entry carries no change to describe (unmodified or ignored).
    private static func effectiveStatus(of change: FileChange) -> FileChange.Status? {
        if change.kind == .ignored { return nil }
        if change.kind == .untracked { return .added }
        if change.indexStatus != .unmodified { return change.indexStatus }
        if change.worktreeStatus != .unmodified { return change.worktreeStatus }
        return nil
    }

    // MARK: - One file

    private static func summarize(_ change: FileChange) -> String {
        switch effectiveStatus(of: change) {
        case .renamed:
            let old = change.originalPath.map(lastComponent) ?? "file"
            return "Rename \(old) to \(change.fileName)"
        case .added, .copied:
            return "Add \(change.fileName)"
        case .deleted:
            return "Delete \(change.fileName)"
        default:
            return "Update \(change.fileName)"
        }
    }

    // MARK: - Several files

    private static func summarize(_ changes: [FileChange]) -> String {
        let verb = commonVerb(for: changes)

        // Up to three files are named outright; more are grouped by type ("13 ts, 12
        // java and 2 md files"), which reads better than a bare count for a large stage.
        if changes.count <= 3 {
            return "\(verb) \(list(changes.map(\.fileName)))"
        }
        return "\(verb) \(byType(changes))"
    }

    /// A per-extension breakdown, most common first: "13 ts, 12 java and 2 md files".
    ///
    /// At most the top three extensions are named; everything past that — including files
    /// with no extension — folds into an "N other" tally so the subject stays short. When
    /// nothing has an extension there is nothing to group by, so it falls back to a count
    /// scoped to the shared directory.
    private static func byType(_ changes: [FileChange]) -> String {
        var counts: [String: Int] = [:]
        for change in changes {
            if let ext = fileExtension(of: change.fileName) {
                counts[ext, default: 0] += 1
            }
        }
        let ranked = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        guard !ranked.isEmpty else {
            let directory = commonDirectory(of: changes.map(\.path))
            return directory.isEmpty ? "\(changes.count) files" : "\(changes.count) files in \(directory)"
        }

        let top = ranked.prefix(3)
        var pieces = top.map { "\($0.value) \($0.key)" }
        let other = changes.count - top.reduce(0) { $0 + $1.value }
        if other > 0 { pieces.append("\(other) other") }
        return "\(list(pieces)) files"
    }

    /// The lower-cased extension of a filename, or nil for a name with none (or a dotfile
    /// like `.env`, whose leading dot is not an extension).
    private static func fileExtension(of fileName: String) -> String? {
        guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else { return nil }
        let ext = fileName[fileName.index(after: dot)...]
        return ext.isEmpty ? nil : ext.lowercased()
    }

    /// The single verb that fits every change, or "Update" when they disagree.
    private static func commonVerb(for changes: [FileChange]) -> String {
        let verbs = Set(changes.map(verb(for:)))
        return verbs.count == 1 ? (verbs.first ?? "Update") : "Update"
    }

    private static func verb(for change: FileChange) -> String {
        switch effectiveStatus(of: change) {
        case .added, .copied: "Add"
        case .deleted: "Delete"
        case .renamed: "Rename"
        default: "Update"
        }
    }

    // MARK: - Text

    /// `["a"]` → `a`; `["a", "b"]` → `a and b`; `["a", "b", "c"]` → `a, b and c`.
    private static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default:
            return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        }
    }

    private static func lastComponent(_ path: String) -> String {
        String(path.split(separator: "/").last ?? Substring(path))
    }

    /// The deepest directory shared by every path, or an empty string when they share
    /// none (files at the repository root, or spread across unrelated trees).
    private static func commonDirectory(of paths: [String]) -> String {
        let directories = paths.map { path -> [String] in
            var components = path.split(separator: "/").map(String.init)
            components.removeLast() // drop the filename
            return components
        }
        guard var shared = directories.first else { return "" }
        for directory in directories.dropFirst() {
            var prefix: [String] = []
            for (a, b) in zip(shared, directory) where a == b { prefix.append(a) }
            shared = prefix
            if shared.isEmpty { break }
        }
        return shared.joined(separator: "/")
    }
}
