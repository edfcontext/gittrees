import GitTreesCore
import SwiftUI

/// The sidebar: repository header, worktrees, branches, and the New Worktree action.
struct RepositorySidebar: View {
    @Environment(RepositoryService.self) private var service
    @Environment(WorkspaceLauncher.self) private var launcher

    @Binding var selection: SidebarItem?
    let onNewWorktree: () -> Void
    let onNewWorkspace: () -> Void
    let onOpenRepository: () -> Void
    let onRequestRemoval: (Worktree) -> Void
    let onRequestLock: (Worktree) -> Void
    @State private var branchToDelete: Branch?

    var body: some View {
        VStack(spacing: 0) {
            header

            List(selection: $selection) {
                if service.repository != nil {
                    Section {
                        Label("Graph", systemImage: "point.3.connected.trianglepath.dotted")
                            .tag(SidebarItem.graph)
                    }
                }
                WorktreeList(
                    selection: $selection,
                    onRequestRemoval: onRequestRemoval,
                    onRequestLock: onRequestLock
                )

                BranchList(selection: $selection, onCreateWorktree: onNewWorktree,
                           onDeleteBranch: { branchToDelete = $0 })
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 22)

            pruneFooter
        }
        .sheet(item: $branchToDelete) { branch in
            DeleteBranchSheet(branch: branch) {
                if selection == .branch(branch.refName) {
                    selection = service.selectedWorktreePath.map(SidebarItem.worktree)
                }
            }
        }
        .onChange(of: service.repository?.id) { _, _ in branchToDelete = nil }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: "shippingbox")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(service.repository?.name ?? "No Repository")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.head)

                Spacer(minLength: 0)

                if service.isRefreshing {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                }
            }

            if let repository = service.repository {
                Text(Self.abbreviate(repository.mainWorktreePath))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(repository.mainWorktreePath.path)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            Button("New Repository…", action: onNewWorkspace)
            Button("Open Repository…", action: onOpenRepository)
            if let repository = service.repository {
                Button("New Worktree…", action: onNewWorktree)
                Divider()
                Button("Reveal in Finder") {
                    launcher.reveal(repository.mainWorktreePath)
                }
                Divider()
                Button("Close Repository") { service.closeRepository() }
            }
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var pruneFooter: some View {
        if service.worktrees.contains(where: { $0.isPrunable || $0.isMissingOnDisk }) {
            VStack(spacing: 0) {
                Divider()
                Button {
                    Task { await service.pruneWorktrees() }
                } label: {
                    Label("Prune", systemImage: "wand.and.rays")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Remove stale worktree metadata")
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
    }

    /// `/Users/me/Development/summit` -> `~/Development/summit`.
    static func abbreviate(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}
