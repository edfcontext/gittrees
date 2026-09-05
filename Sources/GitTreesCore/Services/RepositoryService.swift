import Foundation
import Observation

/// A Git error shaped for presentation, keeping the underlying detail for debugging.
public struct PresentableError: Identifiable, Sendable {
    public let id = UUID()
    public var title: String
    public var message: String
    /// The command that failed, its exit code and its output.
    public var detail: String?

    public init(title: String, message: String, detail: String? = nil) {
        self.title = title
        self.message = message
        self.detail = detail
    }

    public init(title: String, error: Error) {
        self.title = title
        if let failure = (error as? CommandExecutionError)?.failure {
            self.message = failure.message
            self.detail = """
            \(failure.commandLine)
            exit code: \(failure.exitCode)
            \(failure.workingDirectory.map { "directory: \($0)" } ?? "")
            \(failure.stdout.isEmpty ? "" : "\nstdout:\n\(failure.stdout)")
            """.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            self.message = error.localizedDescription
            self.detail = (error as? LocalizedError)?.recoverySuggestion
        }
    }
}

/// A long-running Git operation, surfaced as a progress indicator.
public struct ActiveOperation: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public var label: String
    /// Worktree the operation is running against, when it targets one.
    public var worktreePath: String?

    public init(label: String, worktreePath: String? = nil) {
        self.label = label
        self.worktreePath = worktreePath
    }

    public static func == (lhs: ActiveOperation, rhs: ActiveOperation) -> Bool { lhs.id == rhs.id }
}

/// Everything needed to create a worktree, as gathered by the New Worktree sheet.
public struct NewWorktreeRequest: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        /// Check out a branch that already exists.
        case existingBranch(String)
        /// Create a branch and its worktree in one `git worktree add -b`.
        case newBranch(name: String, startPoint: String)
    }

    public var mode: Mode
    public var path: URL
    public var openInEditor: Bool

    public init(mode: Mode, path: URL, openInEditor: Bool) {
        self.mode = mode
        self.path = path
        self.openInEditor = openInEditor
    }

    /// The branch the new worktree will have checked out.
    public var branchName: String {
        switch mode {
        case .existingBranch(let name): name
        case .newBranch(let name, _): name
        }
    }
}

/// Holds the state of the open repository and mediates every Git operation.
///
/// Views observe this object and call its methods; they never construct Git commands.
/// All state lives on the main actor, while Git itself runs on the cooperative pool
/// through `GitClient`, so the UI is never blocked by a process.
@MainActor
@Observable
public final class RepositoryService {

    // MARK: - State

    public private(set) var repository: Repository?
    public private(set) var worktrees: [Worktree] = []
    public private(set) var branches: [Branch] = []
    public private(set) var status: WorktreeStatus = .empty
    public private(set) var history: [CommitSummary] = []
    /// Dirty flag per worktree path, filled in by a background scan so the sidebar can
    /// show which worktrees have uncommitted work without blocking the first paint.
    public private(set) var dirtyStates: [String: Bool] = [:]
    /// Remotes configured on the repository.
    public private(set) var remotes: [Remote] = []
    /// The commit identity a commit in the selected worktree would use.
    public private(set) var identity: GitIdentity = .unknown
    /// GitHub CLI installation and sign-in state.
    public private(set) var gitHubAuth: GitHubAuth = .unknown
    /// The pull request already open for the selected worktree's branch, if any.
    public private(set) var pullRequest: PullRequest?

    /// Path of the selected worktree. Paths, not indices, so a refresh cannot
    /// silently move the selection to a different worktree.
    public var selectedWorktreePath: String? {
        didSet {
            guard selectedWorktreePath != oldValue else { return }
            status = .empty
            history = []
            selectedFile = nil
            pullRequest = nil
            refreshSelectedWorktree()
            Task { await refreshIdentity() }
            refreshGitHub()
        }
    }

    /// The file whose diff is shown, plus which side of the index it is shown for.
    public var selectedFile: FileChange?
    public var showingStagedDiff = false

    public private(set) var isLoadingRepository = false
    public private(set) var isRefreshing = false
    public private(set) var activeOperation: ActiveOperation?
    public var lastError: PresentableError?
    /// A directory the user opened that turned out not to be a repository.
    ///
    /// Held rather than reported as an error, because the useful next step is to offer
    /// to create a repository there.
    public private(set) var uninitializedDirectory: URL?
    /// Output of the last fetch/pull/push, shown in the operation banner.
    public private(set) var lastOperationOutput: String?

