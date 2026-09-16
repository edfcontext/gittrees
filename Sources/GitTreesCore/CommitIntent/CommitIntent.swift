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
    /// One-line explanation of why this message was chosen, for the commit footer.
    public var diagnostic: String

    public init(
        message: String,
        intent: CommitIntent,
        confidence: Double,
        confidencePerHead: [String: Double] = [:],
        source: Source,
        belowThreshold: Bool,
        diagnostic: String = ""
    ) {
        self.message = message
        self.intent = intent
        self.confidence = confidence
        self.confidencePerHead = confidencePerHead
        self.source = source
        self.belowThreshold = belowThreshold
        self.diagnostic = diagnostic
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
            "scope": ["UI", "API", "DOMAIN", "DATA", "INTEGRATION", "PLATFORM", "BUILD", "SETTINGS", "TESTS", "DOCS", "GENERAL"]
        ],
        headNames: ["type", "action", "scope"]
    )

    public static func load(from url: URL) throws -> LabelSchema {
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(File.self, from: data)
        let heads = [
            "type": decoded.heads.type,
            "action": decoded.heads.action,
            "scope": decoded.heads.scope
        ]
        guard heads.values.allSatisfy({ !$0.isEmpty }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return LabelSchema(heads: heads, headNames: ["type", "action", "scope"])
    }

    private struct File: Decodable {
        var heads: Heads
        struct Heads: Decodable {
            var type: [String]
            var action: [String]
            var scope: [String]
        }
    }
}

/// Sidecar written next to the Core ML package.
public struct CommitIntentManifest: Sendable, Hashable {
    public var maxTokens: Int
    public var confidenceThreshold: Double

    public static let bundled = CommitIntentManifest(maxTokens: 256, confidenceThreshold: 0.50)

    public static func load(from url: URL) throws -> CommitIntentManifest {
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(File.self, from: data)
        return CommitIntentManifest(
            maxTokens: decoded.maxTokens ?? 256,
            confidenceThreshold: decoded.confidenceThreshold ?? 0.50
        )
    }

    private struct File: Decodable {
        var maxTokens: Int?
        var confidenceThreshold: Double?
    }
}
