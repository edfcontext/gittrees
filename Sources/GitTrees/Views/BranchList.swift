import GitTreesCore
import SwiftUI

/// The BRANCHES section.
///
/// The filled indicator is the point of this list: it says at a glance which branches
/// are live in a worktree, and clicking one of those selects the worktree instead of
/// attempting a checkout Git would refuse.
struct BranchList: View {
    @Environment(RepositoryService.self) private var service
    @Environment(PreferencesService.self) private var preferences

    @Binding var selection: SidebarItem?
    let onCreateWorktree: () -> Void

    var body: some View {
        Section {
            ForEach(service.localBranches) { branch in
                BranchRow(branch: branch, worktree: service.worktree(for: branch))
                    .tag(SidebarItem.branch(branch.refName))
                    .contextMenu { menu(for: branch) }
            }
        } header: {
            SectionHeaderLabel(title: "Branches", count: service.localBranches.count)
        }

        if preferences.showRemoteBranches && !service.remoteBranches.isEmpty {
            Section {
                ForEach(service.remoteBranches) { branch in
                    BranchRow(branch: branch, worktree: nil)
                        .tag(SidebarItem.branch(branch.refName))
                        .contextMenu { remoteMenu(for: branch) }
                }
            } header: {
                SectionHeaderLabel(title: "Remote Branches", count: service.remoteBranches.count)
            }
        }
    }

    @ViewBuilder
    private func menu(for branch: Branch) -> some View {
        if let worktree = service.worktree(for: branch) {
            Button("Reveal Worktree") { selection = .worktree(worktree.id) }
            Text("Checked out in \(RepositorySidebar.abbreviate(worktree.path))")
        } else {
            Button("Create Worktree…") {
                selection = .branch(branch.refName)
                onCreateWorktree()
            }
            // This branch has no worktree, so a checkout here is the one Git allows.
            Button("Checkout in Current Worktree") {
                guard let current = service.selectedWorktree else { return }
                Task { await service.checkout(branch: branch, in: current) }
            }
            .disabled(service.selectedWorktree == nil)
        }
    }

    @ViewBuilder
    private func remoteMenu(for branch: Branch) -> some View {
        Button("Create Worktree…") {
            selection = .branch(branch.refName)
            onCreateWorktree()
        }
    }
}

struct BranchRow: View {
    let branch: Branch
    let worktree: Worktree?

    var body: some View {
        HStack(spacing: 5) {
            WorktreeIndicator(state: worktree == nil ? .inactive : .clean)

            Text(branch.name)
                .font(.callout)
                .foregroundStyle(worktree == nil ? Color.secondary : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            if branch.isCurrentHEAD {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .help("HEAD of the repository's main worktree")
            }

            Spacer(minLength: 0)

            if let summary = branch.trackingSummary {
                TrackingBadge(text: summary)
            }
        }
        .padding(.vertical, 1)
        .help(helpText)
    }

    private var helpText: String {
        var lines = [branch.refName]
        if let upstream = branch.upstreamName { lines.append("upstream: \(upstream)") }
        if let worktree { lines.append("worktree: \(worktree.path.path)") }
        return lines.joined(separator: "\n")
    }
}
