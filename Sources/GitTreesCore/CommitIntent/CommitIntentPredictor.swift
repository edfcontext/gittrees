import CoreML
import Foundation

/// Core ML multi-head classifier: tokens in, `{type, action, scope}` logits out.
public final class CommitIntentPredictor: @unchecked Sendable {
    public let schema: LabelSchema
    public let manifest: CommitIntentManifest
    public let threshold: Double

    private let model: MLModel
    private let tokenizer: BertWordPieceTokenizer

    public init(
        modelURL: URL,
        tokenizerURL: URL,
        schema: LabelSchema = .bundled,
        manifest: CommitIntentManifest = .bundled
    ) throws {
        self.schema = schema
        self.manifest = manifest
        self.threshold = manifest.confidenceThreshold
        self.tokenizer = try BertWordPieceTokenizer(tokenizerJSON: tokenizerURL, maxTokens: manifest.maxTokens)
        let compiled = try MLModel.compileModel(at: modelURL)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        self.model = try MLModel(contentsOf: compiled, configuration: configuration)
    }

    /// Steps 1–5 of the Python predictor, minus Git.
    public func predict(stagedDiff: String, files: [String]) throws -> CommitSuggestion {
        let text = DiffNormalizer.normalize(stagedDiff)
        let encoded = tokenizer.encode(text)
        let logits = try infer(ids: encoded.ids, mask: encoded.mask)

        var intentLabels: [String: String] = [:]
        var confs: [String: Double] = [:]
        for head in schema.headNames {
            guard let raw = logits[head] else {
                throw PredictorError.missingOutput(head)
            }
            let probs = softmax(raw)
            let index = argmax(probs)
            intentLabels[head] = schema.label(head: head, at: index) ?? ""
            confs[head] = Double(probs[index])
        }
        let intent = CommitIntent(
            type: intentLabels["type"] ?? "REFACTOR",
            action: intentLabels["action"] ?? "UPDATE",
            scope: intentLabels["scope"] ?? "GENERAL"
        )
        let confidence = confs.values.reduce(0, +) / Double(max(confs.count, 1))
        let object = CommitObjectInferrer.infer(diff: stagedDiff, files: files)
        return CommitSuggestion(
            message: CommitMessageRenderer.render(intent, object: object, style: .plain),
            intent: intent,
            confidence: confidence,
            confidencePerHead: confs,
            source: .model,
            belowThreshold: confidence < threshold,
            diagnostic: ""
        )
    }

    private func infer(ids: [Int], mask: [Int]) throws -> [String: [Float]] {
        let inputIDs = try multiArray(ids)
        let attention = try multiArray(mask)
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: inputIDs),
            "attention_mask": MLFeatureValue(multiArray: attention)
        ])
        let out = try model.prediction(from: provider)
        var logits: [String: [Float]] = [:]
        for head in schema.headNames {
            let names = ["\(head)_logits", head]
            let array = names.compactMap { out.featureValue(for: $0)?.multiArrayValue }.first
                ?? matchingOutput(out, containing: head)
            guard let array else { continue }
            logits[head] = floats(from: array)
        }
        if logits.count != schema.headNames.count {
            // Conversion sometimes names tuple outputs var_N. Map in head order.
            let leftover = out.featureNames
                .compactMap { out.featureValue(for: $0)?.multiArrayValue }
            if leftover.count >= schema.headNames.count {
                for (head, array) in zip(schema.headNames, leftover) where logits[head] == nil {
                    logits[head] = floats(from: array)
                }
            }
        }
        return logits
    }

    private func matchingOutput(_ out: MLFeatureProvider, containing needle: String) -> MLMultiArray? {
        out.featureNames
            .first { $0.lowercased().contains(needle.lowercased()) }
            .flatMap { out.featureValue(for: $0)?.multiArrayValue }
    }

    private func multiArray(_ values: [Int]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, NSNumber(value: values.count)], dataType: .int32)
        for (i, value) in values.enumerated() {
            array[i] = NSNumber(value: Int32(value))
        }
        return array
    }

    private func floats(from array: MLMultiArray) -> [Float] {
        (0..<array.count).map { array[$0].floatValue }
    }

    private func softmax(_ logits: [Float]) -> [Float] {
        guard let maxVal = logits.max() else { return [] }
        let exps = logits.map { exp($0 - maxVal) }
        let sum = exps.reduce(0, +)
        return exps.map { $0 / sum }
    }

    private func argmax(_ values: [Float]) -> Int {
        var best = 0
        for i in values.indices where values[i] > values[best] {
            best = i
        }
        return best
    }

    public enum PredictorError: LocalizedError {
        case missingOutput(String)

        public var errorDescription: String? {
            switch self {
            case .missingOutput(let head): "missing \(head) logits"
            }
        }
    }
}

/// Bundle URLs for the converted Core ML package and its sidecars.
public enum CommitIntentResources {
    public static var directory: URL? {
        let candidates: [URL] = {
            var urls: [URL] = []
            if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
                urls.append(exeDir.appendingPathComponent("GitTrees_GitTreesCore.bundle").appendingPathComponent("CommitIntentModel"))
                urls.append(exeDir.appendingPathComponent("CommitIntentModel"))
            }
            if let resources = Bundle.main.resourceURL {
                urls.append(resources.appendingPathComponent("CommitIntentModel"))
                urls.append(resources.appendingPathComponent("GitTrees_GitTreesCore.bundle").appendingPathComponent("CommitIntentModel"))
            }
            urls.append(Bundle.main.bundleURL.appendingPathComponent("GitTrees_GitTreesCore.bundle").appendingPathComponent("CommitIntentModel"))
            return urls
        }()
        for url in candidates {
            let tokenizer = url.appendingPathComponent("tokenizer.json")
            if FileManager.default.fileExists(atPath: tokenizer.path) {
                return url
            }
        }
        return Bundle.module.url(forResource: "CommitIntentModel", withExtension: nil)
    }

    public static var mlpackage: URL? {
        directory?.appendingPathComponent("CommitIntent.mlpackage")
    }

    public static var tokenizer: URL? {
        directory?.appendingPathComponent("tokenizer.json")
    }

    public static var labels: URL? {
        directory?.appendingPathComponent("labels.json")
    }

    public static var manifest: URL? {
        directory?.appendingPathComponent("manifest.json")
    }
}
