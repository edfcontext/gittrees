import Foundation
import Testing
@testable import GitTreesCore

@Suite("BertWordPieceTokenizer")
struct BertWordPieceTokenizerTests {
    @Test("token ids match Hugging Face on the demo normalized diff")
    func matchesHuggingFace() throws {
        let tokenizerURL = try #require(CommitIntentResources.tokenizer)
        let goldensURL = try #require(
            Bundle.module.url(forResource: "tokenizer_parity", withExtension: "json", subdirectory: "Fixtures")
        )
        let goldens = try JSONDecoder().decode(Parity.self, from: Data(contentsOf: goldensURL))
        let tokenizer = try BertWordPieceTokenizer(tokenizerJSON: tokenizerURL, maxTokens: 256)
        let encoded = tokenizer.encode(goldens.text)
        #expect(encoded.ids == goldens.inputIds)
        #expect(encoded.mask == goldens.attentionMask)
    }
}

@Suite("CommitIntentPredictor")
struct CommitIntentPredictorTests {
    @Test("Core ML argmax matches the conversion-time dump")
    func coreMLArgmax() throws {
        let modelURL = try #require(CommitIntentResources.mlpackage)
        let tokenizerURL = try #require(CommitIntentResources.tokenizer)
        try #require(FileManager.default.fileExists(atPath: modelURL.path))

        let goldensURL = try #require(
            Bundle.module.url(forResource: "tokenizer_parity", withExtension: "json", subdirectory: "Fixtures")
        )
        let demoURL = try #require(
            Bundle.module.url(forResource: "commit_intent_goldens", withExtension: "json", subdirectory: "Fixtures")
        )
        let goldens = try JSONDecoder().decode(Parity.self, from: Data(contentsOf: goldensURL))
        let demo = try JSONDecoder().decode(Demo.self, from: Data(contentsOf: demoURL))
        let predictor = try CommitIntentPredictor(modelURL: modelURL, tokenizerURL: tokenizerURL)
        let suggestion = try predictor.predict(
            stagedDiff: demo.demoDiff,
            files: ["Sources/Git/WorktreeManager.swift"]
        )
        #expect(suggestion.source == .model)
        #expect(suggestion.intent.type == expectedLabel(goldens.logits.typeLogits, LabelSchema.bundled.heads["type"]!))
        #expect(suggestion.intent.action == expectedLabel(goldens.logits.actionLogits, LabelSchema.bundled.heads["action"]!))
        #expect(suggestion.intent.scope == expectedLabel(goldens.logits.scopeLogits, LabelSchema.bundled.heads["scope"]!))
    }

    private func expectedLabel(_ logits: [Double], _ labels: [String]) -> String {
        var best = 0
        for i in logits.indices where logits[i] > logits[best] {
            best = i
        }
        return labels[best]
    }
}

private struct Demo: Decodable {
    var demoDiff: String
    enum CodingKeys: String, CodingKey { case demoDiff = "demo_diff" }
}

private struct Parity: Decodable {
    var text: String
    var inputIds: [Int]
    var attentionMask: [Int]
    var logits: Logits

    struct Logits: Decodable {
        var typeLogits: [Double]
        var actionLogits: [Double]
        var scopeLogits: [Double]

        enum CodingKeys: String, CodingKey {
            case typeLogits = "type_logits"
            case actionLogits = "action_logits"
            case scopeLogits = "scope_logits"
        }
    }

    enum CodingKeys: String, CodingKey {
        case text
        case inputIds = "input_ids"
        case attentionMask = "attention_mask"
        case logits
    }
}
