import Foundation

/// What the app knows about the GitHub CLI's readiness in the current repository.
///
/// Modelled as observed state rather than thrown errors, because "gh is installed but
/// not signed in" is a normal condition the UI should explain, not a failure.
public struct GitHubAuth: Sendable, Hashable {
    public var isInstalled: Bool
    public var isAuthenticated: Bool
    /// The signed-in account, e.g. `octocat`, when `gh auth status` reports one.
    public var account: String?
    /// The host the account is on, e.g. `github.com`.
    public var host: String?
    /// The path the check ran against, so Settings can show which binary answered.
    public var executablePath: String?

    public init(
        isInstalled: Bool = false,
        isAuthenticated: Bool = false,
        account: String? = nil,
        host: String? = nil,
        executablePath: String? = nil
    ) {
        self.isInstalled = isInstalled
        self.isAuthenticated = isAuthenticated
        self.account = account.flatMap { $0.isEmpty ? nil : $0 }
        self.host = host.flatMap { $0.isEmpty ? nil : $0 }
        self.executablePath = executablePath
    }

    public static let unknown = GitHubAuth()

    /// True when a pull request can actually be created.
    public var isReady: Bool { isInstalled && isAuthenticated }

    /// A one-line description for Settings and the create sheet.
    public var summary: String {
        guard isInstalled else { return "GitHub CLI not found" }
        guard isAuthenticated else { return "Installed, but not signed in" }
        if let account, let host {
            return "Signed in to \(host) as \(account)"
        }
        if let account {
            return "Signed in as \(account)"
        }
        return "Signed in"
    }
}

/// Everything needed to open a pull request, as gathered by the create sheet.
public struct PullRequestDraft: Sendable, Equatable {
    public var title: String
    public var body: String
    /// The branch to merge into, e.g. `main`.
    public var base: String
    /// The branch that carries the changes — the checked-out branch of the worktree.
    public var head: String
    public var isDraft: Bool

    public init(title: String, body: String, base: String, head: String, isDraft: Bool = false) {
        self.title = title
        self.body = body
        self.base = base
        self.head = head
        self.isDraft = isDraft
    }
}

/// A pull request, as reported by `gh pr view --json`.
///
/// The field names match gh's JSON exactly so the same type decodes its output directly.
public struct PullRequest: Identifiable, Hashable, Sendable, Codable {
    public struct Author: Hashable, Sendable, Codable {
        public var login: String

        public init(login: String) {
            self.login = login
        }
    }

    public var number: Int
    public var url: String
    public var title: String
    /// `OPEN`, `MERGED` or `CLOSED`.
    public var state: String
    public var isDraft: Bool
    public var baseRefName: String
    public var headRefName: String
    public var headRefOid: String?
    public var baseRefOid: String?
    public var changedFiles: Int?
    public var author: Author?

    public init(
        number: Int,
        url: String,
        title: String,
        state: String,
        isDraft: Bool,
        baseRefName: String,
        headRefName: String,
        headRefOid: String? = nil,
        author: Author? = nil,
        baseRefOid: String? = nil,
        changedFiles: Int? = nil
    ) {
        self.number = number
        self.url = url
        self.title = title
        self.state = state
        self.isDraft = isDraft
        self.baseRefName = baseRefName
        self.headRefName = headRefName
        self.headRefOid = headRefOid
        self.author = author
        self.baseRefOid = baseRefOid
        self.changedFiles = changedFiles
    }

    public var id: Int { number }

    public var isOpen: Bool { state.uppercased() == "OPEN" }
    public var isMerged: Bool { state.uppercased() == "MERGED" }

    public func hasSameRevision(as other: PullRequest) -> Bool {
        url == other.url && headRefOid == other.headRefOid
            && baseRefName == other.baseRefName && baseRefOid == other.baseRefOid
    }

    public func isAuthored(by account: String?) -> Bool {
        guard let account, let author else { return false }
        return author.login.caseInsensitiveCompare(account) == .orderedSame
    }

    /// `#42 · main ← feature/x`, for compact display.
    public var shortDescription: String {
        "#\(number) · \(baseRefName) ← \(headRefName)"
    }

    public var stateLabel: String {
        switch state.uppercased() {
        case "OPEN": isDraft ? "Draft" : "Open"
        case "MERGED": "Merged"
        case "CLOSED": "Closed"
        default: state.capitalized
        }
    }
}

public struct PullRequestChanges: Sendable {
    public let request: PullRequest
    public let files: [PullRequestFile]
}

public struct PullRequestFile: Decodable, Identifiable, Sendable {
    public let filename: String
    public let previousFilename: String?
    public let status: String
    public let additions: Int
    public let deletions: Int
    public let patch: String?

    private enum CodingKeys: String, CodingKey {
        case filename, status, additions, deletions, patch
        case previousFilename = "previous_filename"
    }

    public var id: String { filename }

    /// GitHub may omit trailing hunks from large patches.
    public var hasPartialPatch: Bool {
        guard let patch, !patch.isEmpty else { return false }
        var added = 0
        var removed = 0
        for line in patch.utf8.split(separator: 0x0A) {
            if line.first == 0x2B { added += 1 }
            if line.first == 0x2D { removed += 1 }
        }
        return added < additions || removed < deletions
    }
}

public enum PullRequestMergeMethod: String, CaseIterable, Sendable {
    case merge, squash, rebase

    public var label: String {
        switch self {
        case .merge: "Create a Merge Commit"
        case .squash: "Squash and Merge"
        case .rebase: "Rebase and Merge"
        }
    }
}

public enum PullRequestAction: Sendable {
    case approve
    case merge(PullRequestMergeMethod)
}

/// Errors from driving the GitHub CLI.
public enum GitHubError: Error, LocalizedError, Sendable {
    case executableNotFound(path: String)
    case launchFailed(arguments: [String], reason: String)
    case commandFailed(GitFailure)
    /// gh is present but no account is signed in.
    case notAuthenticated
    /// The repository has no remote pointing at GitHub.
    case noGitHubRemote
    /// The head branch has no upstream on the remote yet, so there is nothing to compare.
    case branchNotPushed(branch: String)
    /// gh's JSON did not match the expected shape.
    case unexpectedOutput(reason: String)
    case pullRequestChanged

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let path):
            return "The GitHub CLI was not found at \(path)."
        case .launchFailed(let arguments, let reason):
            return "Could not run gh \(arguments.joined(separator: " ")): \(reason)"
        case .commandFailed(let failure):
            return failure.message
        case .notAuthenticated:
            return "You are not signed in to GitHub."
        case .noGitHubRemote:
            return "This repository has no GitHub remote."
        case .branchNotPushed(let branch):
            return "The branch \(branch) has not been pushed yet."
        case .unexpectedOutput(let reason):
            return "Unexpected output from gh: \(reason)"
        case .pullRequestChanged:
            return "The pull request changed. Refresh its changed files and review the latest diff."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .executableNotFound:
            return "Install the GitHub CLI (brew install gh), or set its path in Settings."
        case .notAuthenticated:
            return "Run gh auth login in a terminal, then try again."
        case .noGitHubRemote:
            return "Add a remote whose URL points at github.com."
        case .branchNotPushed:
            return "Push the branch first, then create the pull request."
        default:
            return nil
        }
    }

    /// The underlying process failure, when this came from a non-zero exit.
    public var failure: GitFailure? {
        if case .commandFailed(let failure) = self { return failure }
        return nil
    }
}

extension GitHubError: CommandExecutionError {}
