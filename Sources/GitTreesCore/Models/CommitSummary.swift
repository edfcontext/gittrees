import Foundation

/// One line of `git log`, used by the History tab.
public struct CommitSummary: Identifiable, Hashable, Sendable {
    public var hash: String
    public var abbreviatedHash: String
    public var subject: String
    public var authorName: String
    public var authorDate: Date
    public var refNames: String

    public init(
        hash: String,
        abbreviatedHash: String,
        subject: String,
        authorName: String,
        authorDate: Date,
        refNames: String = ""
    ) {
        self.hash = hash
        self.abbreviatedHash = abbreviatedHash
        self.subject = subject
        self.authorName = authorName
        self.authorDate = authorDate
        self.refNames = refNames
    }

    public var id: String { hash }
}
