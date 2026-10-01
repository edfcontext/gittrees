import Foundation

/// Prefers Apple Intelligence and falls back to a deterministic filename summary.
public final class CommitDescriptionService: @unchecked Sendable {
    public static let shared = CommitDescriptionService()

    typealias AppleDraft = @Sendable ([FileChange], String) async throws -> String
    private let appleDraft: AppleDraft

    public init() {
        appleDraft = AppleIntelligenceCommitDrafter.draft
    }

    init(appleDraft: @escaping AppleDraft) {
        self.appleDraft = appleDraft
    }

    /// A local, editable subject. Availability and generation failures retain a useful
    /// filename summary on older or ineligible Macs.
    public func suggest(stagedChanges: [FileChange], stagedDiff: String) async -> CommitSuggestion {
        guard !stagedChanges.isEmpty, !stagedDiff.isEmpty else {
            return suggestNow(stagedChanges: stagedChanges, stagedDiff: stagedDiff)
        }
        let reason: String
        do {
            try Task.checkCancellation()
            let generated = try await appleDraft(stagedChanges, stagedDiff)
            try Task.checkCancellation()
            let subject = try AppleIntelligenceCommitDrafter.validatedSubject(generated)
            return CommitSuggestion(
                message: subject,
                source: .appleIntelligence,
                diagnostic: "Apple Intelligence · On-device"
            )
        } catch is CancellationError {
            return annotated(heuristicSuggestion(for: []), "Suggestion cancelled.")
        } catch AppleIntelligenceCommitDrafter.Failure.unavailable(let explanation) {
            reason = "Apple Intelligence unavailable: \(explanation)."
        } catch {
            // Do not expose errors that might contain the prompt or repository content.
            reason = "Apple Intelligence could not produce a usable subject."
        }
        guard !Task.isCancelled else { return heuristicSuggestion(for: []) }
        var fallback = suggestNow(stagedChanges: stagedChanges, stagedDiff: stagedDiff)
        fallback.diagnostic = "\(reason) \(fallback.diagnostic)"
        return fallback
    }

    /// Just the string the commit box should show.
    public func suggestedMessage(stagedChanges: [FileChange], stagedDiff: String) async -> String {
        await suggest(stagedChanges: stagedChanges, stagedDiff: stagedDiff).message
    }

    func suggestNow(stagedChanges: [FileChange], stagedDiff: String) -> CommitSuggestion {
        let heuristic = heuristicSuggestion(for: stagedChanges)
        guard !stagedChanges.isEmpty else {
            return annotated(heuristic, "Nothing staged — stage files to get a suggestion.")
        }
        guard !stagedDiff.isEmpty else {
            return annotated(heuristic, "Git produced no staged diff — using file names.")
        }

        return annotated(heuristic, "Filename summary · Local fallback")
    }

    private func annotated(_ suggestion: CommitSuggestion, _ diagnostic: String) -> CommitSuggestion {
        var copy = suggestion
        copy.diagnostic = diagnostic
        return copy
    }

    private func heuristicSuggestion(for changes: [FileChange]) -> CommitSuggestion {
        CommitSuggestion(
            message: CommitMessageDrafter.draft(for: changes),
            source: .heuristic
        )
    }
}
