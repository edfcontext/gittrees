import GitTreesCore
import SwiftUI

/// What Git knows about the branch checked out in the selected worktree, and which
/// other branches are live elsewhere.
struct BranchInfoView: View {
    @Environment(RepositoryService.self) private var service

    let worktree: Worktree

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                worktreeSection
                branchSection
                otherWorktreesSection
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Sections

    private var worktreeSection: some View {
        InfoSection(title: "Worktree") {
            InfoRow(label: "Path", value: worktree.path.path, monospaced: true)
            InfoRow(label: "Type", value: worktree.isMain ? "Main worktree" : "Linked worktree")
            InfoRow(label: "HEAD", value: worktree.head ?? "—", monospaced: true)
            if worktree.isDetached {
                InfoRow(label: "State", value: "Detached HEAD")
            }
            InfoRow(label: "Locked", value: lockedValue)
            if let reason = worktree.prunableReason {
                InfoRow(label: "Prunable", value: reason)
            }
            InfoRow(label: "Working Tree", value: service.status.isClean ? "Clean" : dirtyValue)
        }
    }

    @ViewBuilder
    private var branchSection: some View {
        if let branch = service.branch(for: worktree) {
            InfoSection(title: "Branch") {
                InfoRow(label: "Name", value: branch.name)
                InfoRow(label: "Ref", value: branch.refName, monospaced: true)
                InfoRow(label: "Commit", value: branch.objectName, monospaced: true)
                InfoRow(label: "Upstream", value: branch.upstreamName ?? "None")
                if branch.hasUpstream {
                    InfoRow(label: "Ahead", value: "\(branch.ahead ?? 0)")
                    InfoRow(label: "Behind", value: "\(branch.behind ?? 0)")
                    if branch.upstreamIsGone {
                        InfoRow(label: "Note", value: "The upstream branch no longer exists.")
                    }
                }
            }
        } else {
            InfoSection(title: "Branch") {
                InfoRow(label: "State", value: "No branch is checked out in this worktree.")
            }
        }
    }

    /// Makes the branch-to-worktree mapping explicit, which is the relationship the
    /// whole application is organised around.
    @ViewBuilder
    private var otherWorktreesSection: some View {
        let others = service.worktrees.filter { $0.id != worktree.id && !$0.isBare }
        if !others.isEmpty {
            InfoSection(title: "Branches Checked Out Elsewhere") {
                ForEach(others) { other in
                    InfoRow(
                        label: other.branchName ?? other.displayName,
                        value: RepositorySidebar.abbreviate(other.path),
                        monospaced: true
                    )
                }
            }
        }
    }

    private var lockedValue: String {
        guard worktree.isLocked else { return "No" }
        return worktree.lockReason.map { "Yes — \($0)" } ?? "Yes"
    }

    private var dirtyValue: String {
        let summary = service.status.dirtySummary
        return summary.isEmpty ? "Modified" : summary.joined(separator: ", ")
    }
}

struct InfoSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionHeaderLabel(title: title)
            VStack(alignment: .leading, spacing: 3) {
                content
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panelChrome()
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)

            Text(value)
                .font(monospaced ? GitTreesUI.monospaced : .callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
