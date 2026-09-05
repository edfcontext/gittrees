import AppKit
import GitTreesCore
import SwiftUI

@main
struct GitTreesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var preferences: PreferencesService
    @State private var service: RepositoryService
    @State private var launcher = WorkspaceLauncher()
    @State private var commands = AppCommands()

    init() {
        let preferences = PreferencesService()
        _preferences = State(initialValue: preferences)
        _service = State(initialValue: RepositoryService(preferences: preferences))
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(preferences)
                .environment(service)
                .environment(launcher)
                .environment(commands)
                .frame(minWidth: 860, minHeight: 520)
                .background(WindowConfigurator(title: windowTitle))
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1160, height: 720)
        .commands { menuCommands }

        Settings {
            PreferencesView()
                .environment(preferences)
                .environment(service)
                .environment(launcher)
        }
    }

    /// Remote and commit actions need a selected worktree to run in.
    private var hasNoWorktree: Bool { service.selectedWorktree == nil }

    private var windowTitle: String {
        service.repository.map { "GitTrees — \($0.name)" } ?? "GitTrees"
    }

    @CommandsBuilder
    private var menuCommands: some Commands {
        // Replacing the New group keeps "New Worktree" where a Mac user expects it.
        CommandGroup(replacing: .newItem) {
            Button("Open Repository…") { commands.openRepository() }
                .keyboardShortcut("o", modifiers: .command)

            Menu("Open Recent") {
                ForEach(preferences.recentRepositories) { recent in
                    Button(recent.name) { commands.openRecent(recent) }
                }
                if !preferences.recentRepositories.isEmpty {
                    Divider()
                    Button("Clear Menu") { preferences.clearRecents() }
                }
            }
            .disabled(preferences.recentRepositories.isEmpty)

            Divider()

            Button("New Worktree…") { commands.newWorktree() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(service.repository == nil)
        }

        CommandGroup(after: .toolbar) {
            Button("Refresh") { service.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(service.repository == nil)
        }

        CommandMenu("Repository") {
            Button("Fetch") { Task { await service.fetch() } }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(hasNoWorktree)
            Button("Pull") { Task { await service.pull() } }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(hasNoWorktree)
            Button("Push") { Task { await service.push(setUpstream: service.selectedBranchNeedsUpstream) } }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(hasNoWorktree)

            Divider()

            Button("Add Remote…") { commands.addRemote() }

            Button("Create Pull Request…") { commands.createPullRequest() }
                .disabled(hasNoWorktree)

            Divider()

            Button("Commit…") { commands.focusCommitMessage() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(hasNoWorktree)

            Divider()

            Button("Prune Stale Worktrees") { Task { await service.pruneWorktrees() } }
                .disabled(service.repository == nil)
        }

        CommandGroup(after: .windowArrangement) {
            Button("Open in \(preferences.preferredEditor.displayName)") {
                commands.openInEditor()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(service.selectedWorktree == nil)
        }
    }
}

/// Makes the process a normal foreground application even when it is launched as a
/// bare SwiftPM executable (`swift run`) rather than from the built `.app` bundle.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// Bridges menu-bar commands to the view that can act on them.
///
/// Menu items live in the `App` scene while the sheets and pickers they trigger live in
/// the view hierarchy, so the two are connected by these observable flags.
@MainActor
@Observable
final class AppCommands {
    var openRepositoryRequested = false
    var newWorktreeRequested = false
    var openInEditorRequested = false
    var addRemoteRequested = false
    var createPullRequestRequested = false
    var commitFocusRequested = false
    var pendingRecent: RecentRepository?

    func openRepository() { openRepositoryRequested = true }
    func newWorktree() { newWorktreeRequested = true }
    func openInEditor() { openInEditorRequested = true }
    func addRemote() { addRemoteRequested = true }
    func createPullRequest() { createPullRequestRequested = true }
    func focusCommitMessage() { commitFocusRequested = true }
    func openRecent(_ recent: RecentRepository) { pendingRecent = recent }
}
