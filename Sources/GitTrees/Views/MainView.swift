import GitTreesCore
import SwiftUI
import UniformTypeIdentifiers

/// What the sidebar can have selected. Worktrees are addressed by path and branches by
/// ref so a refresh cannot move the selection to a different object.
enum SidebarItem: Hashable {
    case worktree(String)
    case branch(String)
}

struct MainView: View {
    @Environment(RepositoryService.self) private var service
    @Environment(PreferencesService.self) private var preferences
    @Environment(WorkspaceLauncher.self) private var launcher
    @Environment(AppCommands.self) private var commands

    @State private var selection: SidebarItem?
    @State private var showingOpenPanel = false
    @State private var activeSheet: ActiveSheet?
    @State private var hasRestored = false

    var body: some View {
        @Bindable var service = service

        NavigationSplitView {
            RepositorySidebar(
                selection: $selection,
                onNewWorktree: { activeSheet = .newWorktree },
                onOpenRepository: { showingOpenPanel = true },
                onRequestRemoval: { requestRemoval(of: $0) },
                onRequestLock: { activeSheet = .lockWorktree($0) }
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 420)
        } detail: {
            detail
                // Opening a folder that is not a repository offers to create one there.
                // This alert is attached here rather than alongside the error alert
                // above: two alerts on a single view do not both present.
                .alert(
                    "Not a Git Repository",
                    isPresented: Binding(
                        get: { service.uninitializedDirectory != nil },
                        set: { if !$0 { service.dismissInitializationPrompt() } }
                    ),
                    presenting: service.uninitializedDirectory
                ) { directory in
                    Button("Create Repository") {
                        Task { await service.initializeRepository(at: directory) }
                    }
                    Button("Cancel", role: .cancel) { service.dismissInitializationPrompt() }
                } message: { directory in
                    Text("\(RepositorySidebar.abbreviate(directory)) is not inside a Git repository.\n\nRun git init here to create one? Nothing already in the folder is changed.")
                }
        }
        .navigationTitle(service.repository?.name ?? "GitTrees")
        .toolbar { toolbarContent }
        .task { await restoreIfNeeded() }
        .onChange(of: selection) { _, newValue in applySelection(newValue) }
        .onChange(of: service.selectedWorktreePath) { _, newValue in
            // Keep the sidebar in step when the selection is changed elsewhere, such as
            // after removing a worktree or creating one.
            if let newValue, selection != .worktree(newValue) {
                selection = .worktree(newValue)
            }
        }
        .fileImporter(
            isPresented: $showingOpenPanel,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleOpenPanel(result)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .newWorktree:
                NewWorktreeSheet(preselectedBranch: preselectedBranchForSheet)
            case .removeWorktree(let removal):
                RemoveWorktreeSheet(removal: removal)
            case .lockWorktree(let worktree):
                LockWorktreeSheet(worktree: worktree)
            case .addRemote:
                AddRemoteSheet()
            case .createPullRequest:
                CreatePullRequestSheet()
            }
        }
        .alert(
            service.lastError?.title ?? "Git Error",
            isPresented: Binding(
                get: { service.lastError != nil },
                set: { if !$0 { service.lastError = nil } }
            ),
            presenting: service.lastError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(errorBody(error))
        }
        // Menu-bar commands are relayed through AppCommands.
        .onChange(of: commands.openRepositoryRequested) { _, requested in
            if requested { showingOpenPanel = true; commands.openRepositoryRequested = false }
        }
        .onChange(of: commands.newWorktreeRequested) { _, requested in
            if requested {
                if service.repository != nil { activeSheet = .newWorktree }
                commands.newWorktreeRequested = false
            }
        }
        .onChange(of: commands.pendingRecent) { _, recent in
            guard let recent else { return }
            commands.pendingRecent = nil
            Task { await service.open(directory: recent.path) }
        }
        .onChange(of: commands.addRemoteRequested) { _, requested in
            if requested {
                if service.repository != nil { activeSheet = .addRemote }
                commands.addRemoteRequested = false
            }
        }
        .onChange(of: commands.createPullRequestRequested) { _, requested in
            if requested {
                if service.repository != nil { activeSheet = .createPullRequest }
                commands.createPullRequestRequested = false
            }
        }
        .onChange(of: commands.openInEditorRequested) { _, requested in
            guard requested else { return }
            commands.openInEditorRequested = false
            guard let worktree = service.selectedWorktree else { return }
            Task { await openWorktree(worktree, in: preferences.preferredEditor) }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if service.repository == nil {
            NoRepositoryView(onOpen: { showingOpenPanel = true })
        } else if let worktree = service.selectedWorktree {
            WorktreeDetailView(
                worktree: worktree,
                onRequestRemoval: { requestRemoval(of: $0) },
                onRequestLock: { activeSheet = .lockWorktree($0) },
                onAddRemote: { activeSheet = .addRemote },
                onCreatePullRequest: { activeSheet = .createPullRequest }
            )
        } else if case .branch(let ref) = selection,
                  let branch = service.branches.first(where: { $0.refName == ref }) {
            InactiveBranchView(
                branch: branch,
                onCreateWorktree: { activeSheet = .newWorktree }
            )
        } else {
            ContentUnavailableView(
                "No Worktree Selected",
                systemImage: "square.split.2x1",
                description: Text("Select a worktree in the sidebar.")
            )
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                showingOpenPanel = true
            } label: {
                Label("Open Repository", systemImage: "folder")
            }
            .help("Open Repository (⌘O)")
        }

