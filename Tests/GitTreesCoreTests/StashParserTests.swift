import Foundation
import Testing
@testable import GitTreesCore

@Suite("StashParser")
struct StashParserTests {

    /// Builds the exact byte shape `git stash list -z --format=…` produces: fields joined
    /// by the Unit Separator, records terminated by NUL.
    private func output(_ entries: [(sha: String, selector: String, subject: String, iso: String)]) -> Data {
        var text = ""
        for entry in entries {
            text += [entry.sha, entry.selector, entry.subject, entry.iso].joined(separator: "\u{1f}")
            text += "\u{00}"
        }
        return Data(text.utf8)
    }

    @Test("each field is taken from its own separator-delimited slot")
    func parsesFields() throws {
        let data = output([
            ("83dd155b981ef59a25f2d12ed612bab3c8b15a23", "stash@{0}", "On feature: third on feature", "2026-09-07T21:30:57-05:00")
        ])
        let stashes = try StashParser.parse(data)

        #expect(stashes.count == 1)
        let stash = try #require(stashes.first)
        #expect(stash.commit == "83dd155b981ef59a25f2d12ed612bab3c8b15a23")
        #expect(stash.selector == "stash@{0}")
        #expect(stash.branch == "feature")
        #expect(stash.message == "third on feature")
        #expect(stash.shortCommit == "83dd155")
        #expect(stash.date != nil)
    }

    @Test("the branch is read from either the On or WIP-on prefix")
    func splitsSubject() {
        #expect(StashParser.splitSubject("On main: my work").branch == "main")
        #expect(StashParser.splitSubject("On main: my work").message == "my work")
        #expect(StashParser.splitSubject("WIP on release/2.1: fixes").branch == "release/2.1")
        #expect(StashParser.splitSubject("WIP on release/2.1: fixes").message == "fixes")
        // A message containing its own colon keeps everything after the first ": ".
        #expect(StashParser.splitSubject("On main: ratio 3:1 tweak").message == "ratio 3:1 tweak")
    }

    @Test("a branch whose lowercasing changes its byte length is sliced correctly")
    func branchWithNonASCIICasing() {
        // `İ` (U+0130) lowercases to two scalars, so an index taken from a lowercased
        // copy would not be valid against the original — the branch must still come out
        // whole rather than mid-scalar.
        let (branch, message) = StashParser.splitSubject("On İstanbul: harbour work")
        #expect(branch == "İstanbul")
        #expect(message == "harbour work")

        let wip = StashParser.splitSubject("WIP on İzmir: coast")
        #expect(wip.branch == "İzmir")
        #expect(wip.message == "coast")
    }

    @Test("a subject with no recognisable prefix is kept whole as the message")
    func subjectWithoutPrefix() {
        let (branch, message) = StashParser.splitSubject("a bare message")
        #expect(branch == nil)
        #expect(message == "a bare message")
    }

    @Test("entries keep their order and a message may contain spaces and a colon")
    func multipleEntries() throws {
        let data = output([
            ("aaaa111", "stash@{0}", "On main: first: with colon", "2026-09-07T21:30:57-05:00"),
            ("bbbb222", "stash@{1}", "On feature/x: second", "2026-09-06T10:00:00-05:00")
        ])
        let stashes = try StashParser.parse(data)

        #expect(stashes.map(\.commit) == ["aaaa111", "bbbb222"])
        #expect(stashes[0].message == "first: with colon")
        #expect(stashes[1].branch == "feature/x")
    }

    @Test("no stashes parse to an empty list")
    func emptyOutput() throws {
        #expect(try StashParser.parse(Data()).isEmpty)
    }

    @Test("a missing date field is tolerated rather than failing the parse")
    func missingDate() throws {
        // Three fields, no trailing date — parse the entry, leave the date nil.
        let text = ["cccc333", "stash@{0}", "On main: no date"].joined(separator: "\u{1f}") + "\u{00}"
        let stashes = try StashParser.parse(Data(text.utf8))
        #expect(stashes.count == 1)
        #expect(stashes.first?.date == nil)
        #expect(stashes.first?.message == "no date")
    }
}
