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
    public var number: Int
    public var url: String
    public var title: String
    /// `OPEN`, `MERGED` or `CLOSED`.
    public var state: String
    public var isDraft: Bool
    public var baseRefName: String
    public var headRefName: String

    public init(
        number: Int,
        url: String,
        title: String,
        state: String,
        isDraft: Bool,
        baseRefName: String,
        headRefName: String
    ) {
        self.number = number
        self.url = url
        self.title = title
        self.state = state
        self.isDraft = isDraft
        self.baseRefName = baseRefName
        self.headRefName = headRefName
    }

    public var id: Int { number }

    public var isOpen: Bool { state.uppercased() == "OPEN" }

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
