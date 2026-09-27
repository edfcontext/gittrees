import GitTreesCore
import SwiftUI

struct BranchAssistView: View {
    @Environment(RepositoryService.self) private var service
    let worktree: Worktree
    let branch: Branch

    @State private var assessment: BranchAssessment?
    @State private var error: String?
    @State private var explanation: String?
    @State private var isLoading = false
    @State private var isApplying = false
    @State private var explainRequested = false
    @State private var revision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Git Assist").font(.callout.weight(.semibold))
            if isLoading {
                HStack { ProgressView().controlSize(.small); Text("Checking branch history…").font(.caption) }
            }
            if let assessment {
                Text(assessment.summary).font(.callout).fixedSize(horizontal: false, vertical: true)
                if let blocker = assessment.blocker {
                    Text(blocker).font(.caption).foregroundStyle(.orange)
                }
                if assessment.relationship == .fastForward {
                    Button("Fast-Forward \(assessment.currentName) to \(assessment.otherName)") {
                        isApplying = true
                        Task {
                            defer { isApplying = false }
                            do { try await service.fastForward(assessment); revision += 1 }
                            catch { self.error = error.localizedDescription; self.assessment = nil }
                        }
                    }
                    .disabled(!assessment.canFastForward || isApplying || isLoading || service.isBusy(worktree))
                }
                Button(explainRequested ? "Explaining…" : "Explain with Apple Intelligence") {
                    explainRequested = true
                }
                .font(.caption)
                .disabled(explainRequested || isApplying || isLoading)
            }
            if let explanation {
                Text("Apple Intelligence · On-device").font(.caption2).foregroundStyle(.secondary)
                Text(explanation).font(.caption).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Recheck") { revision += 1 }
                if branch.kind == .remote {
                    Button("Fetch & Recheck") {
                        isApplying = true
                        Task {
                            defer { isApplying = false }
                            do {
                                try await service.fetchForAssist(worktree: worktree, branch: branch)
                                revision += 1
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                }
            }
            .font(.caption)
            .disabled(isLoading || isApplying || service.isBusy(worktree))
            if branch.kind == .remote {
                Text("Based on locally known remote history. Fetch to check for newer commits.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .task(id: "\(worktree.head ?? "")|\(branch.refName)|\(branch.objectName)|\(revision)") {
            isLoading = true; assessment = nil; explanation = nil; error = nil; explainRequested = false
            defer { isLoading = false }
            do {
                let result = try await service.assessBranches(worktree: worktree, otherRef: branch.refName)
                try Task.checkCancellation()
                assessment = result
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
        .task(id: explainRequested) {
            guard explainRequested, let current = assessment else { return }
            defer { explainRequested = false }
            do {
                let result = try await AppleIntelligenceGitAssistant.explain(current)
                try Task.checkCancellation()
                if assessment == current { explanation = result }
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}
