import GitTreesCore
import SwiftUI

struct DeleteBranchSheet: View {
    @Environment(RepositoryService.self) private var service
    @Environment(\.dismiss) private var dismiss

    let branch: Branch
    let onDeleted: () -> Void

    @State private var force = false
    @State private var isDeleting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete Local Branch").font(.headline)
            Text(branch.name).font(.callout.weight(.medium)).textSelection(.enabled)

            Text("Deletes this local branch. Its remote branch and worktree directories are kept. Git checks that the branch is fully merged before deleting it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let reason = service.branchDeletionBlocker(branch) {
                Text(reason).font(.caption).foregroundStyle(.orange)
            }

            Toggle("Delete even if not fully merged", isOn: $force)
                .toggleStyle(.checkbox)
            if force {
                Text("Commits unique to this branch may become unreachable. Only continue if you no longer need that work.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isDeleting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isDeleting)
                Button(force ? "Force Delete" : "Delete Branch", role: .destructive) {
                    isDeleting = true
                    Task {
                        let deleted = await service.deleteBranch(branch, force: force)
                        isDeleting = false
                        if deleted {
                            onDeleted()
                            dismiss()
                        }
                    }
                }
                .disabled(isDeleting || service.activeOperation != nil || service.branchDeletionBlocker(branch) != nil)
            }
        }
        .padding(16)
        .frame(width: 460)
        .interactiveDismissDisabled(isDeleting)
    }
}
