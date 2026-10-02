import Foundation

/// Extracts bounded, useful diff context for the on-device Apple Intelligence prompt.
enum CommitDiffEvidence {
    private static let generated = try! NSRegularExpression(
        pattern: #"(?:^|/)(?:package-lock\.json|yarn\.lock|Podfile\.lock|Package\.resolved|Cargo\.lock|poetry\.lock|.*\.pbxproj|.*\.generated\.[A-Za-z]+|.*\.min\.(?:js|css))$"#
    )

    private static let diffGit = try! NSRegularExpression(
        pattern: #"^diff --git a/(.+?) b/(.+)$"#
    )

    private struct ChangedFile {
        var path: String
        var kind: String
        var isGenerated: Bool {
            let ns = path as NSString
            return generated.firstMatch(
                in: path,
                options: [],
                range: NSRange(location: 0, length: ns.length)
            ) != nil
        }
    }

    /// Share a fixed prompt budget across files so a large early patch cannot hide later ones.
    static func extract(from diff: String, bytes: Int) -> String {
        let files = splitFiles(diff).map { file, body in
            let header = "\(file.kind) \(file.path)"
            return file.isGenerated ? header + "\n[generated contents omitted]"
                : ([header] + body).joined(separator: "\n")
        }
        guard !files.isEmpty else { return "" }
        let separatorBytes = 2 * (files.count - 1)
        let marker = "\n[truncated]"
        guard separatorBytes + marker.utf8.count <= bytes else { return "[truncated]" }
        let available = max(0, bytes - separatorBytes - marker.utf8.count)
        var allocations = Array(repeating: 0, count: files.count)
        var remaining = available
        var pending = Array(files.indices)
        while remaining > 0 && !pending.isEmpty {
            let share = max(1, remaining / pending.count)
            var next: [Int] = []
            for index in pending {
                let added = min(share, remaining, files[index].utf8.count - allocations[index])
                allocations[index] += added
                remaining -= added
                if allocations[index] < files[index].utf8.count { next.append(index) }
            }
            pending = next
        }
        let truncated = files.indices.contains { allocations[$0] < files[$0].utf8.count }
        let sections = files.indices.map { index in
            var result = ""
            var used = 0
            for scalar in files[index].unicodeScalars {
                let value = String(scalar)
                let size = value.utf8.count
                guard used + size <= allocations[index] else { break }
                result += value
                used += size
            }
            return result
        }
        return sections.joined(separator: "\n\n") + (truncated ? marker : "")
    }

    private static func splitFiles(_ diff: String) -> [(ChangedFile, [String])] {
        var chunks: [(ChangedFile, [String])] = []
        var lines: [String]?
        var path: String?
        var kind = "M"

        func flush() {
            if let path {
                chunks.append((ChangedFile(path: path, kind: kind), lines ?? []))
            }
            lines = nil
            path = nil
            kind = "M"
        }

        for line in splitLines(diff) {
            if line.hasPrefix("diff --git ") {
                flush()
                let ns = line as NSString
                if let match = diffGit.firstMatch(
                    in: line,
                    options: [],
                    range: NSRange(location: 0, length: ns.length)
                ), match.numberOfRanges >= 3 {
                    path = ns.substring(with: match.range(at: 2))
                }
                lines = []
            } else if lines == nil {
                continue
            } else if line.hasPrefix("new file") {
                kind = "A"
            } else if line.hasPrefix("deleted file") {
                kind = "D"
            } else if line.hasPrefix("rename to ") {
                kind = "R"
                path = String(line.dropFirst("rename to ".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("rename from ") {
                kind = "R"
            } else if line.hasPrefix("+++ b/") {
                path = String(line.dropFirst("+++ b/".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("index ")
                || line.hasPrefix("--- ")
                || line.hasPrefix("+++ ")
                || line.hasPrefix("old mode")
                || line.hasPrefix("new mode")
                || line.hasPrefix("similarity index")
                || line.hasPrefix("Binary files")
            {
                continue
            } else {
                lines?.append(line)
            }
        }
        flush()
        return chunks
    }

    private static func splitLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast(text.hasSuffix("\n") || text.hasSuffix("\r") ? 1 : 0)
            .map(String.init)
    }
}
