import Foundation

/// Parses the two machine-readable streams used to inspect a commit: `git log -1 -z
/// --format=…` for identity and message, and `git diff-tree --name-status -z` for the
/// files the commit changed.
public enum CommitDetailParser {
    /// Field order must match `GitClient.commitDetailFormat`.
    public static let metadataFieldCount = 8

    public static func parse(metadata: Data, nameStatus: Data) throws -> CommitDetail {
        var detail = try parseMetadata(metadata)
        detail.files = try parseNameStatus(nameStatus)
        return detail
    }

    // MARK: - Metadata

    /// `%H %h %an %ae %aI %P %s %b`, NUL-separated. `log -1 -z` then terminates the
    /// record with another NUL, so a trailing empty field is ignored. An empty body
    /// or parent list is a real field and is kept.
    public static func parseMetadata(_ data: Data) throws -> CommitDetail {
        var parts = data
            .split(separator: 0x00, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        if parts.last?.isEmpty == true { parts.removeLast() }

        guard parts.count >= metadataFieldCount else {
            throw GitError.unexpectedOutput(
                reason: "expected \(metadataFieldCount) fields per commit, got \(parts.count)",
                arguments: ["log", "-1"]
            )
        }

        let formatter = ISO8601DateFormatter()
        let parents = parts[5]
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        let subject = parts[6].trimmingCharacters(in: .newlines)
        let body = parts[7].trimmingCharacters(in: .whitespacesAndNewlines)

        return CommitDetail(
            hash: parts[0],
            abbreviatedHash: parts[1],
            subject: subject,
            body: body,
            authorName: parts[2],
            authorEmail: parts[3],
            authorDate: formatter.date(from: parts[4]) ?? Date(timeIntervalSince1970: 0),
            parentHashes: parents
        )
    }

    // MARK: - Name status

    /// `--name-status -z` yields `STATUS\0PATH\0` for ordinary changes and
    /// `R100\0OLD\0NEW\0` (or `C…`) for renames and copies. A trailing NUL produces an
    /// empty field that is skipped.
    public static func parseNameStatus(_ data: Data) throws -> [CommitFileChange] {
        let fields = data
            .split(separator: 0x00, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }

        var changes: [CommitFileChange] = []
        var index = 0
        while index < fields.count {
            let statusField = fields[index]
            index += 1
            if statusField.isEmpty { continue }

            guard let code = statusField.first else { continue }
            let status = FileChange.Status(code: code)
            let similarity = statusField.count > 1 ? Int(statusField.dropFirst()) : nil

            if status == .renamed || status == .copied {
                guard index + 1 < fields.count else {
                    throw GitError.unexpectedOutput(
                        reason: "rename/copy status \(statusField) is missing its paths",
                        arguments: ["diff-tree", "--name-status"]
                    )
                }
                let original = fields[index]
                let path = fields[index + 1]
                index += 2
                guard !original.isEmpty, !path.isEmpty else {
                    throw GitError.unexpectedOutput(
                        reason: "rename/copy status \(statusField) is missing its paths",
                        arguments: ["diff-tree", "--name-status"]
                    )
                }
                changes.append(
                    CommitFileChange(
                        path: path,
                        originalPath: original,
                        status: status,
                        similarity: similarity
                    )
                )
            } else {
                guard index < fields.count else {
                    throw GitError.unexpectedOutput(
                        reason: "status \(statusField) is missing its path",
                        arguments: ["diff-tree", "--name-status"]
                    )
                }
                let path = fields[index]
                index += 1
                guard !path.isEmpty else {
                    throw GitError.unexpectedOutput(
                        reason: "status \(statusField) is missing its path",
                        arguments: ["diff-tree", "--name-status"]
                    )
                }
                changes.append(
                    CommitFileChange(path: path, status: status, similarity: similarity)
                )
            }
        }

        return changes.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
