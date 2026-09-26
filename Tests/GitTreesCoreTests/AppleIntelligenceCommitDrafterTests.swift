import Foundation
import Testing
@testable import GitTreesCore

@Suite("Apple Intelligence commit suggestions")
struct AppleIntelligenceCommitDrafterTests {
    private var change: FileChange {
        FileChange(path: "Sources/Cache.swift", indexStatus: .modified, worktreeStatus: .unmodified)
    }

    private var diff: String {
        """
        diff --git a/Sources/Cache.swift b/Sources/Cache.swift
        --- a/Sources/Cache.swift
        +++ b/Sources/Cache.swift
        @@ -1,3 +1,4 @@
         func cachedValue(for key: String) -> Value? {
        +    guard !expiredKeys.contains(key) else { return nil }
             return values[key]
         }
        """
    }

    @Test("generation is preferred and does not fabricate classifier confidence")
    func generatedSubject() async {
        let service = CommitDescriptionService { changes, diff in
            #expect(changes.count == 1)
            #expect(diff.contains("expiredKeys"))
            return "Prevent expired cache entries from being returned"
        }
        let result = await service.suggest(stagedChanges: [change], stagedDiff: diff)
        #expect(result.message == "Prevent expired cache entries from being returned")
        #expect(result.source == .appleIntelligence)
        #expect(result.confidence == 0)
        #expect(result.confidencePerHead.isEmpty)
        #expect(!result.belowThreshold)
        #expect(result.diagnostic == "Apple Intelligence · On-device")
    }

    @Test("empty input never invokes generation")
    func emptyInput() async {
        let service = CommitDescriptionService { _, _ in
            Issue.record("Generation must not run without staged content")
            return "Unexpected"
        }
        let noFiles = await service.suggest(stagedChanges: [], stagedDiff: diff)
        #expect(noFiles.message.isEmpty)
        let noDiff = await service.suggest(stagedChanges: [change], stagedDiff: "")
        #expect(noDiff.message == "Update Cache.swift")
        #expect(noDiff.source == .heuristic)
    }

    @Test("unavailable, failed, and malformed output use the existing fallback", arguments: [0, 1, 2])
    func fallback(mode: Int) async {
        let service = CommitDescriptionService { _, _ in
            if mode == 0 { throw AppleIntelligenceCommitDrafter.Failure.unavailable("not enabled") }
            if mode == 1 { throw CocoaError(.coderInvalidValue) }
            return "Subject\nUnwanted body"
        }
        let expected = service.suggestNow(stagedChanges: [change], stagedDiff: diff)
        let result = await service.suggest(stagedChanges: [change], stagedDiff: diff)
        #expect(result.source == expected.source)
        #expect(result.message == expected.message)
        #expect(result.diagnostic.hasPrefix("Apple Intelligence"))
        #expect(result.diagnostic.hasSuffix(expected.diagnostic))
    }

    @Test("cancelled generation does not invoke the model fallback")
    func cancellation() async {
        let service = CommitDescriptionService { _, _ in throw CancellationError() }
        let result = await service.suggest(stagedChanges: [change], stagedDiff: diff)
        #expect(result.message.isEmpty)
        #expect(result.diagnostic == "Suggestion cancelled.")
    }

    @Test("subjects must be usable single lines", arguments: ["", " \n", "Fix\nBody", "Fix\u{2028}Body", "```swift", "- Fix bug", String(repeating: "x", count: 73)])
    func invalidSubjects(text: String) {
        #expect(throws: AppleIntelligenceCommitDrafter.Failure.self) {
            try AppleIntelligenceCommitDrafter.validatedSubject(text)
        }
    }

    @Test("prompt is bounded even with long paths, minified code and Unicode")
    func boundedPrompt() {
        let changes = (0..<100).map {
            FileChange(path: "\($0)/" + String(repeating: "界", count: 2_000),
                       indexStatus: .modified, worktreeStatus: .unmodified)
        }
        let input = diff + "\n+" + String(repeating: "界", count: 30_000)
        let prompt = AppleIntelligenceCommitDrafter.prompt(changes: changes, diff: input)
        #expect(prompt.utf8.count < 6_500)
        #expect(prompt.contains("100 staged files"))
        #expect(prompt.contains("expiredKeys"))
        #expect(prompt.contains("[truncated]"))
    }

    @Test("generative evidence keeps code context but omits generated content")
    func codeContext() {
        let prompt = AppleIntelligenceCommitDrafter.prompt(changes: [change], diff: diff + """

        diff --git a/package-lock.json b/package-lock.json
        +DO_NOT_INCLUDE_LOCK_CONTENT
        """)
        #expect(prompt.contains("func cachedValue"))
        #expect(prompt.contains("return values[key]"))
        #expect(prompt.contains("+    guard !expiredKeys"))
        #expect(!prompt.contains("DO_NOT_INCLUDE_LOCK_CONTENT"))
    }

    @Test("live on-device generation", .enabled(if: ProcessInfo.processInfo.environment["GITTREES_TEST_APPLE_INTELLIGENCE"] == "1"))
    func liveGeneration() async throws {
        let samples = [
            (change, diff),
            (FileChange(path: "Sources/Search.swift", indexStatus: .modified, worktreeStatus: .unmodified), """
            diff --git a/Sources/Search.swift b/Sources/Search.swift
            --- a/Sources/Search.swift
            +++ b/Sources/Search.swift
            @@ -1,1 +1,1 @@
            -let matches = names.filter { $0.contains(query) }
            +let matches = names.filter { $0.localizedCaseInsensitiveContains(query) }
            """),
            (FileChange(path: "Sources/Settings.swift", indexStatus: .modified, worktreeStatus: .unmodified), """
            diff --git a/Sources/Settings.swift b/Sources/Settings.swift
            --- a/Sources/Settings.swift
            +++ b/Sources/Settings.swift
            @@ -1,3 +1,4 @@
             Form {
                 Toggle("Notifications", isOn: $notificationsEnabled)
            +    Toggle("Show line numbers", isOn: $showLineNumbers)
             }
            """)
        ]
        let legacy = CommitDescriptionService()
        for (change, diff) in samples {
            let generated = try await AppleIntelligenceCommitDrafter.draft(changes: [change], diff: diff)
            print("Raw Apple Intelligence subject (\(change.path)): \(generated)")
            let subject = try AppleIntelligenceCommitDrafter.validatedSubject(generated)
            let old = legacy.suggestNow(stagedChanges: [change], stagedDiff: diff)
            print("Apple Intelligence sample (\(change.path)): \(subject)")
            print("Existing model sample: \(old.message)")
        }
    }
}
