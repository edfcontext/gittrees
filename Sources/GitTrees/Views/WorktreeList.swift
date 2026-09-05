import GitTreesCore
import SwiftUI

/// The WORKTREES section: every worktree of the repository, with its branch, path,
/// dirty state, and the lock/prune conditions Git reports.
struct WorktreeList: View {
    @Environment(RepositoryService.self) private var service

    @Binding var selection: SidebarItem?
    let onRequestRemoval: (Worktree) -> Void
    let onRequestLock: (Worktree) -> Void

    var body: some View {
        Section {
            ForEach(service.worktrees) { worktree in
                WorktreeRow(worktree: worktree)
                    .tag(SidebarItem.worktree(worktree.id))
                    .contextMenu {
                        WorktreeContextMenu(
                            worktree: worktree,
                            onRequestRemoval: onRequestRemoval,
                            onRequestLock: onRequestLock
                        )
                    }
            }
        } header: {
            SectionHeaderLabel(title: "Worktrees", count: service.worktrees.count)
        }
    }
}

/// One dense worktree row: indicator, branch, path, and state badges.
struct WorktreeRow: View {
    @Environment(RepositoryService.self) private var service

    let worktree: Worktree

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            WorktreeIndicator(state: indicatorState)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(worktree.displayName)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if worktree.isMain {
                        BadgeLabel(text: "main", tint: .secondary)
                    }
                    if worktree.isLocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                            .help(worktree.lockReason.map { "Locked: \($0)" } ?? "Locked")
                    }
                    if worktree.isDetached {
                        BadgeLabel(text: "detached", tint: .orange)
                    }
                }

                Text(RepositorySidebar.abbreviate(worktree.path))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)

                if let staleNote {
                    Text(staleNote)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if service.isBusy(worktree) {
                ProgressView().controlSize(.small).scaleEffect(0.55)
            }
        }
        .padding(.vertical, 1)
        .help(worktree.path.path)
    }

    private var indicatorState: WorktreeIndicator.State {
        if worktree.isPrunable || worktree.isMissingOnDisk { return .stale }
        switch service.isDirty(worktree) {
        case .some(true): return .dirty
        case .some(false): return .clean
        case nil: return .unknown
        }
    }

    /// Git's own reason is shown rather than a generic message, because "gitdir file
    /// points to non-existent location" tells the user exactly what to fix.
    private var staleNote: String? {
        if let reason = worktree.prunableReason { return "Prunable — \(reason)" }
        if worktree.isMissingOnDisk { return "Directory is missing" }
        return nil
    }
}

/// The worktree actions, shared by the sidebar context menu and the detail view.
struct WorktreeContextMenu: View {
    @Environment(RepositoryService.self) private var service
    @Environment(WorkspaceLauncher.self) private var launcher

    let worktree: Worktree
    let onRequestRemoval: (Worktree) -> Void
    let onRequestLock: (Worktree) -> Void

    var body: some View {
        ForEach(launcher.installedEditors()) { editor in
            Button("Open in \(editor.displayName)") { open(in: editor) }
        }
        Button("Open Terminal Here") { open(in: .terminal) }
        Button("Reveal in Finder") { launcher.reveal(worktree.path) }

        if worktree.isMain, !worktree.isBare, !worktree.isMissingOnDisk {
            Divider()
            Menu("Switch Branch") {
                SwitchBranchMenuContent(worktree: worktree)
            }
            .disabled(service.isBusy(worktree))
        }

        Divider()

        Button("Fetch") { run { await service.fetch() } }
        Button("Pull") { run { await service.pull() } }
        Button("Push") { run { await service.push(setUpstream: service.selectedBranchNeedsUpstream) } }

        Divider()

        if worktree.isLocked {
            Button("Unlock Worktree") {
                Task { await service.setLock(false, on: worktree) }
            }
        } else {
            Button("Lock Worktree…") { onRequestLock(worktree) }
        }

        Button("Remove Worktree…") { onRequestRemoval(worktree) }
            .disabled(worktree.isMain)
    }

    /// Remote actions apply to the selected worktree, so select this one first.
    private func run(_ operation: @escaping () async -> Void) {
        service.selectedWorktreePath = worktree.id
        Task { await operation() }
    }

    private func open(in application: WorkspaceApplication) {
        Task {
            do {
                try await launcher.open(worktree.path, in: application)
            } catch {
                service.lastError = PresentableError(title: "Could Not Open Worktree", error: error)
            }
        }
    }
}

/// Local branches offered as `git checkout` targets for one worktree.
///
/// The current branch is marked; a branch already live in another worktree is
/// disabled, matching Git's own rule.
struct SwitchBranchMenuContent: View {
    @Environment(RepositoryService.self) private var service

    let worktree: Worktree

    var body: some View {
        ForEach(service.localBranches) { branch in
            let isCurrent = branch.refName == worktree.branchRef
            Button {
                Task { await service.checkout(branch: branch, in: worktree) }
            } label: {
                if isCurrent {
                    Label(branch.name, systemImage: "checkmark")
                } else {
                    Text(branch.name)
                }
            }
            .disabled(isCurrent || service.isCheckedOutElsewhere(branch, from: worktree))
        }
    }
}

/// A small uppercase pill, e.g. `main` or `detached`.
struct BadgeLabel: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(tint)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
    }
}
