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
        if let gitError = error as? GitError, let failure = gitError.failure {
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

    /// Path of the selected worktree. Paths, not indices, so a refresh cannot
    /// silently move the selection to a different worktree.
    public var selectedWorktreePath: String? {
        didSet {
            guard selectedWorktreePath != oldValue else { return }
            status = .empty
            history = []
            selectedFile = nil
            refreshSelectedWorktree()
        }
    }

    /// The file whose diff is shown, plus which side of the index it is shown for.
    public var selectedFile: FileChange?
    public var showingStagedDiff = false

    public private(set) var isLoadingRepository = false
    public private(set) var isRefreshing = false
    public private(set) var activeOperation: ActiveOperation?
    public var lastError: PresentableError?
    /// Output of the last fetch/pull/push, shown in the operation banner.
    public private(set) var lastOperationOutput: String?

    private let preferences: PreferencesService
    private var client: GitClient
    private var gitExecutablePath: String

    /// Worktrees with a destructive operation in flight.
    ///
    /// Main-actor isolation makes the test-and-insert atomic: the check happens before
    /// the first `await`, so two operations can never both pass it.
    private var busyWorktreePaths: Set<String> = []
    private var refreshTask: Task<Void, Never>?
    private var dirtyScanTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?

    public init(preferences: PreferencesService) {
        self.preferences = preferences
        self.gitExecutablePath = preferences.gitExecutablePath
        self.client = GitClient(runner: GitProcessRunner(executablePath: preferences.gitExecutablePath))
    }

    // MARK: - Derived state

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
            lastError = PresentableError(title: "Could Not Open Repository", error: error)
        }
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
            // Worktrees and branches are independent reads; run them concurrently.
            async let worktreeList = client.worktrees(repository: repository.commandDirectory)
            async let branchList = client.branches(repository: repository.commandDirectory)
            let (loadedWorktrees, loadedBranches) = try await (worktreeList, branchList)

            worktrees = loadedWorktrees
            branches = loadedBranches

            // Keep the selection valid across worktree removals.
            if let selectedWorktreePath, !worktrees.contains(where: { $0.id == selectedWorktreePath }) {
                self.selectedWorktreePath = worktrees.first { !$0.isBare }?.id
            }
            scanDirtyStates()
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

    public func fetch(prune: Bool = false) async {
        await runRemoteOperation(label: "Fetching…", title: "Fetch Failed") { [client] worktree in
            try await client.fetch(worktree: worktree.path, prune: prune)
        }
    }

    public func pull() async {
        await runRemoteOperation(label: "Pulling…", title: "Pull Failed") { [client] worktree in
            try await client.pull(worktree: worktree.path)
        }
    }

    public func push(setUpstream: Bool = false) async {
        await runRemoteOperation(label: "Pushing…", title: "Push Failed") { [client] worktree in
            try await client.push(worktree: worktree.path, setUpstream: setUpstream)
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

    public func clearOperationOutput() {
        lastOperationOutput = nil
    }

    // MARK: - Preferences plumbing

    /// Recreates the Git client when the user points at a different git binary.
    public func rebuildClientIfNeeded() {
        guard preferences.gitExecutablePath != gitExecutablePath else { return }
        gitExecutablePath = preferences.gitExecutablePath
        client = GitClient(runner: GitProcessRunner(executablePath: gitExecutablePath))
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
