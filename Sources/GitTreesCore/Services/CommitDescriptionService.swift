import Foundation

/// App-facing commit suggestion. Tries the bundled Core ML classifier first; if it
/// is missing, fails, or is below the confidence gate, falls back to
/// `CommitMessageDrafter`.
///
/// `suggest(stagedChanges:stagedDiff:)` is the Swift equivalent of
/// `CommitModel.predict(staged_diff)`.
public final class CommitDescriptionService: @unchecked Sendable {
    public static let shared = CommitDescriptionService()

    public static let confidenceThreshold = 0.80

    private let lock = NSLock()
    private var predictor: CommitIntentPredictor?
    private var loadAttempted = false

    public init() {}

    /// A subject to put in the commit box: the model when it is at least
    /// `confidenceThreshold` confident, otherwise the heuristic drafter.
    public func suggest(stagedChanges: [FileChange], stagedDiff: String) async -> CommitSuggestion {
        await Task.detached(priority: .userInitiated) {
            self.suggestNow(stagedChanges: stagedChanges, stagedDiff: stagedDiff)
        }.value
    }

    /// Just the string the commit box should show.
    public func suggestedMessage(stagedChanges: [FileChange], stagedDiff: String) async -> String {
        await suggest(stagedChanges: stagedChanges, stagedDiff: stagedDiff).message
    }

    func suggestNow(stagedChanges: [FileChange], stagedDiff: String) -> CommitSuggestion {
        let heuristic = heuristicSuggestion(for: stagedChanges)
        guard !stagedDiff.isEmpty else { return heuristic }
        guard let predictor = loadedPredictor() else { return heuristic }
        do {
            let prediction = try predictor.predict(
                stagedDiff: stagedDiff,
                files: stagedChanges.map(\.path)
            )
            if prediction.confidence >= predictor.threshold && !prediction.belowThreshold {
                return prediction
            }
            return CommitSuggestion(
                message: heuristic.message,
                intent: prediction.intent,
                confidence: prediction.confidence,
                confidencePerHead: prediction.confidencePerHead,
                source: .heuristic,
                belowThreshold: true
            )
        } catch {
            return heuristic
        }
    }

    private func loadedPredictor() -> CommitIntentPredictor? {
        lock.lock()
        defer { lock.unlock() }
        if loadAttempted { return predictor }
        loadAttempted = true
        guard let modelURL = CommitIntentResources.mlpackage,
              let tokenizerURL = CommitIntentResources.tokenizer,
              FileManager.default.fileExists(atPath: modelURL.path),
              FileManager.default.fileExists(atPath: tokenizerURL.path)
        else { return nil }
        let schema: LabelSchema
        if let labels = CommitIntentResources.labels {
            schema = (try? LabelSchema.load(from: labels)) ?? .bundled
        } else {
            schema = .bundled
        }
        let manifest: CommitIntentManifest
        if let url = CommitIntentResources.manifest {
            manifest = (try? CommitIntentManifest.load(from: url)) ?? .bundled
        } else {
            manifest = .bundled
        }
        predictor = try? CommitIntentPredictor(
            modelURL: modelURL,
            tokenizerURL: tokenizerURL,
            schema: schema,
            manifest: manifest
        )
        return predictor
    }

    private func heuristicSuggestion(for changes: [FileChange]) -> CommitSuggestion {
        CommitSuggestion(
            message: CommitMessageDrafter.draft(for: changes),
            intent: CommitIntent(type: "REFACTOR", action: "UPDATE", scope: "GENERAL"),
            confidence: 0,
            source: .heuristic,
            belowThreshold: true
        )
    }
}
