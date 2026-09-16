import Foundation
import Testing
@testable import GitTreesCore

@Suite("DiffNormalizer")
struct DiffNormalizerTests {
    private var goldens: Goldens {
        get throws {
            let url = try #require(
                Bundle.module.url(forResource: "commit_intent_goldens", withExtension: "json", subdirectory: "Fixtures")
            )
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Goldens.self, from: data)
        }
    }

    @Test("normalized text matches Python byte-for-byte")
    func matchesPythonSwiftFixture() throws {
        let goldens = try goldens
        #expect(DiffNormalizer.normalize(goldens.swiftDiff) == goldens.swiftNormalized)
    }

    @Test("demo diff matches Python")
    func matchesPythonDemoFixture() throws {
        let goldens = try goldens
        #expect(DiffNormalizer.normalize(goldens.demoDiff) == goldens.demoNormalized)
    }

    @Test("lockfile bodies are listed but dropped from [DIFF]")
    func lockfileBodyExcluded() throws {
        let goldens = try goldens
        let out = DiffNormalizer.normalize(goldens.swiftDiff)
        #expect(out.contains("M pkg/package-lock.json"))
        #expect(!out.contains("lockfile noise"))
    }

    @Test("truncation inserts the same marker Python uses")
    func truncationMarker() throws {
        let goldens = try goldens
        #expect(DiffNormalizer.normalize(bigDiff(), maxWords: 60) == goldens.truncated)
    }

    @Test("normalize is deterministic")
    func deterministic() throws {
        let goldens = try goldens
        #expect(DiffNormalizer.normalize(goldens.swiftDiff) == DiffNormalizer.normalize(goldens.swiftDiff))
    }

    private func bigDiff() -> String {
        let lines = (0..<500).map { "+line number \($0) with words" }.joined(separator: "\n")
        return "diff --git a/x.py b/x.py\n--- a/x.py\n+++ b/x.py\n@@ -1 +1 @@\n" + lines
    }
}

