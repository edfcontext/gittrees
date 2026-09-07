import AppKit
import GitTreesCore
import SwiftUI

enum GitTreesScene {
    static let repositoryWindowID = "repository"
}

/// Shared across windows: which repository is key (for Settings) and paths newly
/// created windows should open.
@MainActor
@Observable
final class AppSession {
    /// Empty service used by Settings when no repository window is key.
    let inactiveService: RepositoryService
    weak var keyService: RepositoryService?
    weak var keyCommands: AppCommands?
    /// Consumed FIFO by windows as they appear.
    private var pendingDirectories: [URL] = []
    /// Live repository windows, keyed by their service identity.
    private var liveWindowIDs: Set<ObjectIdentifier> = []
    /// Weak refs so activation can refresh every open repository, not only the
    /// window that happens to be key — `didBecomeKey` often does not fire when
    /// the app is reactivated by the Dock or a click on an already-focused pane.
    private var liveServices: [ObjectIdentifier: WeakRepositoryService] = [:]
    /// The process-wide session, so `AppDelegate` can refresh on `applicationDidBecomeActive`.
    weak static var current: AppSession?
    /// Set from `applicationShouldTerminate` before windows start closing on ⌘Q.
    private(set) static var isTerminating = false

    static func markTerminating() {
        isTerminating = true
    }

    init(preferences: PreferencesService) {
        self.inactiveService = RepositoryService(preferences: preferences)
        AppSession.current = self
    }

    var serviceForSettings: RepositoryService {
        keyService ?? inactiveService
    }

    func enqueuePendingDirectory(_ url: URL) {
        pendingDirectories.append(url)
    }

    func enqueuePendingDirectories(_ urls: [URL]) {
        pendingDirectories.append(contentsOf: urls)
    }

    func takePendingDirectory() -> URL? {
        guard !pendingDirectories.isEmpty else { return nil }
        return pendingDirectories.removeFirst()
    }

    func registerWindow(_ service: RepositoryService) {
        let id = ObjectIdentifier(service)
        liveWindowIDs.insert(id)
        liveServices[id] = WeakRepositoryService(service)
    }

    /// Re-reads every open repository. Called when GitTrees becomes the active app
    /// again, so Changes pick up edits made in an IDE without requiring a click
    /// inside the window first.
    func refreshAllOnActivation() {
        for box in liveServices.values {
            box.service?.refreshOnWindowActivation()
        }
    }

    /// Drops the closed window from the restore list unless this is a quit — closing
    /// the last window terminates the app, and ⌘Q closes every window, so both would
    /// otherwise wipe the session we want to reopen.
    func windowWillClose(_ service: RepositoryService, preferences: PreferencesService) {
        let id = ObjectIdentifier(service)
        liveWindowIDs.remove(id)
        liveServices.removeValue(forKey: id)
        let quitting = AppSession.isTerminating || liveWindowIDs.isEmpty
        guard !quitting, let repository = service.repository else { return }
        preferences.forgetOpen(repository.mainWorktreePath.path)
    }
}

/// Weak box so `AppSession` can iterate live windows without retaining them.
private final class WeakRepositoryService {
    weak var service: RepositoryService?
    init(_ service: RepositoryService) { self.service = service }
}

private struct RepositoryServiceFocusedKey: FocusedValueKey {
    typealias Value = RepositoryService
}

private struct AppCommandsFocusedKey: FocusedValueKey {
    typealias Value = AppCommands
}

extension FocusedValues {
    var repositoryService: RepositoryService? {
        get { self[RepositoryServiceFocusedKey.self] }
        set { self[RepositoryServiceFocusedKey.self] = newValue }
    }

    var appCommands: AppCommands? {
        get { self[AppCommandsFocusedKey.self] }
        set { self[AppCommandsFocusedKey.self] = newValue }
    }
}

@main
struct GitTreesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var preferences: PreferencesService
    @State private var launcher = WorkspaceLauncher()
    @State private var session: AppSession

    init() {
        let preferences = PreferencesService()
        _preferences = State(initialValue: preferences)
        _session = State(initialValue: AppSession(preferences: preferences))
    }

    var body: some Scene {
        WindowGroup(id: GitTreesScene.repositoryWindowID) {
            RepositoryWindow(
                preferences: preferences,
                launcher: launcher,
                session: session
            )
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1160, height: 720)
        .commands {
            GitTreesCommands(preferences: preferences, session: session)
        }

        Settings {
            PreferencesView()
                .environment(preferences)
                .environment(session.serviceForSettings)
                .environment(launcher)
                .environment(session)
        }
    }
}

/// One window, one open repository. Windows do not share `RepositoryService`.
struct RepositoryWindow: View {
    let preferences: PreferencesService
    let launcher: WorkspaceLauncher
    let session: AppSession

    @State private var service: RepositoryService
    @State private var commands = AppCommands()

    init(preferences: PreferencesService, launcher: WorkspaceLauncher, session: AppSession) {
        self.preferences = preferences
        self.launcher = launcher
        self.session = session
        _service = State(initialValue: RepositoryService(preferences: preferences))
    }

