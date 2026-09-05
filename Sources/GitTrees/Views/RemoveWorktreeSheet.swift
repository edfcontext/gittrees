import GitTreesCore
import SwiftUI

/// Confirms removing a worktree.
///
/// A dirty worktree is never removed by default: the sheet lists what Git reports and
/// makes the user opt in to `--force` explicitly, behind a second confirmation.
struct RemoveWorktreeSheet: View {
    @Environment(RepositoryService.self) private var service
    @Environment(\.dismiss) private var dismiss

    let removal: WorktreeRemoval

    @State private var forceAcknowledged = false
    @State private var isRemoving = false

    private var worktree: Worktree { removal.worktree }
    private var isDirty: Bool { removal.blockingChanges != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isDirty ? "exclamationmark.triangle.fill" : "trash")
                    .font(.title2)
                    .foregroundStyle(isDirty ? Color.orange : Color.secondary)

                VStack(alignment: .leading, spacing: 3) {
                    Text(isDirty ? "Cannot Remove Worktree" : "Remove Worktree")
                        .font(.headline)

                    Text(worktree.branchName ?? worktree.displayName)
                        .font(.callout.weight(.medium))

                    Text(worktree.path.path)
                        .font(GitTreesUI.monospaced)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if let blocking = removal.blockingChanges {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(worktree.branchName ?? worktree.displayName) contains:")
                        .font(.callout)

                    ForEach(blocking.dirtySummary, id: \.self) { line in
                        Label(line, systemImage: "circle.fill")
                            .font(.caption)
                            .labelStyle(BulletLabelStyle())
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panelChrome()

                Toggle(isOn: $forceAcknowledged) {
                    Text("Discard these changes and remove the worktree anyway")
                        .font(.caption)
                }
                .toggleStyle(.checkbox)
            } else {
                Text(worktree.isLocked
                     ? "This worktree is locked. Unlock it before removing it."
                     : "The worktree directory will be deleted. The branch itself is not touched.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                if isRemoving {
                    ProgressView().controlSize(.small)
                }

                Spacer(minLength: 0)

                if isDirty {
                    Button("View Changes") {
                        service.selectedWorktreePath = worktree.id
                        dismiss()
                    }
                }

                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)

                // Force removal is never the default button: it must be clicked.
                if isDirty {
                    Button("Force Remove", role: .destructive) { remove() }
                        .disabled(isRemoving || worktree.isLocked || !forceAcknowledged)
                } else {
                    Button("Remove", role: .destructive) { remove() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isRemoving || worktree.isLocked)
                }
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    private func remove() {
        isRemoving = true
        Task {
            let removed = await service.removeWorktree(worktree, force: isDirty)
            isRemoving = false
            if removed { dismiss() }
        }
    }
}

/// A bullet list item; `Label` with a tiny dot instead of a full-size symbol.
struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon
                .font(.system(size: 4))
                .foregroundStyle(.secondary)
            configuration.title
        }
    }
}

/// Locks a worktree, optionally recording why.
struct LockWorktreeSheet: View {
    @Environment(RepositoryService.self) private var service
    @Environment(\.dismiss) private var dismiss

    let worktree: Worktree

    @State private var reason = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Lock Worktree")
                    .font(.headline)
                Text(worktree.path.path)
                    .font(GitTreesUI.monospaced)
                    .foregroundStyle(.secondary)
            }

            Text("Locking prevents Git from pruning this worktree automatically — useful when it lives on a removable or network volume.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Reason (optional)", text: $reason)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Lock") {
                    Task {
                        await service.setLock(true, on: worktree, reason: reason)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}
