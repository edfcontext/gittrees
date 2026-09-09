import GitTreesCore
import SwiftUI

/// The main content area: a header describing the selected worktree, then Changes,
/// History and Repository.
struct WorktreeDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case changes = "Changes"
        case history = "History"
        case stashes = "Stashes"
        case branchInfo = "Repository"

        var id: String { rawValue }
    }

    @Environment(RepositoryService.self) private var service
    @Environment(PreferencesService.self) private var preferences
    @Environment(WorkspaceLauncher.self) private var launcher

    let worktree: Worktree
    let onRequestRemoval: (Worktree) -> Void
    let onRequestLock: (Worktree) -> Void
    let onAddRemote: () -> Void
    let onCreatePullRequest: () -> Void

    @State private var tab: Tab = .changes

    var body: some View {
        VStack(spacing: 0) {
            WorktreeHeaderBar(
                worktree: worktree,
                onRequestRemoval: onRequestRemoval,
                onRequestLock: onRequestLock,
                onAddRemote: onAddRemote,
                onCreatePullRequest: onCreatePullRequest
            )

            Divider()

            HStack(spacing: 0) {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { tab in
                        Text(label(for: tab)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let output = service.lastOperationOutput, !output.isEmpty {
                OperationOutputBar(text: output) { service.clearOperationOutput() }
            }
        }
        .background(GitTreesUI.barBackground)
    }

    /// The tab's name, with a stash count so the user can see stashes exist without
    /// opening the tab.
    private func label(for tab: Tab) -> String {
        if tab == .stashes, !service.stashes.isEmpty {
            return "Stashes (\(service.stashes.count))"
        }
        return tab.rawValue
    }

    @ViewBuilder
    private var content: some View {
        if worktree.isMissingOnDisk {
            MissingWorktreeView(worktree: worktree, onRequestRemoval: onRequestRemoval)
        } else {
            switch tab {
            case .changes:
                ChangesView()
            case .history:
                HistoryView()
            case .stashes:
                StashView()
            case .branchInfo:
                BranchInfoView(worktree: worktree, onAddRemote: onAddRemote)
            }
        }
    }
}

/// Branch, path, cleanliness, tracking, and the remote/IDE actions.
struct WorktreeHeaderBar: View {
    @Environment(RepositoryService.self) private var service
    @Environment(PreferencesService.self) private var preferences
    @Environment(WorkspaceLauncher.self) private var launcher
    @Environment(AppCommands.self) private var commands

    let worktree: Worktree
    let onRequestRemoval: (Worktree) -> Void
    let onRequestLock: (Worktree) -> Void
    let onAddRemote: () -> Void
    let onCreatePullRequest: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: worktree.isDetached ? "arrow.triangle.branch" : "arrow.branch")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    branchTitle

                    if worktree.isMain { BadgeLabel(text: "main worktree") }
                    if worktree.isLocked {
                        BadgeLabel(text: worktree.lockReason.map { "locked · \($0)" } ?? "locked", tint: .secondary)
                    }
                    if worktree.isPrunable { BadgeLabel(text: "prunable", tint: .orange) }

                    stateBadge
                }

                HStack(spacing: 8) {
                    Text(RepositorySidebar.abbreviate(worktree.path))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .layoutPriority(-1)
                        .help(worktree.path.path)

                    if let tracking = trackingText {
                        Text(tracking)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
            }
            // A long worktree path must compress rather than push the actions
            // off the end of the bar.
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(-1)

            actions
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The main worktree's branch is a menu: switching it is `git checkout` in that
    /// directory. Linked worktrees keep a static title — they exist for one branch.
    @ViewBuilder
    private var branchTitle: some View {
        let title = worktree.branchName ?? worktree.displayName
        if worktree.isMain, !worktree.isBare, !worktree.isMissingOnDisk {
            Menu {
                SwitchBranchMenuContent(worktree: worktree)
            } label: {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(service.isBusy(worktree))
            .help("Switch the branch checked out in the main worktree")
        } else {
            Text(title)
                .font(.headline)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var stateBadge: some View {
        if service.status.isClean {
            BadgeLabel(text: "clean", tint: .green)
        } else {
            let count = service.status.changes.count
            BadgeLabel(text: "\(count) change\(count == 1 ? "" : "s")", tint: .orange)
        }
    }

    private var trackingText: String? {
        guard let upstream = service.status.upstream else {
            return service.branch(for: worktree)?.hasUpstream == false ? "no upstream" : nil
        }
        var text = upstream
        var counts: [String] = []
        if let ahead = service.status.ahead, ahead > 0 { counts.append("↑\(ahead)") }
        if let behind = service.status.behind, behind > 0 { counts.append("↓\(behind)") }
        if !counts.isEmpty { text += "  " + counts.joined(separator: " ") }
        return text
    }

    private var actions: some View {
        HStack(spacing: 6) {
            // Only worth the space when there is actually a choice to make.
            if service.remotes.count > 1 { remotePicker }

            Button("Stash") { commands.stash() }
                .disabled(service.status.isClean)
                .help(service.status.isClean
                    ? "Nothing to stash — the worktree is clean."
                    : "Set the local changes aside on the stash (⌥⌘S).")

            Divider().frame(height: 16)

            Button("Fetch") { Task { await service.fetch() } }
                .help(service.selectedRemote.map { "git fetch \($0) (⇧⌘F)" } ?? "git fetch --all (⇧⌘F)")
            Menu("Pull") {
                Button("Pull") { Task { await service.pull() } }
                Button("Stash, Pull & Re-apply") { Task { await service.stashPullAndReapply() } }
                    .help("Stash local changes, pull, then re-apply them — with a warning if a file conflicts.")
            } primaryAction: {
                Task { await service.pull() }
            }
            .menuStyle(.button)
            .fixedSize()
            .help(service.selectedRemote.map { "git pull \($0) (⇧⌘P)" } ?? "git pull (⇧⌘P)")
            Button(service.selectedBranchNeedsUpstream ? "Push…" : "Push") {
                Task { await service.push(setUpstream: service.selectedBranchNeedsUpstream) }
            }
            .help(pushHelp)

            if service.hasGitHubRemote {
                Button(pullRequestButtonTitle) { onCreatePullRequest() }
                    .help(pullRequestButtonHelp)
            }

            Divider().frame(height: 16)

            Button {
                openInPreferredEditor()
            } label: {
                Label("Open in \(preferences.preferredEditor.displayName)", systemImage: "arrow.up.forward.app")
                    .labelStyle(.titleAndIcon)
            }
            .help("Open this worktree in \(preferences.preferredEditor.displayName) (⇧⌘D)")

            Menu {
                WorktreeContextMenu(
                    worktree: worktree,
                    onRequestRemoval: onRequestRemoval,
                    onRequestLock: onRequestLock
                )
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .controlSize(.small)
        .disabled(service.isBusy(worktree))
    }

    /// Chooses which remote fetch, pull and push address.
    private var remotePicker: some View {
        Menu {
            Picker("Remote", selection: remoteBinding) {
                Text("Automatic").tag(String?.none)
                Divider()
                ForEach(service.remotes) { remote in
                    Text(remote.name).tag(String?.some(remote.name))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            Divider()

            Button("Add Remote…") { onAddRemote() }
        } label: {
            Label(service.selectedRemote ?? "Automatic", systemImage: "cloud")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Which remote Fetch, Pull and Push use. Automatic fetches every remote and lets pull and push follow the branch's own tracking configuration.")
    }

    private var remoteBinding: Binding<String?> {
        Binding(
            get: { service.selectedRemote },
            set: { service.selectedRemote = $0 }
        )
    }

    private var pullRequestButtonTitle: String {
        if let pr = service.pullRequest, pr.isOpen { return "PR #\(pr.number)" }
        return "Pull Request…"
    }

    private var pullRequestButtonHelp: String {
        if let pr = service.pullRequest, pr.isOpen {
            return "View pull request #\(pr.number) for this branch"
        }
        return "Open a pull request with gh pr create"
    }

    private var pushHelp: String {
        guard service.selectedBranchNeedsUpstream else {
            return service.selectedRemote.map { "git push \($0) (⇧⌘U)" } ?? "git push (⇧⌘U)"
        }
        let remote = service.remoteForPublishing ?? "<remote>"
        return "git push --set-upstream \(remote) \(worktree.branchName ?? "")"
    }

    private func openInPreferredEditor() {
        Task {
            do {
                try await launcher.open(worktree.path, in: preferences.preferredEditor)
            } catch {
                service.lastError = PresentableError(title: "Could Not Open Worktree", error: error)
            }
        }
    }
}

/// The transient banner showing what fetch/pull/push/commit printed.
struct OperationOutputBar: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "text.alignleft")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                ScrollView(.vertical) {
                    Text(text)
                        .font(GitTreesUI.monospaced)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 76)

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}

/// Shown when Git still records a worktree whose directory has been deleted.
struct MissingWorktreeView: View {
    @Environment(RepositoryService.self) private var service

    let worktree: Worktree
    let onRequestRemoval: (Worktree) -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Worktree Directory Is Missing", systemImage: "exclamationmark.triangle")
        } description: {
            VStack(spacing: 6) {
                Text(worktree.path.path)
                    .font(GitTreesUI.monospaced)
                    .textSelection(.enabled)
                if let reason = worktree.prunableReason {
                    Text("Git reports: \(reason)")
                        .font(.caption)
                }
                Text("The Git metadata for this worktree still exists. Pruning removes the record; nothing on disk is touched.")
                    .font(.caption)
            }
        } actions: {
            Button("Prune Stale Worktrees") {
                Task { await service.pruneWorktrees() }
            }
            Button("Remove Worktree…") { onRequestRemoval(worktree) }
        }
    }
}

/// Detail pane for a branch with no worktree, offering the two valid next steps.
struct InactiveBranchView: View {
    @Environment(RepositoryService.self) private var service

    let branch: Branch
    let onCreateWorktree: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(branch.name, systemImage: "arrow.branch")
        } description: {
            VStack(spacing: 4) {
                Text("This branch has no worktree.")
                if let upstream = branch.upstreamName {
                    Text("Tracks \(upstream)\(branch.trackingSummary.map { " · \($0)" } ?? "")")
                        .font(.caption)
                }
                Text(branch.objectName.prefix(12))
                    .font(GitTreesUI.monospaced)
                    .foregroundStyle(.tertiary)
            }
        } actions: {
            Button("Create Worktree…", action: onCreateWorktree)
                .buttonStyle(.borderedProminent)

            Button("Checkout in Main Worktree") {
                guard let worktree = service.mainWorktree else { return }
                Task { await service.checkout(branch: branch, in: worktree) }
            }
            .disabled(!canCheckoutInMain)
            .help(service.mainWorktree.map { "Runs git checkout in \($0.path.path)" }
                  ?? "The repository has no main worktree.")
        }
    }

    private var canCheckoutInMain: Bool {
        guard let main = service.mainWorktree else { return false }
        return !service.isBusy(main)
    }
}
