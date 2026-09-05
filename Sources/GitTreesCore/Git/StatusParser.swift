import Foundation

/// Parses `git status --porcelain=v2 -z --branch`.
///
/// Format v2 is versioned and documented, unlike v1's positional two-letter form, and
/// `-z` removes all path quoting. Records are NUL-terminated; a rename record (`2`) is
/// followed by a second NUL-terminated field holding the original path.
public enum StatusParser {
    public static func parse(_ data: Data) throws -> WorktreeStatus {
        let separator: UInt8 = data.contains(0x00) ? 0x00 : 0x0A
        let records = data
            .split(separator: separator, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
            .filter { !$0.isEmpty }
        return try parse(records: records)
    }

    public static func parse(porcelainText text: String) throws -> WorktreeStatus {
        try parse(Data(text.utf8))
    }

    static func parse(records: [String]) throws -> WorktreeStatus {
        var status = WorktreeStatus()
        var changes: [FileChange] = []
        var index = 0

        while index < records.count {
            let record = records[index]
            index += 1
            guard let marker = record.first else { continue }

            switch marker {
            case "#":
                apply(header: record, to: &status)
            case "1":
                if let change = parseOrdinary(record) { changes.append(change) }
            case "2":
                // The original path is the next NUL-terminated field.
                let original = index < records.count ? records[index] : nil
                if original != nil { index += 1 }
                if let change = parseRenamed(record, originalPath: original) { changes.append(change) }
            case "u":
                if let change = parseUnmerged(record) { changes.append(change) }
            case "?":
                changes.append(
                    FileChange(
                        path: String(record.dropFirst(2)),
                        indexStatus: .unmodified,
                        worktreeStatus: .modified,
                        kind: .untracked,
                        rawXY: "??"
                    )
                )
            case "!":
                changes.append(
                    FileChange(
                        path: String(record.dropFirst(2)),
                        indexStatus: .unmodified,
                        worktreeStatus: .unmodified,
                        kind: .ignored,
                        rawXY: "!!"
                    )
                )
            default:
                continue
            }
        }

        status.changes = changes.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return status
    }

    // MARK: - Headers

    private static func apply(header: String, to status: inout WorktreeStatus) {
        // `# branch.oid <sha>` / `# branch.head <name>` / `# branch.upstream <name>` /
        // `# branch.ab +<ahead> -<behind>`
        let parts = header.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 3 else { return }
        let key = String(parts[1])
        let value = String(parts[2])
        switch key {
        case "branch.oid":
            status.commit = value == "(initial)" ? nil : value
        case "branch.head":
            status.branch = value
        case "branch.upstream":
            status.upstream = value
        case "branch.ab":
            let counts = value.split(separator: " ")
            for count in counts {
                guard let sign = count.first, let magnitude = Int(count.dropFirst()) else { continue }
                if sign == "+" { status.ahead = magnitude }
                if sign == "-" { status.behind = magnitude }
            }
        default:
            break
        }
    }

    // MARK: - Entries

    /// `1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>`
    private static func parseOrdinary(_ record: String) -> FileChange? {
        let fields = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
        guard fields.count == 9 else { return nil }
        let xy = String(fields[1])
        guard xy.count == 2 else { return nil }
        return FileChange(
            path: String(fields[8]),
            indexStatus: FileChange.Status(code: xy.first!),
            worktreeStatus: FileChange.Status(code: xy.last!),
            kind: .tracked,
            rawXY: xy,
            isSubmodule: isSubmodule(String(fields[2]))
        )
    }

    /// `2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>` + NUL + `<origPath>`
    private static func parseRenamed(_ record: String, originalPath: String?) -> FileChange? {
        let fields = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
        guard fields.count == 10 else { return nil }
        let xy = String(fields[1])
        guard xy.count == 2 else { return nil }
        let scoreField = String(fields[8])
        let similarity = Int(scoreField.dropFirst())
        return FileChange(
            path: String(fields[9]),
            originalPath: originalPath,
            indexStatus: FileChange.Status(code: xy.first!),
            worktreeStatus: FileChange.Status(code: xy.last!),
            kind: .tracked,
            similarity: similarity,
            rawXY: xy,
            isSubmodule: isSubmodule(String(fields[2]))
        )
    }

    /// `u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>`
    private static func parseUnmerged(_ record: String) -> FileChange? {
        let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
        guard fields.count == 11 else { return nil }
        let xy = String(fields[1])
        guard xy.count == 2 else { return nil }
        return FileChange(
            path: String(fields[10]),
            indexStatus: .unmerged,
            worktreeStatus: .unmerged,
            kind: .unmerged,
            rawXY: xy,
            isSubmodule: isSubmodule(String(fields[2]))
        )
    }

    /// The submodule field is `N...` for a plain path and `S<c><m><u>` for a submodule.
    private static func isSubmodule(_ field: String) -> Bool {
        field.first == "S"
    }
}