@Suite("SymbolExtractor")
struct SymbolExtractorTests {
    private var goldens: Goldens {
        get throws {
            let url = try #require(
                Bundle.module.url(forResource: "commit_intent_goldens", withExtension: "json", subdirectory: "Fixtures")
            )
            return try JSONDecoder().decode(Goldens.self, from: Data(contentsOf: url))
        }
    }

    @Test("swift func names match Python")
    func swiftSymbols() throws {
        let goldens = try goldens
        #expect(SymbolExtractor.extract(from: goldens.swiftDiff) == goldens.swiftSymbols)
        #expect(SymbolExtractor.extract(from: goldens.demoDiff) == goldens.demoSymbols)
    }

    @Test("multilingual declarations match Python")
    func multilang() throws {
        let goldens = try goldens
        #expect(SymbolExtractor.extract(from: """
        + def parse_commit(x):
        + class BranchView:
        + func RefreshWorktrees() error {
        + export const loadStatus = async () => {
        """) == goldens.multilangSymbols)
    }

    @Test("stopwords are excluded")
    func stopwords() throws {
        let goldens = try goldens
        #expect(SymbolExtractor.extract(from: "+ if (x) {") == goldens.ifSymbols)
    }
}

@Suite("CommitObjectInferrer")
struct CommitObjectInferrerTests {
    private var goldens: Goldens {
        get throws {
            let url = try #require(
                Bundle.module.url(forResource: "commit_intent_goldens", withExtension: "json", subdirectory: "Fixtures")
            )
            return try JSONDecoder().decode(Goldens.self, from: Data(contentsOf: url))
        }
    }

    @Test("object inference matches Python")
    func matchesPython() throws {
        let goldens = try goldens
        #expect(
            CommitObjectInferrer.infer(
                diff: goldens.swiftDiff,
                files: ["Sources/Git/WorktreeManager.swift", "pkg/package-lock.json"]
            ) == goldens.swiftObject
        )
        #expect(
            CommitObjectInferrer.infer(
                diff: goldens.demoDiff,
                files: ["Sources/Git/WorktreeManager.swift"]
            ) == goldens.demoObject
        )
    }
}

@Suite("CommitMessageRenderer")
struct CommitMessageRendererTests {
    private var goldens: Goldens {
        get throws {
            let url = try #require(
                Bundle.module.url(forResource: "commit_intent_goldens", withExtension: "json", subdirectory: "Fixtures")
            )
            return try JSONDecoder().decode(Goldens.self, from: Data(contentsOf: url))
        }
    }

    @Test("plain and conventional rendering match Python")
    func matchesPython() throws {
        let goldens = try goldens
        #expect(
            CommitMessageRenderer.render(CommitIntent(type: "FIX", action: "FIX", scope: "DOMAIN"))
                == goldens.renders.fixWorktree
        )
        #expect(
            CommitMessageRenderer.render(CommitIntent(type: "FEATURE", action: "ADD", scope: "API"))
                == goldens.renders.addBranch
        )
        #expect(
            CommitMessageRenderer.render(CommitIntent(type: "CONFIG", action: "UPDATE", scope: "SETTINGS"))
                == goldens.renders.updateSettings
        )
        #expect(
            CommitMessageRenderer.render(
                CommitIntent(type: "FIX", action: "HANDLE", scope: "DOMAIN"),
                object: "worktree deletion"
            ) == goldens.renders.handleObject
        )
        #expect(
            CommitMessageRenderer.render(
                CommitIntent(type: "FIX", action: "HANDLE", scope: "DOMAIN"),
                object: "worktree deletion",
                style: .conventional
            ) == goldens.renders.conventional
        )
        #expect(
            CommitMessageRenderer.render(CommitIntent(type: "REFACTOR", action: "UPDATE", scope: "GENERAL"))
                == goldens.renders.generalNoObject
        )
        #expect(
            CommitMessageRenderer.render(CommitIntent(type: "FEATURE", action: "ADD", scope: "GENERAL"))
                == goldens.renders.addGeneral
        )
    }
}

@Suite("CommitDescriptionService")
struct CommitDescriptionServiceTests {
    @Test("labels.json loads the three heads in stable order")
    func labelsLoadFromBundle() throws {
        let url = try #require(CommitIntentResources.labels)
        let schema = try LabelSchema.load(from: url)
        #expect(schema.headNames == ["type", "action", "scope"])
        #expect(schema.label(head: "type", at: 6) == "CONFIG")
        #expect(schema.label(head: "action", at: 1) == "FIX")
        #expect(schema.label(head: "scope", at: 0) == "UI")
    }

    @Test("an empty staged diff falls back to the heuristic drafter")
    func heuristicFallback() async {
        let change = FileChange(
            path: "Sources/App.swift",
            indexStatus: .modified,
            worktreeStatus: .unmodified
        )
        let suggestion = CommitDescriptionService().suggestNow(
            stagedChanges: [change],
            stagedDiff: ""
        )
        #expect(suggestion.source == .heuristic)
        #expect(suggestion.message == "Update App.swift")
        #expect(suggestion.belowThreshold)
        #expect(suggestion.diagnostic.contains("no staged diff"))
    }
}

private struct Goldens: Decodable {
    var swiftDiff: String
    var swiftNormalized: String
    var swiftSymbols: [String]
    var swiftObject: String
    var demoDiff: String
    var demoNormalized: String
    var demoSymbols: [String]
    var demoObject: String
    var multilangSymbols: [String]
    var ifSymbols: [String]
    var truncated: String
    var renders: Renders

    struct Renders: Decodable {
        var fixWorktree: String
        var addBranch: String
        var updateSettings: String
        var handleObject: String
        var conventional: String
        var generalNoObject: String
        var addGeneral: String

        enum CodingKeys: String, CodingKey {
            case fixWorktree = "fix_worktree"
            case addBranch = "add_branch"
            case updateSettings = "update_settings"
            case handleObject = "handle_object"
            case conventional
            case generalNoObject = "general_no_object"
            case addGeneral = "add_general"
        }
    }

    enum CodingKeys: String, CodingKey {
        case swiftDiff = "swift_diff"
        case swiftNormalized = "swift_normalized"
        case swiftSymbols = "swift_symbols"
        case swiftObject = "swift_object"
        case demoDiff = "demo_diff"
        case demoNormalized = "demo_normalized"
        case demoSymbols = "demo_symbols"
        case demoObject = "demo_object"
        case multilangSymbols = "multilang_symbols"
        case ifSymbols = "if_symbols"
        case truncated
        case renders
    }
}
