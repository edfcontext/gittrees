import Foundation

/// A path changed by a commit, as reported by `git diff-tree --name-status -z`.
public struct CommitFileChange: Identifiable, Hashable, Sendable {
    /// Repository-relative path after the change (the destination of a rename).
    public var path: String
    /// Source path for renames and copies.
    public var originalPath: String?
    public var status: FileChange.Status
    /// Similarity score for renames and copies (0–100), when Git reported one.
    public var similarity: Int?

    public init(
        path: String,
        originalPath: String? = nil,
        status: FileChange.Status,
        similarity: Int? = nil
    ) {
        self.path = path
        self.originalPath = originalPath
        self.status = status
        self.similarity = similarity
    }

    public var id: String {
        originalPath.map { "\($0)>\(path)" } ?? path
    }

    public var fileName: String {
        String(path.split(separator: "/").last ?? Substring(path))
    }

    public var directory: String {
        let components = path.split(separator: "/")
        guard components.count > 1 else { return "" }
        return components.dropLast().joined(separator: "/")
    }
}

/// Everything needed to inspect one commit: identity, message, and the files it changed.
public struct CommitDetail: Hashable, Sendable {
    public var hash: String
    public var abbreviatedHash: String
    public var subject: String
    /// The rest of the message after the subject, with trailing blank lines stripped.
    public var body: String
    public var authorName: String
    public var authorEmail: String
    public var authorDate: Date
    public var parentHashes: [String]
    public var files: [CommitFileChange]

    public init(
        hash: String,
        abbreviatedHash: String,
        subject: String,
        body: String = "",
        authorName: String,
        authorEmail: String,
        authorDate: Date,
        parentHashes: [String] = [],
        files: [CommitFileChange] = []
    ) {
        self.hash = hash
        self.abbreviatedHash = abbreviatedHash
        self.subject = subject
        self.body = body
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.authorDate = authorDate
        self.parentHashes = parentHashes
        self.files = files
    }

    /// Subject and body joined the way Git presents `%B`.
    public var fullMessage: String {
        if body.isEmpty { return subject }
        return subject + "\n\n" + body
    }

    public var isRoot: Bool { parentHashes.isEmpty }
}