        ToolbarItemGroup {
            if service.activeOperation != nil || service.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .help(service.activeOperation?.label ?? "Refreshing…")
            }

            Button {
                service.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh (⌘R)")
            .disabled(service.repository == nil)

            Button {
                activeSheet = .newWorktree
            } label: {
                Label("New Worktree", systemImage: "plus.rectangle.on.rectangle")
            }
            .help("New Worktree (⌘N)")
            .disabled(service.repository == nil)
        }
    }

    // MARK: - Selection

    /// Clicking a branch that already has a worktree selects that worktree instead of
    /// attempting a second checkout, which Git would refuse.
    private func applySelection(_ item: SidebarItem?) {
        switch item {
        case .worktree(let path):
            service.selectedWorktreePath = path
        case .branch(let ref):
            guard let branch = service.branches.first(where: { $0.refName == ref }) else { return }
            if let worktree = service.worktree(for: branch) {
                selection = .worktree(worktree.id)
            } else {
                service.selectedWorktreePath = nil
            }
        case nil:
            break
        }
    }

    private var preselectedBranchForSheet: String? {
        if case .branch(let ref) = selection,
           let branch = service.branches.first(where: { $0.refName == ref }),
           service.worktree(for: branch) == nil {
            return branch.name
        }
        return nil
    }

    // MARK: - Actions

    private func restoreIfNeeded() async {
        guard !hasRestored else { return }
        hasRestored = true
        guard let url = preferences.repositoryToRestore() else { return }
        await service.open(directory: url)
    }

    private func handleOpenPanel(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        Task { await service.open(directory: url) }
    }

    /// Reads the worktree's status first: a dirty worktree must never be removed
    /// without showing the user what would be lost.
    private func requestRemoval(of worktree: Worktree) {
        Task {
            let blocking = await service.changesBlockingRemoval(of: worktree)
            activeSheet = .removeWorktree(WorktreeRemoval(worktree: worktree, blockingChanges: blocking))
        }
    }

    private func openWorktree(_ worktree: Worktree, in application: WorkspaceApplication) async {
        do {
            try await launcher.open(worktree.path, in: application)
        } catch {
            service.lastError = PresentableError(title: "Could Not Open Worktree", error: error)
        }
    }

    private func errorBody(_ error: PresentableError) -> String {
        guard let detail = error.detail, !detail.isEmpty else { return error.message }
        return "\(error.message)\n\n\(detail)"
    }
}

/// The one modal the window can be showing.
///
/// SwiftUI presents only one of several `.sheet` modifiers attached to the same view,
/// so every modal goes through a single presenter rather than one modifier each.
enum ActiveSheet: Identifiable {
    case newWorktree
    case removeWorktree(WorktreeRemoval)
    case lockWorktree(Worktree)
    case addRemote
    case createPullRequest

    var id: String {
        switch self {
        case .newWorktree: "new-worktree"
        case .removeWorktree(let removal): "remove-\(removal.id)"
        case .lockWorktree(let worktree): "lock-\(worktree.id)"
        case .addRemote: "add-remote"
        case .createPullRequest: "create-pull-request"
        }
    }
}

/// A pending removal, carrying whatever would be discarded so the sheet can warn.
struct WorktreeRemoval: Identifiable {
    let worktree: Worktree
    let blockingChanges: WorktreeStatus?

    var id: String { worktree.id }
}

private struct NoRepositoryView: View {
    let onOpen: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Repository Open", systemImage: "point.3.filled.connected.trianglepath.dotted")
        } description: {
            Text("Open a Git repository, or any of its worktrees, to get started. Choosing a folder that is not yet a repository offers to create one there.")
        } actions: {
            Button("Open Repository…", action: onOpen)
        }
    }
}
