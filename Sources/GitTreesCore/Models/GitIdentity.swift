import Foundation

/// The `user.name` / `user.email` a commit made here would be authored with.
///
/// Both the resolved values (what Git will actually use) and the repository-local
/// values are kept, so the UI can say *where* an identity came from rather than just
/// showing a name.
public struct GitIdentity: Sendable, Hashable {
    /// Where the effective identity is configured.
    public enum Scope: Sendable, Hashable {
        /// Pinned on this repository with `git config --local`.
        case repository
        /// Coming from the user's global or system configuration.
        case inherited
        /// Partly local, partly inherited — one of name/email is pinned and the other is not.
        case mixed
        /// Git has no identity here; a commit would fail.
        case unset
    }

    /// Resolved `user.name`, as `git config --get user.name` reports it.
    public var name: String?
    /// Resolved `user.email`.
    public var email: String?
    /// `user.name` set with `--local`, if any.
    public var localName: String?
    /// `user.email` set with `--local`, if any.
    public var localEmail: String?

    public init(name: String? = nil, email: String? = nil, localName: String? = nil, localEmail: String? = nil) {
        self.name = name.flatMap { $0.isEmpty ? nil : $0 }
        self.email = email.flatMap { $0.isEmpty ? nil : $0 }
        self.localName = localName.flatMap { $0.isEmpty ? nil : $0 }
        self.localEmail = localEmail.flatMap { $0.isEmpty ? nil : $0 }
    }

    public static let unknown = GitIdentity()

    /// True when Git has everything it needs to author a commit.
    public var isComplete: Bool {
        name != nil && email != nil
    }

    public var isPinnedToRepository: Bool {
        localName != nil || localEmail != nil
    }

    public var scope: Scope {
        guard isComplete else { return .unset }
        switch (localName != nil, localEmail != nil) {
        case (true, true): return .repository
        case (false, false): return .inherited
        default: return .mixed
        }
    }

    public var scopeDescription: String {
        switch scope {
        case .repository: "Set on this repository"
        case .inherited: "Inherited from your global Git configuration"
        case .mixed: "Partly set on this repository, partly inherited"
        case .unset: "Not configured"
        }
    }

    /// `Dev <dev@example.com>`, or nil when Git has no usable identity.
    public var displayName: String? {
        guard let name, let email else { return nil }
        return "\(name) <\(email)>"
    }
}

/// A configured Git remote.
public struct Remote: Identifiable, Hashable, Sendable {
    public var name: String
    /// The URL `git fetch <name>` would use, when Git could report one.
    public var fetchURL: String?

    public init(name: String, fetchURL: String? = nil) {
        self.name = name
        self.fetchURL = fetchURL
    }

    public var id: String { name }
}
