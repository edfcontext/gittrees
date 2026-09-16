import Foundation
import os

/// App-facing commit suggestion. Tries the bundled Core ML classifier first; if it
/// is missing, fails, or is below the confidence gate, falls back to
/// `CommitMessageDrafter`.
///
/// `suggest(stagedChanges:stagedDiff:)` is the Swift equivalent of
/// `CommitModel.predict(staged_diff)`.
public final class CommitDescriptionService: @unchecked Sendable {
    public static let shared = CommitDescriptionService()

    public static let confidenceThreshold = 0.50

    private static let log = Logger(subsystem: "local.gittrees.app", category: "commit-model")

    private let lock = NSLock()
    private var predictor: CommitIntentPredictor?
    private var loadAttempted = false
    private var loadError: String?

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
        guard !stagedChanges.isEmpty else {
            return annotated(heuristic, "Nothing staged — stage files to get a suggestion.")
        }
        guard !stagedDiff.isEmpty else {
            return annotated(heuristic, "Git produced no staged diff — using file names.")
        }

        switch loadResult() {
        case .failure(let reason):
            return annotated(heuristic, "Model unavailable (\(reason)) — using file names.")
        case .success(let predictor):
            do {
                let prediction = try predictor.predict(
                    stagedDiff: stagedDiff,
                    files: stagedChanges.map(\.path)
                )
                let percent = Int((prediction.confidence * 100).rounded())
                let need = Int((predictor.threshold * 100).rounded())
                if prediction.confidence >= predictor.threshold {
                    var accepted = prediction
                    accepted.diagnostic = "Model · \(percent)%"
                    Self.log.info("Using model suggestion “\(accepted.message, privacy: .public)” at \(percent)%")
                    print("[GitTrees] commit model: \(accepted.diagnostic) → \(accepted.message)")
                    return accepted
                }
                let skipped = annotated(
                    heuristic,
                    "Model \(percent)% (need \(need)%): “\(prediction.message)” — using file names."
                )
                var result = skipped
                result.intent = prediction.intent
                result.confidence = prediction.confidence
                result.confidencePerHead = prediction.confidencePerHead
                Self.log.info("\(result.diagnostic, privacy: .public)")
                print("[GitTrees] commit model: \(result.diagnostic)")
                return result
            } catch {
                return annotated(heuristic, "Model failed (\(error.localizedDescription)) — using file names.")
            }
        }
    }

    private func annotated(_ suggestion: CommitSuggestion, _ diagnostic: String) -> CommitSuggestion {
        var copy = suggestion
        copy.diagnostic = diagnostic
        Self.log.info("\(diagnostic, privacy: .public)")
        print("[GitTrees] commit model: \(diagnostic)")
        return copy
    }

    private enum LoadResult {
        case success(CommitIntentPredictor)
        case failure(String)
    }

    private func loadResult() -> LoadResult {
        lock.lock()
        defer { lock.unlock() }
        if let predictor { return .success(predictor) }
        if loadAttempted {
            return .failure(loadError ?? "not loaded")
        }
        loadAttempted = true

        let directory = CommitIntentResources.directory
        let modelURL = CommitIntentResources.mlpackage
        let tokenizerURL = CommitIntentResources.tokenizer
        guard let modelURL, let tokenizerURL else {
            let reason = "bundle missing (dir: \(directory?.path ?? "nil"))"
            loadError = reason
            return .failure(reason)
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            let reason = "no mlpackage at \(modelURL.path)"
            loadError = reason
            return .failure(reason)
        }
        guard FileManager.default.fileExists(atPath: tokenizerURL.path) else {
            let reason = "no tokenizer at \(tokenizerURL.path)"
            loadError = reason
            return .failure(reason)
        }

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

        do {
            let loaded = try CommitIntentPredictor(
                modelURL: modelURL,
                tokenizerURL: tokenizerURL,
                schema: schema,
                manifest: manifest
            )
            predictor = loaded
            loadError = nil
            Self.log.info("Loaded commit model from \(modelURL.path, privacy: .public)")
            print("[GitTrees] commit model: loaded \(modelURL.path)")
            return .success(loaded)
        } catch {
            let reason = error.localizedDescription
            loadError = reason
            Self.log.error("Failed to load commit model: \(reason, privacy: .public)")
            print("[GitTrees] commit model: load failed — \(reason)")
            return .failure(reason)
        }
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
