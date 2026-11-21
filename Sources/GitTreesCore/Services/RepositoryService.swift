import Foundation
import Observation

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
        /// Inspect a specific commit without creating or moving a branch.
        case detachedCommit(String)
    }

    /// What happens to the uncommitted changes in the worktree the request was made from.
    public enum UncommittedChanges: String, Sendable, Equatable, CaseIterable, Identifiable {
        /// Leave them where they are. The new worktree starts clean.
        case leave
        /// Take them out of the source worktree and put them in the new one.
        case move
        /// Put them in the new worktree and leave the source worktree as it was.
        case copy

        public var id: String { rawValue }
    }

    public var mode: Mode
    public var path: URL
    public var openInEditor: Bool
    public var uncommittedChanges: UncommittedChanges
    /// A rule to add to the local exclude file once the worktree exists, so a worktree
    /// root that happens to sit inside the repository does not show up as untracked.
    /// Nil when there is nothing to add or the user declined.
    public var ignoreRule: String?

    public init(
        mode: Mode,
        path: URL,
        openInEditor: Bool,
        uncommittedChanges: UncommittedChanges = .leave,
        ignoreRule: String? = nil
    ) {
        self.mode = mode
        self.path = path
        self.openInEditor = openInEditor
        self.uncommittedChanges = uncommittedChanges
        self.ignoreRule = ignoreRule
    }

    /// The branch the new worktree will have checked out, or empty for a detached checkout.
    public var branchName: String {
        switch mode {
        case .existingBranch(let name): name
        case .newBranch(let name, _): name
        case .detachedCommit: ""
        }
    }

    /// A name for path suggestions and transfer messages, including detached checkouts.
    public var checkoutName: String {
        if case .detachedCommit(let hash) = mode { return "commit-\(hash.prefix(12))" }
        return branchName
    }
}

/// Everything needed to create a new workspace folder, initialise it, and add a remote.
public struct NewWorkspaceRequest: Sendable, Equatable {
    public var directory: URL
    public var remoteName: String
    public var remoteURL: String
    public var openInEditor: Bool

