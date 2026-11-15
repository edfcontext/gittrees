import Foundation

/// The default advertised by a locally known remote HEAD. No network lookup is needed.
public struct GitDefaultBranch: Sendable {
    public var localRef: String
    public var remoteRef: String
}

public enum GraphBranchSelection {
    public static func defaultBranch(from branches: [Branch], remoteDefault: GitDefaultBranch?) -> Branch? {
        if let remoteDefault {
            if let local = branches.first(where: { $0.refName == remoteDefault.localRef }) { return local }
            if let tracking = branches.first(where: { $0.kind == .local && $0.upstreamRef == remoteDefault.remoteRef }) {
                return tracking
            }
            if let remote = branches.first(where: { $0.refName == remoteDefault.remoteRef }) { return remote }
        }
        // Local-only repositories may not have a remote HEAD. Prefer conventional
        // default names before considering the current feature branch.
        for name in ["main", "master", "trunk", "develop"] {
            if let local = branches.first(where: { $0.kind == .local && $0.name == name }) { return local }
        }
        for name in ["main", "master", "trunk", "develop"] {
            if let remote = branches.first(where: { $0.kind == .remote && $0.name.hasSuffix("/" + name) }) {
                return remote
            }
        }
        return branches.first { $0.isCurrentHEAD } ?? branches.first
    }
}