    var body: some View {
        MainView()
            .environment(preferences)
            .environment(service)
            .environment(launcher)
            .environment(commands)
            .environment(session)
            .frame(minWidth: 860, minHeight: 520)
            .background(
                WindowConfigurator(title: windowTitle) {
                    session.keyService = service
                    session.keyCommands = commands
                    service.refreshOnWindowActivation()
                } onAppActive: {
                    service.refreshOnWindowActivation()
                } onWillClose: {
                    session.windowWillClose(service, preferences: preferences)
                }
            )
            .onAppear { session.registerWindow(service) }
            .focusedSceneValue(\.repositoryService, service)
            .focusedSceneValue(\.appCommands, commands)
    }

    private var windowTitle: String {
        service.repository.map { "GitTrees — \($0.name)" } ?? "GitTrees"
    }
}

/// Makes the process a normal foreground application even when it is launched as a
/// bare SwiftPM executable (`swift run`) rather than from the built `.app` bundle.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppSession.current?.refreshAllOnActivation()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppSession.markTerminating()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// Bridges menu-bar commands to the view that can act on them.
///
/// Menu items live in the `App` scene while the sheets and pickers they trigger live in
/// the view hierarchy, so the two are connected by these observable flags. Each window
/// has its own instance; commands use the key window's.
@MainActor
@Observable
final class AppCommands {
    var openRepositoryRequested = false
    var newWorktreeRequested = false
    var newWorkspaceRequested = false
    var openInEditorRequested = false
    var addRemoteRequested = false
    var createPullRequestRequested = false
    var commitFocusRequested = false
    var newWindowRequested = false
    var pendingRecent: RecentRepository?
    /// The path the Changes context menu asked to build an ignore rule for.
    var ignoreRequest: IgnoreRequest?
    /// Open the New Worktree sheet already set to carry the current changes across.
    var branchChangesRequested = false

    func openRepository() { openRepositoryRequested = true }
    func newWorktree() { newWorktreeRequested = true }
    func newWorkspace() { newWorkspaceRequested = true }
    func openInEditor() { openInEditorRequested = true }
    func addRemote() { addRemoteRequested = true }
    func createPullRequest() { createPullRequestRequested = true }
    func focusCommitMessage() { commitFocusRequested = true }
    func newWindow() { newWindowRequested = true }
    func openRecent(_ recent: RecentRepository) { pendingRecent = recent }
    func ignore(path: String) { ignoreRequest = IgnoreRequest(path: path) }
    func branchChanges() { branchChangesRequested = true }
}

/// Menu commands target the key repository window.
private struct GitTreesCommands: Commands {
    @FocusedValue(\.repositoryService) private var focusedService
    @FocusedValue(\.appCommands) private var focusedCommands

    var preferences: PreferencesService
    var session: AppSession

    private var service: RepositoryService? { focusedService ?? session.keyService }
    private var commands: AppCommands? { focusedCommands ?? session.keyCommands }

    private var hasNoWorktree: Bool { service?.selectedWorktree == nil }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") { commands?.newWindow() }
                .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("New Repository…") { commands?.newWorkspace() }
                .keyboardShortcut("n", modifiers: [.command, .option])

            Button("Open Repository…") { commands?.openRepository() }
                .keyboardShortcut("o", modifiers: .command)

            Menu("Open Recent") {
                ForEach(preferences.recentRepositories) { recent in
                    Button(recent.name) { commands?.openRecent(recent) }
                }
                if !preferences.recentRepositories.isEmpty {
                    Divider()
                    Button("Clear Menu") { preferences.clearRecents() }
                }
            }
            .disabled(preferences.recentRepositories.isEmpty)

            Divider()

            Button("New Worktree…") { commands?.newWorktree() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(service?.repository == nil)
        }

        CommandGroup(after: .toolbar) {
            Button("Refresh") { service?.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(service?.repository == nil)
        }

        CommandMenu("Repository") {
            Button("Fetch") {
                Task { await service?.fetch() }
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(hasNoWorktree)
            Button("Pull") {
                Task { await service?.pull() }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(hasNoWorktree)
            Button("Push") {
                Task { await service?.push(setUpstream: service?.selectedBranchNeedsUpstream ?? false) }
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(hasNoWorktree)

            Divider()

            Button("Add Remote…") { commands?.addRemote() }
                .disabled(service?.repository == nil)

            Button("Create Pull Request…") { commands?.createPullRequest() }
                .disabled(hasNoWorktree)

            Divider()

            Button("Commit…") { commands?.focusCommitMessage() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(hasNoWorktree)

            Button("Move Changes to New Worktree…") { commands?.branchChanges() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(hasNoWorktree || service?.status.isClean != false)

            Divider()

            Button("Prune Stale Worktrees") {
                Task { await service?.pruneWorktrees() }
            }
            .disabled(service?.repository == nil)

            if let service, let main = service.mainWorktree {
                Divider()

                Menu("Switch Main Worktree Branch") {
                    ForEach(service.localBranches) { branch in
                        let isCurrent = branch.refName == main.branchRef
                        Button(branch.name) {
                            Task { await service.checkout(branch: branch, in: main) }
                        }
                        .disabled(isCurrent || service.isCheckedOutElsewhere(branch, from: main))
                    }
                }
                .disabled(main.isMissingOnDisk)
            }
        }

        CommandGroup(after: .windowArrangement) {
            Button("Open in \(preferences.preferredEditor.displayName)") {
                commands?.openInEditor()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(service?.selectedWorktree == nil)
        }
    }
}