    private let preferences: PreferencesService
    private var client: GitClient
    private var gitExecutablePath: String
    private var gitHubClient: GitHubClient
    private var gitHubExecutablePath: String

    /// Worktrees with a destructive operation in flight.
    ///
    /// Main-actor isolation makes the test-and-insert atomic: the check happens before
    /// the first `await`, so two operations can never both pass it.
    private var busyWorktreePaths: Set<String> = []
    private var refreshTask: Task<Void, Never>?
    private var dirtyScanTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var gitHubTask: Task<Void, Never>?

    public init(preferences: PreferencesService) {
        self.preferences = preferences
        self.gitExecutablePath = preferences.gitExecutablePath
        self.client = GitClient(runner: GitProcessRunner(executablePath: preferences.gitExecutablePath))
        self.gitHubExecutablePath = preferences.gitHubExecutablePath
        self.gitHubClient = GitHubClient(runner: GitHubProcessRunner(executablePath: preferences.gitHubExecutablePath))
    }

    // MARK: - Derived state

    /// The remote fetch, pull and push act on.
    ///
    /// Nil means "let Git decide": fetch every remote, and let pull and push follow the
    /// branch's own tracking configuration, which is Git's own default behaviour.
    public var selectedRemote: String? {
        get {
            guard let repository else { return nil }
            let stored = preferences.preferredRemote(for: repository)
            // A remote that has since been removed must not keep being passed to Git.
            guard let stored, remotes.contains(where: { $0.name == stored }) else { return nil }
            return stored
        }
        set {
            guard let repository else { return }
            preferences.setPreferredRemote(newValue, for: repository)
        }
    }

    /// The remote to publish a new branch to.
    ///
    /// Prefers an explicit choice, then the remote the branch already tracks, then
    /// `origin`, then whatever single remote exists.
    public var remoteForPublishing: String? {
        if let selectedRemote { return selectedRemote }
        if let worktree = selectedWorktree,
           let upstream = branch(for: worktree)?.upstreamName,
           let remote = remotes.first(where: { upstream.hasPrefix($0.name + "/") }) {
            return remote.name
        }
        if remotes.contains(where: { $0.name == "origin" }) { return "origin" }
        return remotes.first?.name
    }

    public var selectedWorktree: Worktree? {
        guard let selectedWorktreePath else { return nil }
        return worktrees.first { $0.id == selectedWorktreePath }
    }

    public var localBranches: [Branch] {
        branches.filter { $0.kind == .local }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public var remoteBranches: [Branch] {
        branches.filter { $0.kind == .remote }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The worktree that has `branch` checked out, if any.
    ///
    /// `git worktree list` is the authority; `%(worktreepath)` from `for-each-ref` is
    /// the fallback for the rare case where the two disagree mid-operation.
    public func worktree(for branch: Branch) -> Worktree? {
        if let match = worktrees.first(where: { $0.branchRef == branch.refName }) {
            return match
        }
        guard let path = branch.worktreePath else { return nil }
        return worktrees.first { $0.path == path }
    }

    public func branch(for worktree: Worktree) -> Branch? {
        guard let ref = worktree.branchRef else { return nil }
        return branches.first { $0.refName == ref }
    }

    /// Whether the worktree has uncommitted changes. Nil until the scan has run.
    public func isDirty(_ worktree: Worktree) -> Bool? {
        dirtyStates[worktree.id]
    }

    public func isBusy(_ worktree: Worktree) -> Bool {
        busyWorktreePaths.contains(worktree.id)
    }

    /// True when Git would refuse to check this branch out here because another
    /// worktree already has it.
    public func isCheckedOutElsewhere(_ branch: Branch, from worktree: Worktree?) -> Bool {
        guard let holder = self.worktree(for: branch) else { return false }
        return holder.id != worktree?.id
    }

    // MARK: - Opening

    /// Opens any directory inside a repository, resolving it to the repository itself.
    public func open(directory: URL) async {
        isLoadingRepository = true
        defer { isLoadingRepository = false }
        rebuildClientIfNeeded()

        do {
            let discovered = try await client.discoverRepository(at: directory)
            repository = discovered
            preferences.noteOpened(discovered)
            selectedWorktreePath = nil
            worktrees = []
            branches = []
            await reload()
            // Prefer the worktree the user actually pointed at, then the main one.
            let requested = directory.standardizedFileURL.path
            selectedWorktreePath = worktrees.first { requested.hasPrefix($0.id) }?.id
                ?? worktrees.first { !$0.isBare }?.id
        } catch {
            repository = nil
            worktrees = []
            branches = []
            // "Not a repository" is an offer to make one, not a failure to report.
            if case GitError.notARepository = error {
                uninitializedDirectory = directory
            } else {
                lastError = PresentableError(title: "Could Not Open Repository", error: error)
            }
        }
    }

    /// Creates a repository in `directory` with `git init`, then opens it.
    public func initializeRepository(at directory: URL) async {
        uninitializedDirectory = nil
        let created = await withOperation(label: "Creating repository…") { [client] in
            try await client.initializeRepository(at: directory)
        } onFailure: { error in
            PresentableError(title: "Could Not Create Repository", error: error)
        } thenReturning: { true }

        guard created == true else { return }
        await open(directory: directory)
    }

    /// Dismisses the offer to create a repository without creating one.
    public func dismissInitializationPrompt() {
        uninitializedDirectory = nil
    }

    public func closeRepository() {
        repository = nil
        worktrees = []
        branches = []
        status = .empty
        history = []
        selectedWorktreePath = nil
        selectedFile = nil
        dirtyStates = [:]
        remotes = []
        identity = .unknown
        gitHubAuth = .unknown
        pullRequest = nil
        uninitializedDirectory = nil
    }

    // MARK: - Refresh

    /// Reloads worktrees and branches, then the selected worktree's status.
    public func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.reload()
            self?.refreshSelectedWorktree()
        }
    }

