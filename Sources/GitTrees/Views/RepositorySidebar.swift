import GitTreesCore
import SwiftUI

/// The sidebar: repository header, worktrees, branches, and the New Worktree action.
struct RepositorySidebar: View {
    @Environment(RepositoryService.self) private var service
    @Environment(WorkspaceLauncher.self) private var launcher

    @Binding var selection: SidebarItem?
    let onNewWorktree: () -> Void
    let onOpenRepository: () -> Void
    let onRequestRemoval: (Worktree) -> Void
    let onRequestLock: (Worktree) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            List(selection: $selection) {
                WorktreeList(
                    selection: $selection,
                    onRequestRemoval: onRequestRemoval,
                    onRequestLock: onRequestLock
                )

                BranchList(selection: $selection, onCreateWorktree: onNewWorktree)
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 22)

            footer
        }
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
            Button("Open Repository…", action: onOpenRepository)
            if let repository = service.repository {
                Button("Reveal in Finder") {
                    launcher.reveal(repository.mainWorktreePath)
                }
                Divider()
                Button("Close Repository") { service.closeRepository() }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                Button(action: onNewWorktree) {
                    Label("New Worktree", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(service.repository == nil)
                .help("Create a worktree (⌘N)")

                Spacer(minLength: 0)

                if service.worktrees.contains(where: { $0.isPrunable || $0.isMissingOnDisk }) {
                    Button {
                        Task { await service.pruneWorktrees() }
                    } label: {
                        Label("Prune", systemImage: "wand.and.rays")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Remove stale worktree metadata")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    /// `/Users/me/Development/summit` -> `~/Development/summit`.
    static func abbreviate(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}
