import Foundation

/// Parses `git stash list -z --format=%H%x1f%gd%x1f%gs%x1f%cI`.
///
/// Entries are NUL-terminated (`-z`) and their four fields are separated by the Unit
/// Separator (0x1f), so a stash message containing spaces, colons or even a newline
/// cannot be mistaken for a field or record boundary.
public enum StashParser {
    /// The Git `--format` string this parser expects, kept beside the parser so the two
    /// stay in step.
    public static let format = "%H%x1f%gd%x1f%gs%x1f%cI"

    private static let unitSeparator: Character = "\u{1f}"

    public static func parse(_ data: Data) throws -> [Stash] {
        let text = String(decoding: data, as: UTF8.self)
        // `-z` terminates every record with a NUL; the split drops the empty tail.
        let records = text.split(separator: "\0", omittingEmptySubsequences: true)

        return try records.map { record in
            let fields = record.split(separator: unitSeparator, omittingEmptySubsequences: false)
            guard fields.count >= 3 else {
                throw GitError.unexpectedOutput(
                    reason: "a stash entry had \(fields.count) fields, expected 4",
                    arguments: ["stash", "list"]
                )
            }
            let commit = String(fields[0])
            let selector = String(fields[1])
            let subject = String(fields[2])
            let isoDate = fields.count > 3 ? String(fields[3]) : ""

            let (branch, message) = splitSubject(subject)
            return Stash(
                selector: selector,
                commit: commit,
                branch: branch,
                message: message,
                date: date(fromISO: isoDate)
            )
        }
    }

    /// Splits `On main: my work` or `WIP on main: <sha> <subject>` into the branch and
    /// the message. A subject Git wrote without the `on <branch>:` shape is kept whole as
    /// the message.
    static func splitSubject(_ subject: String) -> (branch: String?, message: String) {
        guard let colon = subject.range(of: ": ") else {
            return (nil, subject)
        }
        let prefix = subject[subject.startIndex..<colon.lowerBound]
        let message = String(subject[colon.upperBound...])

        // `prefix` is `On <branch>` or `WIP on <branch>`; the branch is what follows the
        // last `on `. Search `prefix` itself, case-insensitively, so the index is native
        // to it — indices from a separately-lowercased copy are not interchangeable, and
        // a branch whose lowercasing changes its UTF-8 length (e.g. `İ`) would land
        // mid-scalar.
        if let onRange = prefix.range(of: "on ", options: [.backwards, .caseInsensitive]) {
            let branch = String(prefix[onRange.upperBound...])
            return (branch.isEmpty ? nil : branch, message)
        }
        return (nil, message)
    }

    private static func date(fromISO iso: String) -> Date? {
        let trimmed = iso.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Built per call rather than cached: `ISO8601DateFormatter` is not `Sendable`, and
        // parsing a stash list is nowhere near hot enough for the allocation to matter.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }
}