    private func reload() async {
        guard let repository else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            // These reads are independent; run them concurrently.
            async let worktreeList = client.worktrees(repository: repository.commandDirectory)
            async let branchList = client.branches(repository: repository.commandDirectory)
            async let remoteList = client.remotes(repository: repository.commandDirectory)
            let (loadedWorktrees, loadedBranches, loadedRemotes) =
                try await (worktreeList, branchList, remoteList)

            worktrees = loadedWorktrees
            branches = loadedBranches
            remotes = loadedRemotes

            // Keep the selection valid across worktree removals.
            if let selectedWorktreePath, !worktrees.contains(where: { $0.id == selectedWorktreePath }) {
                self.selectedWorktreePath = worktrees.first { !$0.isBare }?.id
            }
            scanDirtyStates()
            await refreshIdentity()
            refreshGitHub()
        } catch is CancellationError {
            return
        } catch {
            lastError = PresentableError(title: "Could Not Read Repository", error: error)
        }
    }

    /// Runs `git status` in every live worktree concurrently and publishes the results
    /// in one update, so the sidebar does not flicker row by row.
    private func scanDirtyStates() {
        dirtyScanTask?.cancel()
        let targets = worktrees.filter { !$0.isBare && !$0.isPrunable && !$0.isMissingOnDisk }
        let client = self.client
        dirtyScanTask = Task { [weak self] in
            var results: [String: Bool] = [:]
            await withTaskGroup(of: (String, Bool)?.self) { group in
                for worktree in targets {
                    group.addTask {
                        guard let dirty = try? await client.isDirty(worktree: worktree.path) else { return nil }
                        return (worktree.id, dirty)
                    }
                }
                for await result in group {
                    if let result { results[result.0] = result.1 }
                }
            }
            guard !Task.isCancelled else { return }
            self?.dirtyStates = results
        }
    }

    /// Reloads status and history for the selected worktree.
    public func refreshSelectedWorktree() {
        statusTask?.cancel()
        guard let worktree = selectedWorktree, !worktree.isBare, !worktree.isMissingOnDisk else {
            status = .empty
            history = []
            return
        }
        statusTask = Task { [weak self] in
            guard let self else { return }
            do {
                async let statusResult = self.client.statusSummary(worktree: worktree.path)
                async let logResult = self.client.log(worktree: worktree.path, limit: 200)
                let (loadedStatus, loadedHistory) = try await (statusResult, logResult)
                guard !Task.isCancelled, self.selectedWorktreePath == worktree.id else { return }
                self.status = loadedStatus
                self.history = loadedHistory
                self.reconcileSelectedFile()
            } catch is CancellationError {
                return
            } catch {
                guard self.selectedWorktreePath == worktree.id else { return }
                self.lastError = PresentableError(title: "Could Not Read Status", error: error)
            }
        }
    }

    /// Keeps the diff pane pointed at the same path after a refresh, and drops the
    /// selection when the path no longer has changes.
    private func reconcileSelectedFile() {
        guard let selectedFile else { return }
        if let updated = status.changes.first(where: { $0.path == selectedFile.path }) {
            self.selectedFile = updated
            if showingStagedDiff && !updated.hasStagedChanges { showingStagedDiff = false }
        } else {
            self.selectedFile = nil
        }
    }

    // MARK: - GitHub

    /// True when at least one remote points at GitHub.
    public var hasGitHubRemote: Bool {
        remotes.contains { ($0.fetchURL).map(GitHubClient.isGitHubRemoteURL) ?? false }
    }

    /// The branch a pull request from the selected worktree would merge into.
    ///
    /// A conventional default branch when one exists, falling back to any local branch
    /// other than the head itself. Only ever a suggestion — the user can change it.
    public var defaultBaseBranch: String? {
        let head = selectedWorktree?.branchName
        let names = localBranches.map(\.name)
        for candidate in ["main", "master", "develop", "trunk"] where names.contains(candidate) {
            if candidate != head { return candidate }
        }
        return names.first { $0 != head } ?? names.first
    }

    /// The branch a pull request would be opened from: the selected worktree's branch.
    public var pullRequestHeadBranch: String? {
        guard let worktree = selectedWorktree, !worktree.isDetached else { return nil }
        return worktree.branchName
    }

    /// Everything that must hold before `gh pr create` can run, or the reason it cannot.
    public var pullRequestBlocker: String? {
        guard repository != nil else { return "No repository is open." }
        if !gitHubAuth.isInstalled { return "The GitHub CLI is not installed." }
        if !gitHubAuth.isAuthenticated { return "You are not signed in to GitHub." }
        if !hasGitHubRemote { return "This repository has no GitHub remote." }
        guard let head = pullRequestHeadBranch else {
            return "Select a worktree with a branch checked out."
        }
        if branch(for: selectedWorktree ?? Worktree(path: URL(fileURLWithPath: "/")))?.hasUpstream == false {
            return "The branch \(head) has not been pushed yet."
        }
        return nil
    }

    public var canCreatePullRequest: Bool {
        pullRequestBlocker == nil
    }

    /// Reloads gh auth state and, when possible, the pull request open for the selected
    /// worktree. Cheap enough to run after every repository refresh.
    public func refreshGitHub() {
        gitHubTask?.cancel()
        let client = self.gitHubClient
        let executablePath = self.gitHubExecutablePath
        let worktree = selectedWorktree
        let lookupPossible = hasGitHubRemote
        gitHubTask = Task { [weak self] in
            let auth = await client.auth(executablePath: executablePath)
            guard !Task.isCancelled else { return }
            self?.gitHubAuth = auth

            guard auth.isReady, lookupPossible,
                  let worktree, !worktree.isBare, !worktree.isMissingOnDisk else {
                self?.pullRequest = nil
                return
            }
            let pr = try? await client.pullRequest(worktree: worktree.path)
            guard !Task.isCancelled, self?.selectedWorktreePath == worktree.id else { return }
            self?.pullRequest = pr
        }
    }

    /// Opens a pull request with `gh pr create`, then records it so the UI can link to it.
    public func createPullRequest(_ draft: PullRequestDraft) async -> PullRequest? {
        guard let worktree = selectedWorktree else { return nil }
        let created = await withOperation(label: "Creating pull request…", worktree: worktree) { [gitHubClient] in
            try await gitHubClient.createPullRequest(worktree: worktree.path, draft: draft)
        } onFailure: { error in
            PresentableError(title: "Could Not Create Pull Request", error: error)
        } thenReturning: { [weak self] (pr: PullRequest) -> PullRequest in
            self?.pullRequest = pr
            self?.lastOperationOutput = "Created pull request #\(pr.number)\n\(pr.url)"
            return pr
        }
        return created
    }

    /// Opens the pull request (or its create page) in the browser.
    public func openPullRequestInBrowser() async {
        guard let worktree = selectedWorktree else { return }
        _ = await withOperation(label: "Opening browser…", worktree: worktree) { [gitHubClient] in
            try await gitHubClient.openPullRequestInBrowser(worktree: worktree.path)
        } onFailure: { error in
            PresentableError(title: "Could Not Open Pull Request", error: error)
        } thenReturning: { }
    }

    // MARK: - Commit identity

    /// Reads the identity a commit would be authored with.
    ///
    /// Read in the selected worktree so the answer reflects the directory the commit
    /// would actually run in.
    public func refreshIdentity() async {
        guard let repository else {
            identity = .unknown
            return
        }
        let directory = selectedWorktree.map(\.path) ?? repository.commandDirectory
        identity = (try? await client.identity(directory: directory)) ?? .unknown
    }

    /// Pins the commit identity on the repository with `git config --local`.
    ///
    /// `--local` config lives in the shared git directory, so this applies to every
    /// worktree of the repository. Passing nil for both fields clears the pin and lets
    /// the user's global configuration show through again.
    public func setLocalIdentity(name: String?, email: String?) async {
        guard let repository else { return }
        _ = await withOperation(label: "Updating identity…") { [client] in
            try await client.setLocalIdentity(
                repository: repository.commandDirectory,
                name: name,
                email: email
            )
        } onFailure: { error in
            PresentableError(title: "Could Not Update Identity", error: error)
        } thenReturning: { [weak self] in
            await self?.refreshIdentity()
        }
    }

    // MARK: - Worktree lifecycle

    public func createWorktree(_ request: NewWorktreeRequest) async -> Worktree? {
        guard let repository else { return nil }
        // `withOperation` wraps a failure as nil, so the nested optional here is
        // "operation failed" outside and "worktree not found afterwards" inside.
        let created: Worktree?? = await withOperation(label: "Creating worktree…") { [client] in
            switch request.mode {
            case .existingBranch(let branch):
                try await client.createWorktree(
                    repository: repository.commandDirectory,
                    path: request.path,
                    checkingOut: branch
                )
            case .newBranch(let name, let startPoint):
                try await client.createWorktree(
                    repository: repository.commandDirectory,
                    path: request.path,
                    newBranch: name,
                    startingAt: startPoint
                )
            }
        } onFailure: { error in
            PresentableError(title: "Could Not Create Worktree", error: error)
        } thenReturning: { [weak self] () -> Worktree? in
            await self?.reload()
            let worktree = self?.worktrees.first { $0.path == request.path.standardizedFileURL }
            if let worktree { self?.selectedWorktreePath = worktree.id }
            return worktree
        }
        return created ?? nil
    }

    /// Reads the worktree's status so the caller can warn before a destructive removal.
    public func changesBlockingRemoval(of worktree: Worktree) async -> WorktreeStatus? {
        guard !worktree.isMissingOnDisk else { return nil }
        do {
            let status = try await client.statusSummary(worktree: worktree.path)
            return status.isClean ? nil : status
        } catch {
            // A worktree Git can no longer read is handled by the removal itself.
            return nil
        }
    }

    /// Removes a worktree. `force` is only ever passed after the user has been shown
    /// what would be discarded and has confirmed.
    @discardableResult
    public func removeWorktree(_ worktree: Worktree, force: Bool = false) async -> Bool {
        guard let repository else { return false }
        guard claim(worktree) else {
            lastError = PresentableError(
                title: "Operation In Progress",
                message: "Another operation is already running in \(worktree.path.path)."
            )
            return false
        }
        defer { release(worktree) }

        let succeeded = await withOperation(label: "Removing worktree…", worktree: worktree) { [client] in
            try await client.removeWorktree(
                repository: repository.commandDirectory,
                path: worktree.path,
                force: force
            )
        } onFailure: { error in
            PresentableError(title: "Could Not Remove Worktree", error: error)
        } thenReturning: { true } ?? false

        if succeeded {
            if selectedWorktreePath == worktree.id { selectedWorktreePath = nil }
            await reload()
            if selectedWorktreePath == nil {
                selectedWorktreePath = worktrees.first { !$0.isBare }?.id
            }
        }
        return succeeded
    }

    public func setLock(_ locked: Bool, on worktree: Worktree, reason: String? = nil) async {
        guard let repository else { return }
        _ = await withOperation(label: locked ? "Locking…" : "Unlocking…", worktree: worktree) { [client] in
            if locked {
                try await client.lockWorktree(
                    repository: repository.commandDirectory,
                    path: worktree.path,
                    reason: reason
                )
            } else {
                try await client.unlockWorktree(
                    repository: repository.commandDirectory,
                    path: worktree.path
                )
            }
        } onFailure: { error in
            PresentableError(title: locked ? "Could Not Lock Worktree" : "Could Not Unlock Worktree", error: error)
        } thenReturning: { [weak self] in
            await self?.reload()
        }
    }

    public func pruneWorktrees() async {
        guard let repository else { return }
        _ = await withOperation(label: "Pruning worktrees…") { [client] in
            try await client.pruneWorktrees(repository: repository.commandDirectory)
        } onFailure: { error in
            PresentableError(title: "Could Not Prune Worktrees", error: error)
        } thenReturning: { [weak self] output in
            self?.lastOperationOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
            await self?.reload()
        }
    }

    // MARK: - Branch actions

    /// Checks a branch out in an existing worktree.
    ///
    /// Git's own rule — a branch may be checked out in only one worktree — is left to
    /// Git; a refusal surfaces as an ordinary error.
    public func checkout(branch: Branch, in worktree: Worktree) async {
        guard claim(worktree) else { return }
        defer { release(worktree) }

        _ = await withOperation(label: "Checking out \(branch.name)…", worktree: worktree) { [client] in
            try await client.checkout(worktree: worktree.path, branch: branch.name)
        } onFailure: { error in
            PresentableError(title: "Could Not Check Out Branch", error: error)
        } thenReturning: { [weak self] in
            await self?.reload()
            self?.refreshSelectedWorktree()
        }
    }

    // MARK: - Staging

    public func stage(_ changes: [FileChange]) async {
        guard let worktree = selectedWorktree, !changes.isEmpty else { return }
        // A rename's old path must be staged too, or the deletion is left behind.
        let paths = changes.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }
        _ = await withOperation(label: "Staging…", worktree: worktree) { [client] in
            try await client.stage(worktree: worktree.path, paths: paths)
        } onFailure: { error in
            PresentableError(title: "Could Not Stage Changes", error: error)
        } thenReturning: { [weak self] in
            self?.refreshSelectedWorktree()
        }
    }

    public func unstage(_ changes: [FileChange]) async {
        guard let worktree = selectedWorktree, !changes.isEmpty else { return }
        let paths = changes.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) }
        _ = await withOperation(label: "Unstaging…", worktree: worktree) { [client] in
            try await client.unstage(worktree: worktree.path, paths: paths)
        } onFailure: { error in
            PresentableError(title: "Could Not Unstage Changes", error: error)
        } thenReturning: { [weak self] in
            self?.refreshSelectedWorktree()
        }
    }

    // MARK: - Diff

    /// The unified diff for one file, for either side of the index.
    public func diff(for change: FileChange, staged: Bool) async throws -> String {
        guard let worktree = selectedWorktree else { return "" }
        if change.kind == .untracked && !staged {
            return try await client.diffUntracked(worktree: worktree.path, path: change.path)
        }
        return try await client.diff(
            worktree: worktree.path,
            path: change.path,
            staged: staged,
            contextLines: preferences.diffContextLines
        )
    }

    // MARK: - Commit

    /// Commits the index. Hooks and commit configuration are left untouched.
    @discardableResult
    public func commit(message: String) async -> Bool {
        guard let worktree = selectedWorktree else { return false }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let output = await withOperation(label: "Committing…", worktree: worktree) { [client] in
            try await client.commit(worktree: worktree.path, message: trimmed)
        } onFailure: { error in
            PresentableError(title: "Commit Failed", error: error)
        } thenReturning: { [weak self] output -> String in
            await self?.reload()
            self?.refreshSelectedWorktree()
            return output
        }

        if let output {
            lastOperationOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return true
        }
        return false
    }

    // MARK: - Remotes

    /// Fetches the chosen remote, or every remote when none is chosen.
    public func fetch(prune: Bool = false) async {
        let remote = selectedRemote
        let label = remote.map { "Fetching \($0)…" } ?? "Fetching…"
        await runRemoteOperation(label: label, title: "Fetch Failed") { [client] worktree in
            try await client.fetch(worktree: worktree.path, remote: remote, prune: prune)
        }
    }

    public func pull() async {
        let remote = selectedRemote
        await runRemoteOperation(label: "Pulling…", title: "Pull Failed") { [client] worktree in
            try await client.pull(worktree: worktree.path, remote: remote)
        }
    }

    /// Pushes, publishing the branch when it has no upstream yet.
    public func push(setUpstream: Bool = false) async {
        // Publishing needs a named remote; an ordinary push can fall back to Git's own
        // tracking configuration.
        let remote = setUpstream ? remoteForPublishing : selectedRemote
        if setUpstream && remote == nil {
            lastError = PresentableError(
                title: "Push Failed",
                message: "This branch has no upstream and the repository has no remotes to publish it to.",
                detail: "Add a remote with git remote add, then push again."
            )
            return
        }
        await runRemoteOperation(label: "Pushing…", title: "Push Failed") { [client] worktree in
            try await client.push(worktree: worktree.path, remote: remote, setUpstream: setUpstream)
        }
    }

    /// True when the selected worktree's branch has never been pushed, so Push needs
    /// `--set-upstream`.
    public var selectedBranchNeedsUpstream: Bool {
        guard let worktree = selectedWorktree, let branch = branch(for: worktree) else { return false }
        return !branch.hasUpstream
    }

    private func runRemoteOperation(
        label: String,
        title: String,
        _ body: @escaping @Sendable (Worktree) async throws -> String
    ) async {
        guard let worktree = selectedWorktree else { return }
        guard claim(worktree) else { return }
        defer { release(worktree) }

        let output = await withOperation(label: label, worktree: worktree) {
            try await body(worktree)
        } onFailure: { error in
            PresentableError(title: title, error: error)
        } thenReturning: { [weak self] output -> String in
            await self?.reload()
            self?.refreshSelectedWorktree()
            return output
        }
        if let output {
            lastOperationOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Adds a remote and reloads, so the picker and Branch Info pick it up immediately.
    @discardableResult
    public func addRemote(name: String, url: String) async -> Bool {
        guard let repository else { return false }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedURL.isEmpty else { return false }

        let added = await withOperation(label: "Adding remote…") { [client] in
            try await client.addRemote(
                repository: repository.commandDirectory,
                name: trimmedName,
                url: trimmedURL
            )
        } onFailure: { error in
            PresentableError(title: "Could Not Add Remote", error: error)
        } thenReturning: { [weak self] in
            await self?.reload()
            return true
        }
        return added ?? false
    }

    /// Remote names already taken, so the sheet can say so before Git has to.
    public var remoteNames: Set<String> {
        Set(remotes.map(\.name))
    }

    public func clearOperationOutput() {
        lastOperationOutput = nil
    }

    // MARK: - Preferences plumbing

    /// Recreates the Git and GitHub clients when the user points at a different binary.
    public func rebuildClientIfNeeded() {
        if preferences.gitExecutablePath != gitExecutablePath {
            gitExecutablePath = preferences.gitExecutablePath
            client = GitClient(runner: GitProcessRunner(executablePath: gitExecutablePath))
        }
        if preferences.gitHubExecutablePath != gitHubExecutablePath {
            gitHubExecutablePath = preferences.gitHubExecutablePath
            gitHubClient = GitHubClient(runner: GitHubProcessRunner(executablePath: gitHubExecutablePath))
            refreshGitHub()
        }
    }

    // MARK: - Operation scaffolding

    /// Marks a worktree busy, returning false when something is already running there.
    private func claim(_ worktree: Worktree) -> Bool {
        busyWorktreePaths.insert(worktree.id).inserted
    }

    private func release(_ worktree: Worktree) {
        busyWorktreePaths.remove(worktree.id)
    }

    /// Runs `body` with a progress indicator, converting a throw into a presentable
    /// error and returning nil.
    @discardableResult
    private func withOperation<T, R>(
        label: String,
        worktree: Worktree? = nil,
        _ body: @escaping @Sendable () async throws -> T,
        onFailure: (Error) -> PresentableError,
        thenReturning finish: (T) async -> R
    ) async -> R? {
        let operation = ActiveOperation(label: label, worktreePath: worktree?.id)
        activeOperation = operation
        defer {
            if activeOperation == operation { activeOperation = nil }
        }
        do {
            let value = try await body()
            return await finish(value)
        } catch is CancellationError {
            return nil
        } catch {
            lastError = onFailure(error)
            return nil
        }
    }

    /// Overload for operations whose body returns `Void`.
    @discardableResult
    private func withOperation<R>(
        label: String,
        worktree: Worktree? = nil,
        _ body: @escaping @Sendable () async throws -> Void,
        onFailure: (Error) -> PresentableError,
        thenReturning finish: () async -> R
    ) async -> R? {
        await withOperation(label: label, worktree: worktree, body, onFailure: onFailure) { (_: Void) in
            await finish()
        }
    }
}
