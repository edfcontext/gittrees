import Foundation
import Testing
@testable import GitTreesCore

/// Fixtures captured from real repositories with
/// `git diff-tree --name-status -z | tr '\0' '|'` and the matching `log -1 -z --format`.
@Suite("CommitDetailParser")
struct CommitDetailParserTests {

    static func nul(_ text: String) -> Data {
        Data(text.replacingOccurrences(of: "|", with: "\u{0}").utf8)
    }

    /// `%H %h %an %ae %aI %P %s %b` plus the trailing NUL `log -z` adds.
    static let ordinaryMetadata = nul(
        "3a41334e2640dc50b4225ebaebeec7e4f84dbd88|3a41334|GitTrees Tests|tests@example.com|2024-06-02T14:05:00Z|7eae1f89ebebacf4b6921f5bb8ba15554bceaa2b|subject line|body paragraph\nsecond line|"
    )

    static let rootMetadata = nul(
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|aaaaaaa|GitTrees Tests|tests@example.com|2024-06-02T14:00:00Z||initial commit||"
    )

    @Test("metadata fields round-trip, including a multi-line body")
    func metadataRoundTrip() throws {
        let detail = try CommitDetailParser.parseMetadata(Self.ordinaryMetadata)

        #expect(detail.hash == "3a41334e2640dc50b4225ebaebeec7e4f84dbd88")
        #expect(detail.abbreviatedHash == "3a41334")
        #expect(detail.authorName == "GitTrees Tests")
        #expect(detail.authorEmail == "tests@example.com")
        #expect(detail.subject == "subject line")
        #expect(detail.body == "body paragraph\nsecond line")
        #expect(detail.parentHashes == ["7eae1f89ebebacf4b6921f5bb8ba15554bceaa2b"])
        #expect(!detail.isRoot)
        #expect(detail.fullMessage == "subject line\n\nbody paragraph\nsecond line")
    }

    @Test("a root commit has no parents and may have an empty body")
    func rootCommit() throws {
        let detail = try CommitDetailParser.parseMetadata(Self.rootMetadata)

        #expect(detail.subject == "initial commit")
        #expect(detail.body.isEmpty)
        #expect(detail.parentHashes.isEmpty)
        #expect(detail.isRoot)
        #expect(detail.fullMessage == "initial commit")
    }

    @Test("ordinary name-status entries carry their letter and path")
    func ordinaryNameStatus() throws {
        // Captured from `git diff-tree --name-status -z` of a modify + add.
        let files = try CommitDetailParser.parseNameStatus(Self.nul("M|README.md|A|b.txt|"))

        #expect(files.map(\.path) == ["b.txt", "README.md"])
        let readme = try #require(files.first { $0.path == "README.md" })
        #expect(readme.status == .modified)
        #expect(readme.originalPath == nil)
        let added = try #require(files.first { $0.path == "b.txt" })
        #expect(added.status == .added)
    }

    @Test("a rename reports both paths and the similarity score")
    func renameNameStatus() throws {
        let files = try CommitDetailParser.parseNameStatus(
            Self.nul("R100|src/a.txt|src/a renamed.txt|")
        )

        #expect(files.count == 1)
        let renamed = try #require(files.first)
        #expect(renamed.status == .renamed)
        #expect(renamed.path == "src/a renamed.txt")
        #expect(renamed.originalPath == "src/a.txt")
        #expect(renamed.similarity == 100)
        #expect(renamed.fileName == "a renamed.txt")
    }

    @Test("a copy is distinguished from a rename")
    func copyNameStatus() throws {
        let files = try CommitDetailParser.parseNameStatus(Self.nul("C080|keep.txt|keep copy.txt|"))
        let copied = try #require(files.first)
        #expect(copied.status == .copied)
        #expect(copied.similarity == 80)
        #expect(copied.originalPath == "keep.txt")
    }

    @Test("paths with spaces survive the NUL field split")
    func pathWithSpace() throws {
        let files = try CommitDetailParser.parseNameStatus(Self.nul("D|docs/old note.md|"))
        #expect(files.first?.path == "docs/old note.md")
        #expect(files.first?.status == .deleted)
    }

    @Test("empty name-status yields no files")
    func emptyNameStatus() throws {
        #expect(try CommitDetailParser.parseNameStatus(Data()).isEmpty)
    }

    @Test("metadata and name-status combine into one CommitDetail")
    func combinedParse() throws {
        let detail = try CommitDetailParser.parse(
            metadata: Self.ordinaryMetadata,
            nameStatus: Self.nul("M|README.md|A|b.txt|")
        )
        #expect(detail.subject == "subject line")
        #expect(detail.files.count == 2)
    }

    @Test("a truncated rename record is reported rather than silently dropped")
    func truncatedRename() {
        #expect(throws: GitError.self) {
            try CommitDetailParser.parseNameStatus(Self.nul("R100|only-old.txt|"))
        }
    }

    @Test("truncated metadata is reported rather than silently mis-parsed")
    func truncatedMetadata() {
        #expect(throws: GitError.self) {
            try CommitDetailParser.parseMetadata(Self.nul("abc|short|"))
        }
    }

    @Test("the log format GitClient sends has one field per metadata slot")
    func formatMatchesParser() {
        let fields = GitClient.commitDetailFormat.split(separator: "%x00", omittingEmptySubsequences: false)
        #expect(fields.count == CommitDetailParser.metadataFieldCount)
    }
}
