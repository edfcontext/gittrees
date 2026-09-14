import Foundation

/// Multi-head commit intent predicted by the bundled classifier.
public struct CommitIntent: Sendable, Hashable, Equatable {
    public var type: String
    public var action: String
    public var scope: String

    public init(type: String, action: String, scope: String) {
        self.type = type
        self.action = action
        self.scope = scope
    }

    public subscript(head: String) -> String {
        switch head {
        case "type": type
        case "action": action
        case "scope": scope
        default: ""
        }
    }
}

/// A rendered commit subject plus the structured intent that produced it.
public struct CommitSuggestion: Sendable, Hashable, Equatable {
    public enum Source: String, Sendable, Hashable {
        case model
        case heuristic
    }

    public var message: String
    public var intent: CommitIntent
    public var confidence: Double
    public var confidencePerHead: [String: Double]
    public var source: Source
    /// True when the model ran but its aggregate confidence is below the UI gate.
    public var belowThreshold: Bool

    public init(
        message: String,
        intent: CommitIntent,
        confidence: Double,
        confidencePerHead: [String: Double] = [:],
        source: Source,
        belowThreshold: Bool
    ) {
        self.message = message
        self.intent = intent
        self.confidence = confidence
        self.confidencePerHead = confidencePerHead
        self.source = source
        self.belowThreshold = belowThreshold
    }
}

/// Label space loaded from `labels.json` so the neural code never hard-codes classes.
public struct LabelSchema: Sendable, Hashable {
    public var heads: [String: [String]]
    public var headNames: [String]

    public init(heads: [String: [String]], headNames: [String]? = nil) {
        self.heads = heads
        self.headNames = headNames ?? Array(heads.keys)
    }

    public func label(head: String, at index: Int) -> String? {
        heads[head].flatMap { $0.indices.contains(index) ? $0[index] : nil }
    }

    public static let bundled = LabelSchema(
        heads: [
            "type": ["FEATURE", "FIX", "REFACTOR", "UI", "TEST", "DOCS", "CONFIG", "DEPENDENCY", "PERFORMANCE", "CLEANUP"],
            "action": ["ADD", "FIX", "UPDATE", "REMOVE", "REFACTOR", "IMPROVE", "SUPPORT", "HANDLE", "PREVENT", "RENAME", "SIMPLIFY"],
            "scope": ["WORKTREE", "BRANCH", "REPOSITORY", "COMMIT", "STATUS", "SETTINGS", "FILESYSTEM", "UI", "GIT", "TESTS", "GENERAL"]
        ],
        headNames: ["type", "action", "scope"]
    )

    public static func load(from url: URL) throws -> LabelSchema {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let rawHeads = object?["heads"] as? [String: [String]] ?? [:]
        let names = (object?["heads"] as? [String: Any]).map { Array($0.keys) }
        return LabelSchema(heads: rawHeads, headNames: names)
    }
}

/// Sidecar written next to the Core ML package.
public struct CommitIntentManifest: Sendable, Hashable {
    public var maxTokens: Int
    public var confidenceThreshold: Double

    public static let bundled = CommitIntentManifest(maxTokens: 256, confidenceThreshold: 0.80)

    public static func load(from url: URL) throws -> CommitIntentManifest {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let maxTokens = object?["maxTokens"] as? Int ?? 256
        let threshold = object?["confidenceThreshold"] as? Double ?? 0.80
        return CommitIntentManifest(maxTokens: maxTokens, confidenceThreshold: threshold)
    }
}
