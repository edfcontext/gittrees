import GitTreesCore
import SwiftUI

/// Keeps the branch being changed visible while choosing the operation and other branch.
struct BranchIntegrationSheet: View {
    @Environment(RepositoryService.self) private var service
    @Environment(\.dismiss) private var dismiss

    let worktree: Worktree

    @State private var rebase = false
    @State private var selectedRef = ""

    private var currentName: String { worktree.branchName ?? worktree.displayName }
    private var selectedBranch: Branch? {
        service.mergeCandidates.first { $0.refName == selectedRef }
    }
    private var matchesSelection: Bool {
        service.selectedWorktree?.id == worktree.id
            && service.selectedWorktree?.branchRef == worktree.branchRef
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Merge or Rebase").font(.headline)

            LabeledContent("Branch to update") {
                Text(currentName).font(.body.monospaced()).textSelection(.enabled)
            }
            Text(worktree.path.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Picker("Operation", selection: $rebase) {
                Text("Merge").tag(false)
                Text("Rebase").tag(true)
            }
            .pickerStyle(.segmented)

            Picker(rebase ? "Onto branch" : "Merge from", selection: $selectedRef) {
                Text("Choose a branch…").tag("")
                ForEach(service.mergeCandidates) { branch in
                    Text(branch.name).tag(branch.refName)
                }
            }

            if let branch = selectedBranch {
                BranchAssistView(worktree: worktree, branch: branch)
                    .id(branch.refName)

                Text(rebase
                    ? "Rebase \(currentName) onto \(branch.name)"
                    : "Merge \(branch.name) into \(currentName)")
                    .font(.callout.weight(.semibold))
                    .textSelection(.enabled)
            }

            Text(rebase
                ? "Replay this branch’s commits on top of the chosen branch. Replayed commits get new IDs. If they were already pushed, you may need Force Push (With Lease)."
                : "Bring the chosen branch’s commits into this branch. Existing commits keep their IDs; Git may fast-forward or create a merge commit.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if rebase && !service.status.isClean {
                Text("Commit or stash local changes before rebasing.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text("Conflicts appear in Changes, where you can resolve them or abort.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(rebase ? "Rebase \(currentName)" : "Merge into \(currentName)") {
                    guard matchesSelection, let branch = selectedBranch else { return }
                    let shouldRebase = rebase
                    Task {
                        guard matchesSelection else { return }
                        if shouldRebase {
                            await service.rebase(onto: branch)
                        } else {
                            await service.merge(branch)
                        }
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedBranch == nil || !matchesSelection
                    || service.activeOperation != nil || service.isBusy(worktree)
                    || !(rebase ? service.canRebase : service.canMerge))
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            if let upstream = service.branch(for: worktree)?.upstreamRef,
               service.mergeCandidates.contains(where: { $0.refName == upstream }) {
                selectedRef = upstream
            }
        }
    }
}
