import Foundation

/// A local or remote-tracking branch.
public struct Branch: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable, Hashable {
        case local
        case remote
    }

    /// Fully qualified ref name, e.g. `refs/heads/feature/x`.
    public var refName: String
    /// Short name, e.g. `feature/x` or `origin/main`.
    public var name: String
    public var kind: Kind
    /// Commit the ref points at.
    public var objectName: String
    /// Fully qualified upstream ref, when configured.
    public var upstreamRef: String?
    /// Commits ahead of upstream, when Git could compute it.
    public var ahead: Int?
    /// Commits behind upstream, when Git could compute it.
    public var behind: Int?
    /// True when the configured upstream no longer exists.
    public var upstreamIsGone: Bool
    /// Path of the worktree that has this branch checked out, as reported by Git.
    public var worktreePath: URL?
    /// True when this branch is HEAD of the worktree the query ran in.
    public var isCurrentHEAD: Bool

    public init(
        refName: String,
        name: String,
        kind: Kind,
        objectName: String,
        upstreamRef: String? = nil,
        ahead: Int? = nil,
        behind: Int? = nil,
        upstreamIsGone: Bool = false,
        worktreePath: URL? = nil,
        isCurrentHEAD: Bool = false
    ) {
        self.refName = refName
        self.name = name
        self.kind = kind
        self.objectName = objectName
        self.upstreamRef = upstreamRef
        self.ahead = ahead
        self.behind = behind
        self.upstreamIsGone = upstreamIsGone
        self.worktreePath = worktreePath?.standardizedFileURL
        self.isCurrentHEAD = isCurrentHEAD
    }

    public var id: String { refName }

    /// Short upstream name, e.g. `origin/main`.
    public var upstreamName: String? {
        guard let upstreamRef else { return nil }
        return RefName.shortenLocal(upstreamRef)
    }

    public var hasUpstream: Bool { upstreamRef != nil }

    /// Compact tracking description such as `↑2 ↓1`, or nil when there is nothing to say.
    public var trackingSummary: String? {
        if upstreamIsGone { return "upstream gone" }
        var parts: [String] = []
        if let ahead, ahead > 0 { parts.append("↑\(ahead)") }
        if let behind, behind > 0 { parts.append("↓\(behind)") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
