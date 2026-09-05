import Foundation

/// Parses `git for-each-ref` output produced with an explicit `%00`-separated format.
///
/// `for-each-ref` has no `-z`, but its format language accepts `%00` as a literal NUL
/// byte, which gives the same guarantee: fields cannot be confused with content. Ref
/// names may not contain control characters, so LF remains a safe record separator.
public enum BranchParser {
    /// Field order must match `GitClient.branchFormat`.
    public static let fieldCount = 6

    public static func parse(_ data: Data) throws -> [Branch] {
        let text = String(decoding: data, as: UTF8.self)
        return try parse(text: text)
    }

    public static func parse(text: String) throws -> [Branch] {
        var branches: [Branch] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.components(separatedBy: "\u{0}")
            guard fields.count >= fieldCount else {
                throw GitError.unexpectedOutput(
                    reason: "expected \(fieldCount) fields per ref, got \(fields.count)",
                    arguments: ["for-each-ref"]
                )
            }
            let refName = fields[0]
            guard !refName.isEmpty else { continue }
            // `refs/remotes/origin/HEAD` is a symbolic alias, not a branch.
            if refName.hasSuffix("/HEAD") && refName.hasPrefix(RefName.remotePrefix) { continue }

            let kind: Branch.Kind = refName.hasPrefix(RefName.remotePrefix) ? .remote : .local
            let hasUpstream = !fields[2].isEmpty
            // An empty track field is ambiguous on its own: it means "level with
            // upstream" when an upstream exists, and "unknown" when none does.
            let track = parseTrack(fields[3], hasUpstream: hasUpstream)
            let worktree = fields[4].isEmpty ? nil : URL(fileURLWithPath: fields[4])

            branches.append(
                Branch(
                    refName: refName,
                    name: RefName.shortenLocal(refName),
                    kind: kind,
                    objectName: fields[1],
                    upstreamRef: fields[2].isEmpty ? nil : fields[2],
                    ahead: track.ahead,
                    behind: track.behind,
                    upstreamIsGone: track.gone,
                    worktreePath: worktree,
                    isCurrentHEAD: fields[5] == "*"
                )
            )
        }
        return branches
    }

    /// `%(upstream:track,nobracket)` yields `ahead 3`, `behind 2`, `ahead 3, behind 2`,
    /// `gone`, or an empty string when the branch is level with its upstream.
    static func parseTrack(_ value: String, hasUpstream: Bool) -> (ahead: Int?, behind: Int?, gone: Bool) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed == "gone" { return (nil, nil, true) }
        guard hasUpstream else { return (nil, nil, false) }
        if trimmed.isEmpty { return (0, 0, false) }

        var ahead: Int?
        var behind: Int?
        for component in trimmed.components(separatedBy: ",") {
            let parts = component.trimmingCharacters(in: .whitespaces).split(separator: " ")
            guard parts.count == 2, let count = Int(parts[1]) else { continue }
            switch parts[0] {
            case "ahead": ahead = count
            case "behind": behind = count
            default: break
            }
        }
        // Git omits the side that is zero, so a missing half means zero, not unknown.
        return (ahead ?? 0, behind ?? 0, false)
    }
}
