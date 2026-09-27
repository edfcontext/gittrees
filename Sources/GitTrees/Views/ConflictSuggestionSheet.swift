import GitTreesCore
import SwiftUI

struct ConflictSuggestionSheet: View {
    @Environment(RepositoryService.self) private var service
    @Environment(\.dismiss) private var dismiss
    let worktree: Worktree
    let path: String

    @State private var proposal: ConflictProposal?
    @State private var error: String?
    @State private var isGenerating = false
    @State private var isApplying = false
    @State private var request = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review Conflict Suggestion").font(.headline)
            Text(path).font(.callout.monospaced()).textSelection(.enabled)
            Text("Experimental · Apple Intelligence · On-device. Review the suggested code before applying; it has not been tested.")
                .font(.caption).foregroundStyle(.secondary)
            if isGenerating {
                HStack { ProgressView().controlSize(.small); Text("Reading both versions and their common ancestor…") }
            }
            if let error {
                Text(error).foregroundStyle(.orange).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let proposal {
                Text(proposal.explanation).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                DiffTextView(diff: proposal.diff)
                    .frame(minHeight: 260)
                    .background(GitTreesUI.editorBackground)
                Text("Apply & Stage updates this file only. Commit or Continue Rebase remains a separate step.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Spacer(minLength: 30)
            }
            HStack {
                if !isGenerating {
                    Button("Try Again") { request += 1 }.disabled(isApplying)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(isApplying)
                Button("Apply & Stage") {
                    guard let proposal else { return }
                    isApplying = true
                    Task {
                        defer { isApplying = false }
                        do { try await service.applyConflictProposal(proposal); dismiss() }
                        catch { self.error = error.localizedDescription; self.proposal = nil }
                    }
                }
                .disabled(proposal == nil || isGenerating || isApplying || service.isBusy(worktree)
                    || service.selectedWorktree?.id != worktree.id)
            }
        }
        .padding(20)
        .frame(width: 760, height: 560)
        .interactiveDismissDisabled(isApplying)
        .task(id: request) {
            isGenerating = true; proposal = nil; error = nil
            defer { isGenerating = false }
            do {
                let result = try await service.suggestConflictResolution(worktree: worktree, path: path)
                try Task.checkCancellation()
                proposal = result
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}