    public init(directory: URL, remoteName: String, remoteURL: String, openInEditor: Bool) {
        self.directory = directory
        self.remoteName = remoteName
        self.remoteURL = remoteURL
        self.openInEditor = openInEditor
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
    public private(set) var defaultBranch: Branch?
    public private(set) var status: WorktreeStatus = .empty
    public private(set) var history: [CommitSummary] = []
    /// Changes even when refs are unchanged, so a manual refresh can retry Graph.
    public private(set) var graphRevision = 0
    /// Dirty flag per worktree path, filled in by a background scan so the sidebar can
    /// show which worktrees have uncommitted work without blocking the first paint.
    public private(set) var dirtyStates: [String: Bool] = [:]
    /// Best-effort last activity per worktree, gathered alongside the dirty scan.
    public private(set) var worktreeActivityDates: [String: Date] = [:]
    /// Remotes configured on the repository.
    public private(set) var remotes: [Remote] = []
    /// The commit identity a commit in the selected worktree would use.
    public private(set) var identity: GitIdentity = .unknown
    /// GitHub CLI installation and sign-in state.
    public private(set) var gitHubAuth: GitHubAuth = .unknown
    /// The pull request already open for the selected worktree's branch, if any.
    public private(set) var pullRequest: PullRequest?
    /// The merge or rebase the selected worktree is in the middle of, when its status
    /// shows conflicts — so the UI can offer the right Abort and map ours/theirs.
    public private(set) var mergeOperation: GitClient.InProgressOperation = .none
    /// The repository's stash stack, newest first. Shared across worktrees.
    public private(set) var stashes: [Stash] = []
    /// The stash whose diff the Stashes panel is showing, addressed by commit.
    public var selectedStashID: Stash.ID?
    private var stashRecoveryNotices: [String: StashRecoveryNotice] = [:]

    /// Recovery for the selected worktree, independent of the dismissible error alert.
    public var stashRecovery: StashRecoveryNotice? {
        selectedWorktreePath.flatMap { stashRecoveryNotices[$0] }
    }

    public func dismissStashRecovery() {
        guard let selectedWorktreePath else { return }
        stashRecoveryNotices.removeValue(forKey: selectedWorktreePath)
    }

    /// Path of the selected worktree. Paths, not indices, so a refresh cannot
    /// silently move the selection to a different worktree.
    public var selectedWorktreePath: String? {
        didSet {
            guard selectedWorktreePath != oldValue else { return }
            status = .empty
            history = []
            selectedFileKeys = []
            selectedFile = nil
            pullRequest = nil
            refreshSelectedWorktree()
            Task { await refreshIdentity() }
            refreshGitHub()
        }
    }

    /// The rows selected in Changes, as `WorktreeStatus` selection keys.
    ///
    /// A set rather than one key, because the list supports the ordinary macOS
    /// multi-selection gestures and stage/unstage/ignore act on everything selected.
    public var selectedFileKeys: Set<String> = []

    /// The file whose diff is shown, plus which side of the index it is shown for.
    ///
    /// Only ever set when exactly one row is selected: a diff pane showing one of several
    /// selected files would be showing an arbitrary one.
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
    private var windowActivationTask: Task<Void, Never>?
    private var autoFetchTask: Task<Void, Never>?
    /// When the last opportunistic fetch ran, so activation does not fetch on every focus.
    private var lastAutoFetch: Date?
    /// The shortest gap between opportunistic fetches.
    private static let autoFetchInterval: TimeInterval = 180
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

    /// The repository's main worktree, when it is a real checkout rather than a bare repo.
    public var mainWorktree: Worktree? {
        worktrees.first { $0.isMain && !$0.isBare }
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

    public func lastActivityDate(for worktree: Worktree) -> Date? {
        worktreeActivityDates[worktree.id]
    }

    /// Most recent activity across the repository's live worktrees.
    public var repositoryLastActivityDate: Date? {
        worktreeActivityDates.values.max()
    }

    /// Linked worktrees that still exist on disk, excluding the repository's main
    /// workspace and stale metadata that Git can prune.
    public var linkedWorktreeCount: Int {
        worktrees.count {
            !$0.isMain && $0.isWorkingCopyAvailable
        }
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
            defaultBranch = nil
            dirtyStates = [:]
            worktreeActivityDates = [:]
            // A different repository carries its own fetch cadence; don't let the previous
            // one's timestamp suppress the first auto-fetch here.
            lastAutoFetch = nil
            await reload()
            // Prefer the worktree the user actually pointed at, then the main one.
            let requested = directory.standardizedFileURL.path
            selectedWorktreePath = worktrees.first { requested.hasPrefix($0.id) }?.id
                ?? worktrees.first { !$0.isBare }?.id
        } catch {
            repository = nil
            worktrees = []
            branches = []
            defaultBranch = nil
            dirtyStates = [:]
            worktreeActivityDates = [:]
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

    /// Creates a new folder, runs `git init`, and adds a remote. Does not open the
    /// result: the caller decides whether this window or a new one should take it.
    public func createWorkspace(_ request: NewWorkspaceRequest) async -> URL? {
        rebuildClientIfNeeded()
        let name = request.remoteName.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = request.remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !url.isEmpty else { return nil }

        return await withOperation(label: "Creating workspace…") { [client] in
            try await client.createWorkspace(
                at: request.directory,
                remoteName: name,
                remoteURL: url
            )
        } onFailure: { error in
            PresentableError(title: "Could Not Create Workspace", error: error)
        } thenReturning: {
            preferences.noteWorkspaceParent(request.directory.deletingLastPathComponent())
            return request.directory
        }
    }

    /// Dismisses the offer to create a repository without creating one.
    public func dismissInitializationPrompt() {
        uninitializedDirectory = nil
    }

    public func closeRepository() {
        if let repository {
            preferences.forgetOpen(repository.mainWorktreePath.path)
        }
        repository = nil
        worktrees = []
        branches = []
        defaultBranch = nil
        status = .empty
        history = []
        selectedWorktreePath = nil
        selectedFileKeys = []
        selectedFile = nil
        dirtyStates = [:]
        worktreeActivityDates = [:]
        remotes = []
        stashes = []
        selectedStashID = nil
        stashRecoveryNotices = [:]
        identity = .unknown
        gitHubAuth = .unknown
        pullRequest = nil
        uninitializedDirectory = nil
        lastAutoFetch = nil
    }

    // MARK: - Refresh

    /// Reloads worktrees and branches, then the selected worktree's status.
    public func refresh() {
        startRefresh(presentError: true, retryOnce: false)
    }

    /// Called when GitTrees becomes the active app or this window becomes key, so
    /// Changes pick up edits made in an IDE without a click inside the window.
    ///
    /// Activation fires several notifications at once (`didBecomeActive`,
    /// `didBecomeKey`, and sometimes a view reinstall). Starting a refresh on each
    /// one cancels the previous mid-flight, SIGTERMs git, and used to surface that
    /// as a "Could Not Read Repository" alert. Debouncing coalesces them; a silent
    /// retry covers the first git after a long sleep, when disks and index locks
    /// often fail once and then succeed.
    public func refreshOnWindowActivation() {
        guard repository != nil else { return }
        windowActivationTask?.cancel()
        windowActivationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.startRefresh(presentError: false, retryOnce: true)
            self?.maybeAutoFetch()
        }
    }

    /// Quietly runs `git fetch` on returning to a window, so the "behind upstream" notice
    /// reflects the remote now rather than as of the last manual fetch.
    ///
    /// Deliberately unobtrusive: throttled so focus-thrashing does not hammer the network,
    /// silent on failure (a fetch that needs credentials just fails — the process runs
    /// with `GIT_TERMINAL_PROMPT=0`), and it never surfaces output or an error alert. A
    /// fetch only updates remote-tracking refs; the working tree is untouched.
    private func maybeAutoFetch() {
        guard preferences.autoFetchOnActivation,
              let repository,
              !remotes.isEmpty,
              activeOperation == nil
        else { return }
        if let lastAutoFetch, Date().timeIntervalSince(lastAutoFetch) < Self.autoFetchInterval {
            return
        }
        lastAutoFetch = Date()
        autoFetchTask?.cancel()
        autoFetchTask = Task { [weak self] in
            guard let self else { return }
            _ = try? await self.client.fetch(worktree: repository.commandDirectory, prune: false)
            guard !Task.isCancelled else { return }
            // Re-read so ahead/behind and the notice reflect what the fetch brought in,
            // through the shared refresh task rather than a second bare `reload()` — that
            // supersedes the activation refresh instead of racing it (and its
            // `isRefreshing` flag) with an overlapping reload.
            self.startRefresh(presentError: false, retryOnce: false)
        }
    }

    private func startRefresh(presentError: Bool, retryOnce: Bool) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let firstPresented = presentError && !retryOnce
            let ok = await self.reload(presentError: firstPresented)
            if !ok, retryOnce, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                _ = await self.reload(presentError: true)
            }
            guard !Task.isCancelled else { return }
            self.refreshSelectedWorktree()
        }
    }

    @discardableResult
    private func reload(presentError: Bool = true) async -> Bool {
        rebuildClientIfNeeded()
        guard let repository else { return false }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            // These reads are independent; run them concurrently.
            async let worktreeList = client.worktrees(repository: repository.commandDirectory)
            async let branchList = client.branches(repository: repository.commandDirectory)
            async let remoteList = client.remotes(repository: repository.commandDirectory)
            async let remoteDefault = try? client.defaultBranch(
                repository: repository.commandDirectory, preferredRemote: preferences.preferredRemote(for: repository)
            )
            let (loadedWorktrees, loadedBranches, loadedRemotes, loadedDefault) =
                try await (worktreeList, branchList, remoteList, remoteDefault)

            worktrees = loadedWorktrees
            branches = loadedBranches
            defaultBranch = GraphBranchSelection.defaultBranch(from: loadedBranches, remoteDefault: loadedDefault)
            graphRevision &+= 1
            remotes = loadedRemotes
            // Best-effort: a stash-list failure must not fail the whole reload.
            if let loadedStashes = try? await client.stashes(repository: repository.commandDirectory) {
                stashes = loadedStashes
                let retainedCommits = Set(loadedStashes.map(\.commit))
                stashRecoveryNotices = stashRecoveryNotices.filter { retainedCommits.contains($0.value.stashCommit) }
            } else {
                stashes = []
            }
            if let selectedStashID, !stashes.contains(where: { $0.id == selectedStashID }) {
                self.selectedStashID = nil
            }

            // Keep the selection valid across worktree removals.
            if let selectedWorktreePath, !worktrees.contains(where: { $0.id == selectedWorktreePath }) {
                self.selectedWorktreePath = worktrees.first { !$0.isBare }?.id
            }
            scanWorktreeActivity()
            await refreshIdentity()
            refreshGitHub()
            return true
        } catch is CancellationError {
            return false
        } catch {
            if Task.isCancelled { return false }
            if presentError {
                lastError = PresentableError(title: "Could Not Read Repository", error: error)
            }
            return false
        }
    }

    /// Reads activity in every live worktree concurrently and publishes the results in
    /// one update, so the sidebar's indicators and timestamps do not flicker row by row.
    private func scanWorktreeActivity() {
        dirtyScanTask?.cancel()
        let targets = worktrees.filter(\.isWorkingCopyAvailable)
        let client = self.client
        dirtyScanTask = Task { [weak self] in
            var dirtyResults: [String: Bool] = [:]
            var activityResults: [String: Date] = [:]
            await withTaskGroup(of: (String, WorktreeActivity)?.self) { group in
                for worktree in targets {
                    group.addTask {
                        guard let activity = try? await client.worktreeActivity(worktree: worktree.path) else {
                            return nil
                        }
                        return (worktree.id, activity)
                    }
                }
                for await result in group {
                    guard let result else { continue }
                    dirtyResults[result.0] = result.1.isDirty
                    activityResults[result.0] = result.1.lastActivityAt
                }
            }
            guard !Task.isCancelled else { return }
            self?.dirtyStates = dirtyResults
            self?.worktreeActivityDates = activityResults
        }
    }

    /// Reloads status and history for the selected worktree.
    public func refreshSelectedWorktree() {
        statusTask?.cancel()
        guard let worktree = selectedWorktree, worktree.isWorkingCopyAvailable else {
            clearSelectedWorkingCopyState()
            return
        }
        let logRevisions = historyRevisions(for: worktree)
        statusTask = Task { [weak self] in
            guard let self else { return }
            do {
                async let statusResult = self.client.statusSummary(worktree: worktree.path)
                async let logResult = self.client.log(worktree: worktree.path, limit: 200, revisions: logRevisions)
                // Asked on every refresh, not only when conflicts exist. A rebase whose
                // conflicts have just been resolved is still in progress — and that is
                // exactly the moment the UI has to offer Continue, so inferring `.none`
                // from "no conflicts" would hide the only way to finish it. Runs
                // concurrently with the other two, so it costs no extra wall time.
                async let operationResult = try? self.client.inProgressOperation(worktree: worktree.path)
                let (loadedStatus, loadedHistory) = try await (statusResult, logResult)
                let operation = await operationResult ?? .none
                guard !Task.isCancelled, self.selectedWorktreePath == worktree.id else { return }
                guard self.selectedWorktree?.isWorkingCopyAvailable == true else {
                    self.clearSelectedWorkingCopyState()
                    return
                }
                self.status = loadedStatus
                self.history = loadedHistory
                self.mergeOperation = operation
                self.reconcileSelectedFile()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.selectedWorktreePath == worktree.id else { return }
                // A checkout can disappear while Git is reading it. The detail pane
                // explains unavailable worktrees; activation must not reopen an alert.
                guard self.selectedWorktree?.isWorkingCopyAvailable == true else {
                    self.clearSelectedWorkingCopyState()
                    return
                }
                self.lastError = PresentableError(title: "Could Not Read Status", error: error)
            }
        }
    }

    private func clearSelectedWorkingCopyState() {
        status = .empty
        history = []
        mergeOperation = .none
        selectedFileKeys = []
        selectedFile = nil
    }

    /// The `git log` revision arguments for the History panel: empty for the full history
    /// behind the branch tip, or `["<base>..HEAD"]` when limited to the current branch.
    ///
    /// Returns empty (full history) when the toggle is off or no base branch can be
    /// resolved — better to show everything than to silently show nothing.
    private func historyRevisions(for worktree: Worktree) -> [String] {
        guard preferences.historyCurrentBranchOnly,
              let base = historyBaseRef(for: worktree)
        else { return [] }
        return ["\(base)..HEAD"]
    }

    /// The default branch to measure "this branch's commits" against — a local
    /// `main`/`master`/`develop`, else the remote's equivalent. Nil when none exists, so
    /// the filter falls back to full history rather than an empty list.
    private func historyBaseRef(for worktree: Worktree) -> String? {
        let localNames = Set(localBranches.map(\.name))
        for name in ["main", "master", "develop"] where localNames.contains(name) {
            return name
        }
        let remoteNames = Set(remoteBranches.map(\.name))
        for name in ["origin/main", "origin/master", "origin/develop"] where remoteNames.contains(name) {
            return name
        }
        return nil
    }

    /// Carries the selection across a refresh: rows that are still there stay selected,
    /// a file that only moved between the staged and unstaged sections is followed, and a
    /// path with no changes left drops out.
    private func reconcileSelectedFile() {
        selectedFileKeys = Set(selectedFileKeys.compactMap(status.survivingSelectionKey(for:)))
        focusSelectedFile(resettingSide: false)
    }

    /// Points the diff pane at the selection, which it can only do when the selection is
    /// a single row.
    ///
    /// `resettingSide` follows the row the user just clicked to its own side of the
    /// index. A refresh passes false so that flipping the diff's Working Tree/Staged
    /// picker is not undone the next time status is read.
    public func focusSelectedFile(resettingSide: Bool) {
        guard selectedFileKeys.count == 1,
              let key = selectedFileKeys.first,
              let selection = WorktreeStatus.selection(fromKey: key),
              let change = status.change(forSelectionKey: key)
        else {
            selectedFile = nil
            return
        }
        selectedFile = change
        if resettingSide {
            showingStagedDiff = selection.staged
        } else if showingStagedDiff, !change.hasStagedChanges {
            showingStagedDiff = false
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
                  let worktree, worktree.isWorkingCopyAvailable else {
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

    private var pullRequestDirectory: URL? {
        if let worktree = selectedWorktree, worktree.isWorkingCopyAvailable {
            return worktree.path
        }
        return repository?.commandDirectory
    }

    public func loadPullRequest(_ reference: String) async -> PullRequest? {
        guard let directory = pullRequestDirectory, gitHubAuth.isReady, activeOperation == nil else { return nil }
        return await withOperation(label: "Loading pull request…") { [gitHubClient] in
            try await gitHubClient.pullRequest(reference, directory: directory)
        } onFailure: { error in
            PresentableError(title: "Could Not Load Pull Request", error: error)
        } thenReturning: { $0 }
    }

    public func openPullRequests(limit: Int) async throws -> [PullRequest] {
        guard let repository else { return [] }
        return try await gitHubClient.openPullRequests(directory: repository.commandDirectory, limit: limit)
    }

    public func pullRequestChanges(_ request: PullRequest) async throws -> PullRequestChanges {
        try await gitHubClient.pullRequestChanges(request, directory: signedInPullRequestDirectory())
    }

    public func pullRequestChecks(_ request: PullRequest) async throws -> [PullRequestCheck] {
        try await gitHubClient.pullRequestChecks(request, directory: signedInPullRequestDirectory())
    }

    public func pullRequestCheckDetails(_ check: PullRequestCheck, request: PullRequest) async throws -> PullRequestCheckDetails {
        try await gitHubClient.pullRequestCheckDetails(check, request: request, directory: signedInPullRequestDirectory())
    }

    public func pullRequestCheckLog(_ check: PullRequestCheck, request: PullRequest, failedOnly: Bool) async throws -> String {
        try await gitHubClient.pullRequestCheckLog(
            check, request: request, failedOnly: failedOnly, directory: signedInPullRequestDirectory()
        )
    }

    private func signedInPullRequestDirectory() throws -> URL {
        guard let directory = pullRequestDirectory, gitHubAuth.isReady else {
            throw GitHubError.notAuthenticated
        }
        return directory
    }

    public func performPullRequestAction(
        _ action: PullRequestAction, on pr: PullRequest
    ) async -> (pullRequest: PullRequest?, message: String)? {
        guard let directory = pullRequestDirectory, gitHubAuth.isReady, activeOperation == nil else { return nil }
        let label: String
        let errorTitle: String
        switch action {
        case .approve:
            label = "Approving pull request…"
            errorTitle = "Could Not Approve Pull Request"
        case .merge:
            label = "Merging pull request…"
            errorTitle = "Could Not Merge Pull Request"
        }

        return await withOperation(label: label, worktree: selectedWorktree) { [gitHubClient] in
            let result = try await gitHubClient.perform(action, on: pr, directory: directory)
            // The write succeeded even if reading the updated PR fails.
            let updated = try? await gitHubClient.pullRequest(pr.url, directory: directory)
            return (result, updated)
        } onFailure: { error in
            PresentableError(title: errorTitle, error: error)
        } thenReturning: { result, updated in
            if let updated, self.pullRequest?.url == pr.url {
                self.gitHubTask?.cancel()
                self.pullRequest = updated
            }
            let message: String
            switch action {
            case .approve:
                message = "Approved pull request #\(pr.number)."
            case .merge:
                let output = [result.stdoutText, result.stderrText]
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if updated?.isMerged == true {
                    message = "Merged pull request #\(pr.number)."
                } else {
                    message = output.isEmpty ? "GitHub accepted the merge request." : output
                }
            }
            self.lastOperationOutput = "\(message)\n\(pr.url)"
            return (updated, message)
        }
    }

    /// Opens the displayed PR, or the selected worktree's branch PR by default.
    public func openPullRequestInBrowser(_ pr: PullRequest? = nil) async {
        guard let directory = pullRequestDirectory, activeOperation == nil else { return }
        _ = await withOperation(label: "Opening browser…", worktree: selectedWorktree) { [gitHubClient] in
            try await gitHubClient.openPullRequestInBrowser(worktree: directory, reference: pr?.url)
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
        guard selectedWorktree == nil || selectedWorktree?.isWorkingCopyAvailable == true else {
            identity = .unknown
            return
        }
        let selectedPath = selectedWorktreePath
        let directory = selectedWorktree.map(\.path) ?? repository.commandDirectory
        let loadedIdentity = (try? await client.identity(directory: directory)) ?? .unknown
        guard self.repository?.id == repository.id, selectedWorktreePath == selectedPath else { return }
        identity = selectedWorktree == nil || selectedWorktree?.isWorkingCopyAvailable == true
            ? loadedIdentity : .unknown
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

    /// Defaults for creating a worktree from a selected branch. Remote branches need
    /// a local tracking branch; never reuse a local name that may point elsewhere.
    public func suggestedWorktreeMode(for branch: Branch) -> NewWorktreeRequest.Mode {
        guard branch.kind == .remote,
              let localName = Self.localName(forRemoteBranch: branch.refName) else {
            return worktree(for: branch) == nil
                ? .existingBranch(branch.name)
                : .newBranch(name: "", startPoint: branch.name)
        }

        let names = localBranches.map(\.name)
        func conflicts(_ candidate: String) -> Bool {
            names.contains {
                $0 == candidate || $0.hasPrefix(candidate + "/") || candidate.hasPrefix($0 + "/")
            }
        }
        var name = localName
        if conflicts(name) {
            // Flatten only when an existing parent ref prevents a nested branch.
            let base = names.contains(where: { localName.hasPrefix($0 + "/") })
                ? localName.replacingOccurrences(of: "/", with: "-") : localName
            name = base + "-worktree"
            var suffix = 2
            while conflicts(name) {
                name = base + "-worktree-\(suffix)"
                suffix += 1
            }
        }
        return .newBranch(name: name, startPoint: branch.refName)
    }

    public func createWorktree(_ request: NewWorktreeRequest) async -> Worktree? {
        guard repository != nil else { return nil }
        let created = await addWorktree(request)
        // Only once the worktree is really there: an ignore rule for a worktree root that
        // was never created would be a leftover the user did not ask for.
        if created != nil, let rule = request.ignoreRule {
            await addIgnoreRule(pattern: rule, destination: .local)
        }
        return created
    }

    private func addWorktree(_ request: NewWorktreeRequest) async -> Worktree? {
        guard let repository else { return nil }

        if request.uncommittedChanges != .leave, let source = selectedWorktree {
            return await createWorktree(request, transferringChangesFrom: source)
        }

        // `withOperation` wraps a failure as nil, so the nested optional here is
        // "operation failed" outside and "worktree not found afterwards" inside.
        let created: Worktree?? = await withOperation(label: "Creating worktree…") { [client] in
            try await Self.addWorktree(request, in: repository, using: client)
        } onFailure: { error in
            PresentableError(title: "Could Not Create Worktree", error: error)
        } thenReturning: { [weak self] () -> Worktree? in
            await self?.reload()
            let worktree = self?.worktree(at: request.path)
            if let worktree { self?.selectedWorktreePath = worktree.id }
            return worktree
        }
        return created ?? nil
    }

    /// Finds the worktree created for `path` in the refreshed list.
    ///
    /// `git worktree list` reports the path as it resolves on disk, which can differ from
    /// the one the request carried once a parent directory is a symlink (`/var` ->
    /// `/private/var`, a home under a linked volume). A plain `standardizedFileURL` match
    /// does not resolve symlinks, so it would miss the row for a worktree that was in fact
    /// created — and the caller, reading that nil as failure, would leave its dialog open
    /// with a stale "already exists" warning. Resolving both sides makes the match hold.
    private func worktree(at path: URL) -> Worktree? {
        // Compare as normalized path strings, not URL equality: `==` on file URLs also
        // weighs the trailing-slash/`isDirectory` hint and any base URL, so two URLs for
        // the very same directory can compare unequal. `.path` after resolving symlinks and
        // standardizing collapses all of that to one canonical string.
        func key(_ url: URL) -> String {
            url.resolvingSymlinksInPath().standardizedFileURL.path
        }
        let target = key(path)
        return worktrees.first { key($0.path) == target }
    }

    /// Creates the worktree and carries `source`'s uncommitted work into it.
    ///
    /// The transfer goes through the stash rather than a patch file, because the stash is
    /// the one mechanism that reproduces the whole working state — staged and unstaged
    /// changes kept apart, untracked files included — and it is a real commit in the
    /// repository, so nothing lives in a temporary file that a crash could strand.
    ///
    /// The sequence is: stash in the source, create the worktree, apply in the new
    /// worktree, and only then drop the stash entry. Every failure path either puts the
    /// changes back or reports which stash still holds them; none of them drops it.
    private func createWorktree(
        _ request: NewWorktreeRequest,
        transferringChangesFrom source: Worktree
    ) async -> Worktree? {
        guard let repository else { return nil }
        guard claim(source) else {
            lastError = PresentableError(
                title: "Operation In Progress",
                message: "Another operation is already running in \(source.path.path)."
            )
            return nil
        }
        defer { release(source) }

        let label = request.uncommittedChanges == .copy
            ? "Copying changes to new worktree…"
            : "Moving changes to new worktree…"
        let keepInSource = request.uncommittedChanges == .copy

        let created: Worktree?? = await withOperation(label: label, worktree: source) { [client] in
            let repositoryDirectory = repository.commandDirectory

            guard let stash = try await client.stashPush(
                worktree: source.path,
                message: "GitTrees: \(request.checkoutName)"
            ) else {
                throw GitError.noLocalChanges(path: source.path.path)
            }

            // From here the changes exist only in the stash, so every exit restores them
            // or names the stash that still has them.
            var resolved = request
            if case .newBranch(let name, let startPoint) = request.mode, startPoint.isEmpty {
                // `HEAD` would resolve in the repository's main worktree, not this one, so
                // a detached source worktree has to name its commit outright.
                let head = try await client.headCommit(worktree: source.path)
                resolved.mode = .newBranch(name: name, startPoint: head ?? "")
            }

            do {
                try await Self.addWorktree(resolved, in: repository, using: client)
            } catch {
                try await client.stashApply(worktree: source.path, stash: stash, restoringIndex: true)
                try await Self.dropStash(stash, in: repositoryDirectory, using: client)
                throw error
            }

            do {
                try await client.stashApply(worktree: request.path, stash: stash, restoringIndex: true)
            } catch {
                // `--index` is refused in cases Git cannot represent. Retrying without it
                // is only safe while the failed attempt has left the worktree untouched.
                guard try await client.isDirty(worktree: request.path) == false else {
                    throw GitError.changesLeftInStash(
                        stash: stash,
                        reason: "The worktree was created, but the changes could not be applied to it."
                    )
                }
                do {
                    try await client.stashApply(worktree: request.path, stash: stash, restoringIndex: false)
                } catch {
                    throw GitError.changesLeftInStash(
                        stash: stash,
                        reason: "The worktree was created, but the changes could not be applied to it."
                    )
                }
            }

            if keepInSource {
                do {
                    try await client.stashApply(worktree: source.path, stash: stash, restoringIndex: true)
                } catch {
                    throw GitError.changesLeftInStash(
                        stash: stash,
                        reason: "The changes are in the new worktree, but could not be put back in \(source.path.lastPathComponent)."
                    )
                }
            }

            try await Self.dropStash(stash, in: repositoryDirectory, using: client)
        } onFailure: { error in
            PresentableError(title: "Could Not Move Changes", error: error)
        } thenReturning: { [weak self] () -> Worktree? in
            await self?.reload()
            let worktree = self?.worktree(at: request.path)
            if let worktree { self?.selectedWorktreePath = worktree.id }
            return worktree
        }
        return created ?? nil
    }

    /// Runs the `git worktree add` a request describes.
    ///
    /// Shared by the plain creation path and the one that carries changes across, so the
    /// two cannot drift apart in how a request is turned into a worktree.
    private nonisolated static func addWorktree(
        _ request: NewWorktreeRequest,
        in repository: Repository,
        using client: GitClient
    ) async throws {
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
        case .detachedCommit(let hash):
            try await client.createDetachedWorktree(
                repository: repository.commandDirectory,
                path: request.path,
                at: hash
            )
        }
    }

    /// Removes a stash entry once its contents are safely somewhere else.
    ///
    /// A stash that has already gone is not an error: the entry is only ever dropped
    /// after the changes have landed, so the outcome the caller wanted already holds.
    private nonisolated static func dropStash(
        _ stash: String,
        in repositoryDirectory: URL,
        using client: GitClient
    ) async throws {
        guard let selector = try await client.stashSelector(
            repository: repositoryDirectory,
            forCommit: stash
        ) else { return }
        try await client.stashDrop(repository: repositoryDirectory, selector: selector)
    }

    /// Reads the worktree's status so the caller can warn before a destructive removal.
    public func changesBlockingRemoval(of worktree: Worktree) async -> WorktreeStatus? {
        guard worktree.isWorkingCopyAvailable else { return nil }
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

    /// A reason to disable local branch deletion, also checked when confirming it.
    public func branchDeletionBlocker(_ branch: Branch) -> String? {
        guard branch.kind == .local else { return "Only local branches can be deleted here." }
        if let path = worktree(for: branch)?.path ?? branch.worktreePath {
            return "Checked out in \(path.path). Switch that worktree to another branch or remove the worktree first."
        }
        if branch.isCurrentHEAD { return "Switch to another branch before deleting this branch." }
        return nil
    }

    @discardableResult
    public func deleteBranch(_ branch: Branch, force: Bool = false) async -> Bool {
        guard let repository, activeOperation == nil else { return false }
        guard let current = branches.first(where: { $0.refName == branch.refName }),
              current.objectName == branch.objectName else {
            lastError = PresentableError(title: "Branch Has Changed", message: "Refresh the branch list and try again.")
            return false
        }
        if let reason = branchDeletionBlocker(current) {
            lastError = PresentableError(title: "Cannot Delete Branch", message: reason)
            return false
        }
        return await withOperation(label: "Deleting \(branch.name)…") { [client] in
            try await client.deleteBranch(repository: repository.commandDirectory, name: branch.name, force: force)
        } onFailure: { error in
            PresentableError(title: "Could Not Delete Branch", error: error)
        } thenReturning: { [weak self] in
            await self?.reload()
            return true
        } ?? false
    }

    /// Creates a branch at a historical commit while preserving every checkout.
    @discardableResult
    public func createBranch(name: String, at commit: CommitSummary) async -> Bool {
        guard let repository, activeOperation == nil else { return false }
        return await withOperation(label: "Creating branch…") { [client] in
            try await client.createBranch(repository: repository.commandDirectory, name: name, at: commit.hash)
        } onFailure: { error in
            PresentableError(title: "Could Not Create Branch", error: error)
        } thenReturning: { [weak self] in
            await self?.reload()
            self?.refreshSelectedWorktree()
            return true
        } ?? false
    }

    /// Creates a local tag at a historical commit and refreshes its history badge.
    @discardableResult
    public func createTag(name: String, at commit: CommitSummary, message: String = "") async -> Bool {
        guard let repository, activeOperation == nil else { return false }
        return await withOperation(label: "Creating tag…") { [client] in
            try await client.createTag(repository: repository.commandDirectory, name: name,
                                       at: commit.hash, message: message)
        } onFailure: { error in
            PresentableError(title: "Could Not Create Tag", error: error)
        } thenReturning: { [weak self] in
            await self?.reload()
            self?.refreshSelectedWorktree()
            return true
        } ?? false
    }

    /// Checks a branch out in an existing worktree.
    ///
    /// Git's own rule — a branch may be checked out in only one worktree — is left to
    /// Git; a refusal surfaces as an ordinary error.
    public func checkout(branch: Branch, in worktree: Worktree) async {
        guard claim(worktree) else { return }
        defer { release(worktree) }

        let trackingLocalName = branch.kind == .remote
            ? Self.localName(forRemoteBranch: branch.refName)
            : nil
        let existingLocalBranch = trackingLocalName.flatMap { name in
            localBranches.first(where: { $0.name == name })
        }

        _ = await withOperation(label: "Checking out \(branch.name)…", worktree: worktree) { [client] in
            if let trackingLocalName {
                if let existingLocalBranch {
                    try await client.checkout(worktree: worktree.path, branch: existingLocalBranch.name)
                } else {
                    try await client.checkoutTrackingBranch(
                        worktree: worktree.path,
                        localBranch: trackingLocalName,
                        remoteRef: branch.refName
                    )
                }
            } else {
                try await client.checkout(worktree: worktree.path, branch: branch.name)
            }
        } onFailure: { error in
            PresentableError(title: "Could Not Check Out Branch", error: error)
        } thenReturning: { [weak self] in
            await self?.reload()
            // Show the worktree that just changed, including when the user started
            // from a branch that had no worktree.
            self?.selectedWorktreePath = worktree.id
            self?.refreshSelectedWorktree()
        }
    }

    /// `refs/remotes/origin/feature/x` maps to the conventional local name
    /// `feature/x`. A malformed or non-remote ref returns nil and keeps the existing
    /// checkout path as a fallback.
    private nonisolated static func localName(forRemoteBranch refName: String) -> String? {
        guard refName.hasPrefix(RefName.remotePrefix) else { return nil }
        let components = refName.dropFirst(RefName.remotePrefix.count).split(separator: "/")
        guard components.count >= 2 else { return nil }
        return components.dropFirst().joined(separator: "/")
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

    // MARK: - Conflict resolution

    public func assessBranches(worktree: Worktree, otherRef: String) async throws -> BranchAssessment {
        try await client.assessBranches(worktree: worktree.path, otherRef: otherRef)
    }

    public func fetchForAssist(worktree: Worktree, branch: Branch) async throws {
        guard selectedWorktree?.id == worktree.id,
              let remote = remotes.filter({ branch.name.hasPrefix($0.name + "/") })
                .max(by: { $0.name.count < $1.name.count }) else {
            throw GitAssistError.unsupported("The remote for this branch is unavailable. Refresh the repository and try again.")
        }
        guard claim(worktree) else { throw GitError.operationInProgress(path: worktree.id) }
        defer { release(worktree) }
        lastOperationOutput = try await client.fetch(worktree: worktree.path, remote: remote.name)
        await reload()
        refreshSelectedWorktree()
    }

    public func fastForward(_ assessment: BranchAssessment) async throws {
        guard let worktree = selectedWorktree, worktree.path == assessment.worktree,
              worktree.branchRef == assessment.currentRef else { throw GitAssistError.stale }
        guard claim(worktree) else { throw GitError.operationInProgress(path: worktree.id) }
        defer { release(worktree); refreshSelectedWorktree() }
        lastOperationOutput = try await client.fastForward(assessment)
        await reload()
    }

    public func suggestConflictResolution(worktree: Worktree, path: String) async throws -> ConflictProposal {
        let snapshot = try await client.conflictSnapshot(worktree: worktree.path, path: path)
        let suggestion = try await AppleIntelligenceGitAssistant.suggest(snapshot)
        try Task.checkCancellation()
        return try await client.conflictProposal(snapshot: snapshot, replacements: suggestion.replacements,
                                                explanation: suggestion.explanation)
    }

    public func applyConflictProposal(_ proposal: ConflictProposal) async throws {
        guard let worktree = selectedWorktree, worktree.path == proposal.snapshot.worktree else {
            throw GitAssistError.stale
        }
        guard claim(worktree) else { throw GitError.operationInProgress(path: worktree.id) }
        defer { release(worktree); refreshSelectedWorktree() }
        try await client.applyConflictProposal(proposal)
    }

    /// Which working copy to keep for a conflicted file, in the user's terms rather than
    /// Git's stage numbers.
    public enum ConflictChoice: Sendable {
        /// This branch's own work.
        case mine
        /// The incoming side being merged, rebased, or applied.
        case theirs
    }

    /// Resolves conflicted files by taking one whole side, in one operation and refresh.
    ///
    /// "Mine"/"theirs" is mapped to Git's ours/theirs per the operation in progress: a
    /// merge (and a stash apply) keeps mine = ours, but a rebase replays your commits as
    /// *theirs*, so the two are swapped there — this keeps "Mine" meaning your work in
    /// both.
    public func resolveConflicts(_ changes: [FileChange], keeping choice: ConflictChoice) async {
        guard let worktree = selectedWorktree else { return }
        let conflicted = changes.filter(\.isConflicted)
        guard !conflicted.isEmpty else { return }
        let paths = conflicted.map(\.path)

        _ = await withOperation(label: "Resolving…", worktree: worktree) { [client] in
            let operation = try await client.inProgressOperation(worktree: worktree.path)
            let side: GitClient.ConflictSide
            switch (choice, operation) {
            case (.mine, .rebase): side = .theirs
            case (.mine, _): side = .ours
            case (.theirs, .rebase): side = .ours
            case (.theirs, _): side = .theirs
            }
            for path in paths {
                try await client.resolveConflict(worktree: worktree.path, path: path, keeping: side)
            }
        } onFailure: { error in
            PresentableError(title: "Could Not Resolve Conflict", error: error)
        } thenReturning: { [weak self] in
            self?.refreshSelectedWorktree()
        }
    }

    /// Resolves conflicted files by discarding both sides and restoring the branch's
    /// committed version (`HEAD`).
    public func discardConflicts(_ changes: [FileChange]) async {
        guard let worktree = selectedWorktree else { return }
        let paths = changes.filter(\.isConflicted).map(\.path)
        guard !paths.isEmpty else { return }

        _ = await withOperation(label: "Restoring…", worktree: worktree) { [client] in
            for path in paths {
                try await client.discardConflict(worktree: worktree.path, path: path)
            }
        } onFailure: { error in
            PresentableError(title: "Could Not Restore File", error: error)
        } thenReturning: { [weak self] in
            self?.refreshSelectedWorktree()
        }
    }

    /// Aborts the in-progress merge or rebase, returning the worktree to the branch as it
    /// was before it began. Only meaningful while `mergeOperation` is not `.none`.
    public func abortMerge() async {
        guard let worktree = selectedWorktree else { return }
        _ = await withOperation(label: "Aborting…", worktree: worktree) { [client] in
            let operation = try await client.inProgressOperation(worktree: worktree.path)
            guard operation != .none else {
                throw GitError.unexpectedOutput(
                    reason: "there is no merge or rebase in progress to abort",
                    arguments: ["merge", "--abort"]
                )
            }
            try await client.abortInProgressOperation(worktree: worktree.path, operation: operation)
        } onFailure: { error in
            PresentableError(title: "Could Not Abort", error: error)
        } thenReturning: { [weak self] in
            await self?.reload()
            self?.refreshSelectedWorktree()
        }
    }

    /// True while a rebase is stopped on a step whose conflicts are all resolved — the
    /// only moment `Continue Rebase` means anything.
    public var canContinueRebase: Bool {
        mergeOperation == .rebase && status.conflicts.isEmpty
    }

    /// Finishes the rebase step whose conflicts have been resolved.
    ///
    /// A merge is completed by committing, so the Commit box already covers it. A rebase
    /// is not: without this, a fully resolved rebase could only be thrown away.
    public func continueRebase() async {
        await advanceRebase(argument: "--continue", label: "Continuing rebase…") { [client] worktree in
            try await client.continueRebase(worktree: worktree.path)
        }
    }

    /// Drops the commit being replayed and moves the rebase on to the next one.
    public func skipRebaseCommit() async {
        await advanceRebase(argument: "--skip", label: "Skipping commit…") { [client] worktree in
            try await client.skipRebaseCommit(worktree: worktree.path)
        }
    }

    private func advanceRebase(
        argument: String,
        label: String,
        _ body: @escaping @Sendable (Worktree) async throws -> String
    ) async {
        guard let worktree = selectedWorktree else { return }
        let output = await withOperation(label: label, worktree: worktree) {
            let operation = try await self.client.inProgressOperation(worktree: worktree.path)
            guard operation == .rebase else {
                throw GitError.unexpectedOutput(
                    reason: "there is no rebase in progress",
                    arguments: ["rebase", argument]
                )
            }
            return try await body(worktree)
        } onFailure: { error in
            PresentableError(title: "Could Not Continue the Rebase", error: error)
        } thenReturning: { [weak self] (output: String) -> String in
            await self?.reload()
            self?.refreshSelectedWorktree()
            return output
        }
        if let output {
            lastOperationOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Throws away local changes to `changes`, returning each file to its committed state.
    ///
    /// Destructive and not recoverable through Git — a file that was never committed is
    /// simply gone — so callers confirm first.
    public func discardChanges(_ changes: [FileChange]) async {
        guard let worktree = selectedWorktree else { return }
        let paths = changes.map(\.path)
        guard !paths.isEmpty else { return }
        _ = await withOperation(label: "Discarding changes…", worktree: worktree) { [client] in
            try await client.discardChanges(worktree: worktree.path, paths: paths)
        } onFailure: { error in
            PresentableError(title: "Could Not Discard Changes", error: error)
        } thenReturning: { [weak self] in
            await self?.reload()
            self?.refreshSelectedWorktree()
        }
    }

    /// True when there is a commit to undo. Before the first commit there is not.
    public var canUndoLastCommit: Bool {
        selectedWorktree != nil && mergeOperation == .none && !history.isEmpty
    }

    /// Undoes the last commit, keeping everything it contained staged so it can be
    /// corrected and committed again. Nothing is lost.
    public func undoLastCommit() async {
        guard let worktree = selectedWorktree else { return }
        _ = await withOperation(label: "Undoing last commit…", worktree: worktree) { [client] in
            try await client.undoLastCommit(worktree: worktree.path)
        } onFailure: { error in
            PresentableError(title: "Could Not Undo the Last Commit", error: error)
        } thenReturning: { [weak self] in
            await self?.reload()
            self?.refreshSelectedWorktree()
        }
    }

    // MARK: - Ignore rules

    /// The file a destination resolves to, for the sheet to show and write to.
    ///
    /// Only `.repository` needs a worktree — it is that worktree's own `.gitignore`.
    /// `.local` lives in the shared git directory, so it can be resolved before any
    /// worktree is selected.
    public func ignoreFile(for destination: Gitignore.Destination) -> URL? {
        guard let repository else { return nil }
        switch destination {
        case .local:
            return Gitignore.fileURL(
                for: .local,
                worktree: repository.mainWorktreePath,
                commonGitDir: repository.commonGitDir
            )
        case .repository:
            guard let worktree = selectedWorktree else { return nil }
            return Gitignore.fileURL(
                for: .repository,
                worktree: worktree.path,
                commonGitDir: repository.commonGitDir
            )
        }
    }

    /// True when the rule is already on a line of its own in that destination's file.
    public func hasIgnoreRule(pattern: String, destination: Gitignore.Destination) -> Bool {
        guard let file = ignoreFile(for: destination) else { return false }
        return Gitignore.contains(pattern: pattern, in: file)
    }

    /// Captures the invariant half of an ignore preview — the untracked walk and the
    /// global excludes — so a sheet can reuse it across every pattern the user tries.
    /// Nil when there is no worktree or the walk fails; the caller falls back to the
    /// per-pattern path, which recomputes it.
    public func ignorePreviewBaseline() async -> GitClient.IgnorePreviewBaseline? {
        guard let worktree = selectedWorktree else { return nil }
        return try? await client.ignorePreviewBaseline(worktree: worktree.path)
    }

    /// The untracked paths `pattern` would hide, so a rule can be checked before it is
    /// written. Returns an empty list rather than an error: this drives a preview, and a
    /// half-typed custom pattern must not raise an alert.
    ///
    /// Pass a `baseline` from `ignorePreviewBaseline()` to skip the untracked walk that
    /// is the same for every pattern; without one the walk is redone each call.
    public func previewIgnore(
        pattern: String,
        baseline: GitClient.IgnorePreviewBaseline? = nil
    ) async -> [String] {
        if let baseline {
            return (try? await client.pathsHidden(byIgnorePattern: pattern, baseline: baseline)) ?? []
        }
        guard let worktree = selectedWorktree else { return [] }
        return (try? await client.pathsHidden(byIgnorePattern: pattern, worktree: worktree.path)) ?? []
    }

    /// Appends one rule to the chosen ignore file so the paths it matches drop out of
    /// Changes. A `.gitignore` edit is left unstaged for the user to commit; nothing is
    /// written to `info/exclude` that Git would ever try to commit.
    @discardableResult
    public func addIgnoreRule(
        pattern: String,
        destination: Gitignore.Destination
    ) async -> Bool {
        await addIgnoreRules(patterns: [pattern], destination: destination)
    }

    /// Appends several rules under one operation and one refresh.
    ///
    /// The write is not all-or-nothing: a rule that fails leaves the ones before it in
    /// the file, which is the same state a partial hand edit would leave and is visible
    /// in the file itself.
    @discardableResult
    public func addIgnoreRules(
        patterns: [String],
        destination: Gitignore.Destination
    ) async -> Bool {
        let wanted = patterns
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let file = ignoreFile(for: destination), !wanted.isEmpty else { return false }

        let added = await withOperation(
            label: "Updating \(destination.displayName)…",
            worktree: selectedWorktree
        ) {
            var added = false
            for pattern in wanted {
                added = try Gitignore.append(pattern: pattern, to: file) || added
            }
            return added
        } onFailure: { error in
            PresentableError(title: "Could Not Update \(destination.displayName)", error: error)
        } thenReturning: { [weak self] (added: Bool) -> Bool in
            self?.refreshSelectedWorktree()
            return added
        }
        return added ?? false
    }

    /// Appends one rule per path to this worktree's `.gitignore`, in one operation so a
    /// multiple selection is a single edit rather than one refresh per file.
    public func ignore(_ changes: [FileChange]) async {
        let patterns = changes.map { Gitignore.pattern(forPath: $0.path) }
        await addIgnoreRules(patterns: patterns, destination: .repository)
    }

    /// Appends the untracked path to this worktree's `.gitignore`.
    public func ignore(_ change: FileChange) async {
        await ignore([change])
    }

    /// Appends a directory pattern (`/path/`) to `.gitignore`.
    public func ignoreDirectory(of change: FileChange) async {
        let directory = change.directory
        guard !directory.isEmpty else { return }
        await addIgnoreRule(
            pattern: Gitignore.pattern(forDirectory: directory),
            destination: .repository
        )
    }

    // MARK: - Diff

    /// Unified diff of the current index, for the commit-subject drafter.
    public func stagedDiff() async throws -> String {
        guard let worktree = selectedWorktree else { return "" }
        return try await client.stagedDiff(worktree: worktree.path)
    }

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

    /// Identity, message and files for one commit, including repository-wide Graph.
    public func commitDetail(hash: String) async throws -> CommitDetail {
        guard let directory = selectedWorktree?.path ?? repository?.commandDirectory else {
            throw GitError.unexpectedOutput(
                reason: "no repository is open",
                arguments: ["log", "-1"]
            )
        }
        return try await client.commitDetail(worktree: directory, hash: hash)
    }

    /// Unified diff of one path as introduced by `hash`.
    public func commitDiff(hash: String, path: String) async throws -> String {
        guard let directory = selectedWorktree?.path ?? repository?.commandDirectory else { return "" }
        return try await client.commitDiff(
            worktree: directory,
            hash: hash,
            path: path,
            contextLines: preferences.diffContextLines
        )
    }

    public func graph(branches: [Branch], limit: Int = 500) async throws -> CommitGraph {
        guard let repository else { return CommitGraph() }
        rebuildClientIfNeeded()
        return try await client.graph(repository: repository.commandDirectory, branches: branches, limit: limit,
                                      knownBranches: self.branches)
    }

    // MARK: - Commit

    /// Commits the index. Hooks and commit configuration are left untouched.
    @discardableResult
    /// `amend` rewrites the previous commit instead of adding one — for a wrong message or
    /// a file left out. It rewrites history, so an already-pushed branch then needs a
    /// force-push (`push(forceWithLease:)`).
    public func commit(message: String, amend: Bool = false) async -> Bool {
        guard let worktree = selectedWorktree else { return false }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let output = await withOperation(
            label: amend ? "Amending…" : "Committing…",
            worktree: worktree
        ) { [client] in
            try await client.commit(worktree: worktree.path, message: trimmed, amend: amend)
        } onFailure: { error in
            PresentableError(title: amend ? "Amend Failed" : "Commit Failed", error: error)
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

    /// How the selected worktree should pull: which remote/branch to name, and whether to
    /// set an upstream first. Sendable so it can cross into the off-main operation body.
    private struct PullPlan: Sendable {
        var remote: String?
        var branch: String?
        /// A ref to set as the branch's upstream before pulling, for a branch that has none.
        var setUpstreamTo: String?
    }

    /// Works out how to pull the selected worktree, or sets `lastError` and returns nil
    /// explaining why it cannot.
    ///
    /// A branch with an upstream pulls normally. A branch without one, whose name matches
    /// a branch on the resolved remote, gets that ref set as its upstream and then pulls —
    /// turning the two-step "set upstream, then pull" into one action. A branch with no
    /// upstream and no matching remote branch has nothing to pull from, and says so
    /// instead of letting Git emit its raw "no tracking information" error.
    private func pullPlan() -> PullPlan? {
        guard let worktree = selectedWorktree else {
            lastError = PresentableError(title: "Pull Failed", message: "No worktree is selected.")
            return nil
        }
        if !selectedBranchNeedsUpstream {
            return PullPlan(remote: selectedRemote, branch: nil, setUpstreamTo: nil)
        }
        guard let branchName = worktree.branchName else {
            lastError = PresentableError(
                title: "Pull Failed",
                message: "This worktree has a detached HEAD, so there is no branch to pull into."
            )
            return nil
        }
        guard let remote = remoteForPublishing else {
            lastError = PresentableError(
                title: "Pull Failed",
                message: "\(branchName) has no upstream and the repository has no remotes to pull from.",
                detail: "Add a remote with git remote add, then push or pull again."
            )
            return nil
        }
        let matchName = "\(remote)/\(branchName)"
        guard remoteBranches.contains(where: { $0.name == matchName }) else {
            lastError = PresentableError(
                title: "Pull Failed",
                message: "\(branchName) has no upstream to pull from.",
                detail: "There is no \(matchName) to track. Push this branch first to publish it."
            )
            return nil
        }
        // Set the upstream, then pull through tracking — future pulls need no remote named.
        return PullPlan(remote: nil, branch: nil, setUpstreamTo: matchName)
    }

    public func pull(strategy: GitClient.PullStrategy = .merge) async {
        guard let plan = pullPlan() else { return }
        await runRemoteOperation(label: "Pulling…", title: "Pull Failed") { [client] worktree in
            if let ref = plan.setUpstreamTo {
                try await client.setUpstream(worktree: worktree.path, to: ref)
            }
            return try await client.pull(
                worktree: worktree.path,
                remote: plan.remote,
                branch: plan.branch,
                strategy: strategy
            )
        }
    }

    // MARK: - Merge and rebase

    /// Branches that can be merged into the selected worktree's branch: every local and
    /// remote branch except the one already checked out here.
    ///
    /// A branch checked out in *another* worktree is still offered — Git only refuses to
    /// check such a branch out, not to merge from it.
    public var mergeCandidates: [Branch] {
        let current = selectedWorktree.flatMap { branch(for: $0)?.refName }
        return (localBranches + remoteBranches).filter { $0.refName != current }
    }

    /// False while a merge or rebase is already in flight — that has to be resolved or
    /// aborted before another merge can start — or when there is nothing to merge.
    public var canMerge: Bool {
        selectedWorktree?.isWorkingCopyAvailable == true && selectedWorktree?.branchRef != nil
            && mergeOperation == .none && !mergeCandidates.isEmpty
    }

    public var canRebase: Bool {
        canMerge && status.isClean
    }

    /// Merges `branch` into the selected worktree's branch.
    ///
    /// A conflicting merge is reported as a failure *and* still refreshes, so the
    /// conflicted files land in the Changes list, where Use Mine / Use Theirs / Discard
    /// resolve them individually and Abort Merge puts the branch back as it was.
    public func merge(_ branch: Branch, noFastForward: Bool = false) async {
        guard canMerge, let current = selectedWorktree?.branchName else { return }
        await runRemoteOperation(
            label: "Merging \(branch.name) into \(current)…",
            title: "Could Not Merge \(branch.name) into \(current)"
        ) { [client] worktree in
            try await client.merge(
                worktree: worktree.path,
                ref: branch.refName,
                noFastForward: noFastForward
            )
        }
    }

    /// Replays the selected worktree's branch onto `branch`, leaving the base ref alone.
    /// Refresh on failure too, so a stopped rebase exposes Continue, Skip and Abort.
    public func rebase(onto branch: Branch) async {
        // Git checks the live worktree with --no-autostash; cached status may lag a commit.
        guard canMerge, let current = selectedWorktree?.branchName else { return }
        await runRemoteOperation(
            label: "Rebasing \(current) onto \(branch.name)…",
            title: "Could Not Rebase \(current) onto \(branch.name)"
        ) { [client] worktree in
            try await client.rebase(worktree: worktree.path, onto: branch.refName)
        }
    }

    /// The outcome of a stash-pull-reapply, so the caller can tell a clean run from one
    /// the user has to finish resolving.
    private enum StashPullOutcome: Sendable {
        /// Pulled and re-applied cleanly, or there was nothing to stash.
        case clean(output: String)
        /// Work remains in the stash, possibly alongside partially restored files.
        case recovery(output: String, stash: String, error: PresentableError)
    }

    /// Stashes local changes, pulls, and re-applies the stash — the manual dance people
    /// do to pull onto a dirty worktree, done in one step and reported honestly.
    ///
    /// The stash is a transport, dropped only after the changes are safely re-applied;
    /// every failure keeps it and says which commit holds the work. The re-apply does not
    /// restore the staged/unstaged split (`git stash apply` without `--index`): after the
    /// pull moved HEAD, a plain apply is what reliably lands the changes on the new base,
    /// and a conflict could not preserve the split anyway.
    public func stashPullAndReapply(strategy: GitClient.PullStrategy = .merge) async {
        guard let worktree = selectedWorktree else { return }
        // Resolve the pull the same way a plain Pull does — upstream handling and the
        // reconcile strategy included — before touching the stash, so a branch that can't
        // be pulled fails cleanly with nothing stashed.
        guard let plan = pullPlan() else { return }
        guard claim(worktree) else {
            lastError = PresentableError(
                title: "Operation In Progress",
                message: "Another operation is already running in \(worktree.path.path)."
            )
            return
        }
        defer { release(worktree) }

        let outcome = await withOperation(
            label: "Stashing, pulling and re-applying…",
            worktree: worktree
        ) { [client] () -> StashPullOutcome in
            let path = worktree.path

            func pull() async throws -> String {
                if let ref = plan.setUpstreamTo {
                    try await client.setUpstream(worktree: path, to: ref)
                }
                return try await client.pull(
                    worktree: path,
                    remote: plan.remote,
                    branch: plan.branch,
                    strategy: strategy
                )
            }

            guard let stash = try await client.stashPush(
                worktree: path,
                message: "GitTrees: stash & apply"
            ) else {
                // Nothing to stash — this is just a pull.
                return .clean(output: try await pull())
            }

            let output: String
            do {
                output = try await pull()
            } catch {
                let pullError = error
                // The pull failed. If it left the tree untouched, put the changes straight
                // back; if it conflicted or half-applied, don't compound it — keep the
                // stash and name it. Either way nothing is lost.
                if (try? await client.statusSummary(worktree: path).isClean) == true {
                    do {
                        try await client.stashApply(worktree: path, stash: stash, restoringIndex: false)
                    } catch {
                        let issue = Self.stashRecoveryError(
                            title: "Pull Failed — Stash Restore Incomplete",
                            reason: "The pull failed and Git could not fully put your local changes back.",
                            stash: stash, error: error
                        )
                        return .recovery(output: Self.diagnosticOutput(pullError), stash: stash, error: issue)
                    }
                    do {
                        try await Self.dropStash(stash, in: path, using: client)
                    } catch {
                        let issue = Self.stashRecoveryError(
                            title: "Pull Failed — Changes Restored",
                            reason: "The pull failed. Your local changes were restored, but Git could not remove the saved stash. Do not apply it again.",
                            stash: stash, error: error
                        )
                        return .recovery(output: Self.diagnosticOutput(pullError), stash: stash, error: issue)
                    }
                    throw pullError
                }
                let issue = Self.stashRecoveryError(
                    title: "Pull Failed — Changes Kept in Stash",
                    reason: "The pull could not be completed, so your stashed changes were not re-applied. Resolve the pull conflicts before recovering the stash.",
                    stash: stash, error: pullError
                )
                return .recovery(output: "", stash: stash, error: issue)
            }

            do {
                try await client.stashApply(worktree: path, stash: stash, restoringIndex: false)
            } catch {
                // Untracked-file collisions may leave no unmerged index entries at all,
                // or occur alongside a text conflict. Keep all of Git's diagnostics.
                let conflicts = (try? await client.statusSummary(worktree: path).conflicts.map(\.path)) ?? []
                let issue = Self.stashRecoveryError(
                    title: conflicts.isEmpty ? "Stash Re-apply Incomplete" : "Re-applied With Conflicts",
                    reason: "The pull succeeded, but Git could not fully restore your stashed changes. Some files may still be only in the stash.",
                    stash: stash, error: error, conflicts: conflicts
                )
                return .recovery(output: output, stash: stash, error: issue)
            }

            do {
                try await Self.dropStash(stash, in: path, using: client)
            } catch {
                let issue = Self.stashRecoveryError(
                    title: "Changes Restored — Stash Kept",
                    reason: "The pull succeeded and your changes were restored, but Git could not remove the saved stash. Do not apply it again.",
                    stash: stash, error: error
                )
                return .recovery(output: output, stash: stash, error: issue)
            }
            return .clean(output: output)
        } onFailure: { error in
            PresentableError(title: "Stash & Apply Failed", error: error)
        } thenReturning: { (outcome: StashPullOutcome) in outcome }

        // A failed pull or partial apply has already changed Git state. Refresh even
        // when the operation threw, and finish loading conflicts before notifying UI.
        await reload(presentError: false)
        refreshSelectedWorktree()
        await statusTask?.value

        switch outcome {
        case .clean(let output):
            lastOperationOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        case .recovery(let output, let stash, let error):
            showStashRecovery(stash: stash, worktree: worktree, error: error, output: output)
        case .none:
            break // A hard failure already set lastError.
        }
    }

    private nonisolated static func diagnosticOutput(_ error: Error) -> String {
        let diagnostic = PresentableError(title: "", error: error)
        return diagnostic.diagnosticText
    }

    private nonisolated static func stashRecoveryError(
        title: String, reason: String, stash: String, error: Error, conflicts: [String] = []
    ) -> PresentableError {
        let files = conflicts.isEmpty ? "" : "\n\nUnresolved conflicts:\n" + conflicts.map { "• \($0)" }.joined(separator: "\n")
        return PresentableError(
            title: title,
            message: "\(reason)\(files)\n\nThe original changes are kept in stash \(stash.prefix(7)). Review Changes and the saved stash before applying anything again.",
            detail: diagnosticOutput(error),
            recoverySteps: [
                "Review Changes and resolve any conflicted files. Inspect the saved stash in Stashes to find work that was not restored.",
                "Keep the saved stash until you have confirmed that all original changes are present. Review the recovery notice before applying the stash again."
            ]
        )
    }

    private func showStashRecovery(stash: String, worktree: Worktree, error: PresentableError, output: String = "") {
        var diagnostic = error
        if !output.isEmpty {
            diagnostic.detail = [output, error.detail].compactMap { $0 }.joined(separator: "\n\n")
        }
        stashRecoveryNotices[worktree.id] = StashRecoveryNotice(stashCommit: stash, error: diagnostic)
        // The persistent notice and its scrollable Details carry the failure output.
        // Do not duplicate a full command transcript in the compact operation bar.
        lastOperationOutput = nil
        lastError = diagnostic
    }

    // MARK: - Stash panel

    /// A reasonable default message for an explicit stash: the branch it is taken on, so
    /// the stash list reads the way Git's own default does, but pre-filled and editable.
    public var suggestedStashMessage: String {
        if let branch = selectedWorktree?.branchName { return "WIP on \(branch)" }
        return "WIP"
    }

    /// Stashes the selected worktree's changes under `message`. The button that calls this
    /// is disabled on a clean worktree, but "nothing to stash" is still reported rather
    /// than silently doing nothing.
    public func createStash(message: String, includeUntracked: Bool) async {
        guard let worktree = selectedWorktree else { return }
        guard claim(worktree) else {
            lastError = PresentableError(
                title: "Operation In Progress",
                message: "Another operation is already running in \(worktree.path.path)."
            )
            return
        }
        defer { release(worktree) }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalMessage = trimmed.isEmpty ? suggestedStashMessage : trimmed

        let created: String?? = await withOperation(label: "Stashing…", worktree: worktree) { [client] in
            try await client.stashPush(
                worktree: worktree.path,
                message: finalMessage,
                includeUntracked: includeUntracked
            )
        } onFailure: { error in
            PresentableError(title: "Stash Failed", error: error)
        } thenReturning: { [weak self] (sha: String?) -> String? in
            await self?.reload()
            self?.refreshSelectedWorktree()
            return sha
        }

        if case .some(nil) = created {
            lastError = PresentableError(
                title: "Nothing to Stash",
                message: "There are no local changes in \(worktree.displayName) to stash."
            )
        } else if let sha = created ?? nil {
            // Show the new stash straight away so the user can see it landed.
            selectedStashID = sha
        }
    }

    /// Drops a stash, addressing it by commit so a shifted selector cannot take the wrong
    /// one. A stash already gone is not an error — the end state the user wanted holds.
    public func dropStash(_ stash: Stash) async {
        guard let repository else { return }
        _ = await withOperation(label: "Dropping stash…") { [client] in
            try await Self.dropStash(stash.commit, in: repository.commandDirectory, using: client)
        } onFailure: { error in
            PresentableError(title: "Could Not Drop Stash", error: error)
        } thenReturning: { [weak self] in
            if self?.selectedStashID == stash.id { self?.selectedStashID = nil }
            await self?.reload()
            self?.refreshSelectedWorktree()
        }
    }

    /// Applies a stash to the selected worktree, keeping it on the stack (Git's own
    /// `apply`, not `pop`). A conflict is reported and the stash is preserved, so nothing
    /// is lost; the staged/unstaged split is not restored, for the same reason the pull
    /// re-apply does not.
    public func applyStash(_ stash: Stash) async {
        guard let worktree = selectedWorktree else { return }
        guard claim(worktree) else {
            lastError = PresentableError(
                title: "Operation In Progress",
                message: "Another operation is already running in \(worktree.path.path)."
            )
            return
        }
        defer { release(worktree) }

        enum ApplyOutcome: Sendable { case clean, recovery(PresentableError) }

        let outcome = await withOperation(label: "Applying stash…", worktree: worktree) { [client] () -> ApplyOutcome in
            do {
                try await client.stashApply(worktree: worktree.path, stash: stash.commit, restoringIndex: false)
                return .clean
            } catch {
                // A stale stash row can point at an entry deleted by another Git client.
                // Only promise recovery through the stack after verifying it is there.
                guard (try? await client.stashSelector(repository: worktree.path, forCommit: stash.commit)) != nil else {
                    throw error
                }
                let conflicts = (try? await client.statusSummary(worktree: worktree.path).conflicts.map(\.path)) ?? []
                return .recovery(Self.stashRecoveryError(
                    title: conflicts.isEmpty ? "Could Not Fully Apply Stash" : "Applied With Conflicts",
                    reason: "Git could not fully apply the stash. Some files may still be only in the stash.",
                    stash: stash.commit, error: error, conflicts: conflicts
                ))
            }
        } onFailure: { error in
            PresentableError(title: "Could Not Apply Stash", error: error)
        } thenReturning: { (outcome: ApplyOutcome) in outcome }

        await reload(presentError: false)
        refreshSelectedWorktree()
        await statusTask?.value

        if case .recovery(let error) = outcome {
            showStashRecovery(stash: stash.commit, worktree: worktree, error: error)
        }
    }

    /// The patch a stash would apply, for the panel's diff pane.
    public func stashDiff(_ stash: Stash) async throws -> String {
        guard let repository else { return "" }
        return try await client.stashDiff(
            repository: repository.commandDirectory,
            commit: stash.commit,
            contextLines: preferences.diffContextLines
        )
    }

    /// Pushes, publishing the branch when it has no upstream yet.
    /// `forceWithLease` is what makes a branch pushable again after an amend or a rebase
    /// rewrote it. It is `--force-with-lease`, never a bare force: Git refuses if the
    /// remote has moved since the last fetch, so someone else's commits cannot be erased.
    public func push(setUpstream: Bool = false, forceWithLease: Bool = false) async {
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
        await runRemoteOperation(
            label: forceWithLease ? "Force-pushing…" : "Pushing…",
            title: "Push Failed"
        ) { [client] worktree in
            try await client.push(
                worktree: worktree.path,
                remote: remote,
                setUpstream: setUpstream,
                forceWithLease: forceWithLease
            )
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
        guard let worktree = selectedWorktree, worktree.isWorkingCopyAvailable else { return }
        guard claim(worktree) else { return }
        defer { release(worktree) }

        let output = await withOperation(label: label, worktree: worktree) {
            try await body(worktree)
        } onFailure: { error in
            PresentableError(title: title, error: error)
        } thenReturning: { output in output }

        // Refresh whether or not it succeeded: a pull that conflicts, or a push that is
        // rejected, leaves the worktree in a state the Changes view must show — a merge
        // conflict in particular only becomes resolvable once its files appear here.
        await reload()
        refreshSelectedWorktree()

        if let output {
            lastOperationOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Adds a remote and reloads, so the picker and Repository tab pick it up immediately.
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

    /// Repoints an existing remote at a new URL with `git remote set-url`.
    ///
    /// The common reason is switching the host — e.g. a plain `git@github.com:…` to an SSH
    /// config alias like `git@github-ctx:…` so the repository authenticates as the right
    /// account. The reload afterwards refreshes GitHub detection, which keys off the URL.
    public func setRemoteURL(name: String, url: String) async -> Bool {
        guard let repository else { return false }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedURL.isEmpty else { return false }

        let updated = await withOperation(label: "Updating remote…") { [client] in
            try await client.setRemoteURL(
                repository: repository.commandDirectory,
                name: trimmedName,
                url: trimmedURL
            )
        } onFailure: { error in
            PresentableError(title: "Could Not Update Remote", error: error)
        } thenReturning: { [weak self] in
            await self?.reload()
            return true
        }
        return updated ?? false
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
        // A user's Git operation supersedes the silent auto-fetch: cancel it (which
        // SIGTERMs the `git fetch`) so the two cannot contend on `.git` ref locks and
        // surface a spurious "another git process is running" as an operation failure.
        autoFetchTask?.cancel()
        return busyWorktreePaths.insert(worktree.id).inserted
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
