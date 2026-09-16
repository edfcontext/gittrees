import Foundation

/// Deterministic diff → compact `[FILES]/[STATS]/[SYMBOLS]/[DIFF]` text.
///
/// This is a line-for-line port of `data/normalize_diff.py`. Training and inference
/// share this shape; any drift here is train/serve skew.
public enum DiffNormalizer {
    public static let defaultMaxWords = 380

    private static let generated = try! NSRegularExpression(
        pattern: #"(?:^|/)(?:package-lock\.json|yarn\.lock|Podfile\.lock|Package\.resolved|Cargo\.lock|poetry\.lock|.*\.pbxproj|.*\.generated\.[A-Za-z]+|.*\.min\.(?:js|css))$"#
    )

    private static let diffGit = try! NSRegularExpression(
        pattern: #"^diff --git a/(.+?) b/(.+)$"#
    )

    /// Collapse runs of the literal two-character sequence `\s` — matching the Python
    /// `re.sub(r'\\s+', ' ', content)` in `normalize_diff.py`, not Unicode whitespace.
    private static let literalSlashS = try! NSRegularExpression(pattern: #"\\s+"#)

    private struct FileChange {
        var path: String
        var kind: String
        var oldPath: String?
        var isGenerated: Bool {
            let ns = path as NSString
            return generated.firstMatch(in: path, options: [], range: NSRange(location: 0, length: ns.length)) != nil
        }
    }

    public static func normalize(_ diff: String, maxWords: Int = defaultMaxWords) -> String {
        let changes = splitFiles(diff)
        var filesBlock: [String] = []
        var allDiffLines: [String] = []
        var added = 0
        var deleted = 0
        for (file, body) in changes {
            filesBlock.append("\(file.kind) \(file.path)")
            for line in body {
                if line.hasPrefix("+") && !line.hasPrefix("+++") {
                    added += 1
                } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                    deleted += 1
                }
            }
            if !file.isGenerated {
                allDiffLines.append(contentsOf: changedOnly(body))
            }
        }

        let symbols = SymbolExtractor.extract(from: diff)
        var header: [String] = ["[FILES]"]
        header.append(contentsOf: filesBlock)
        header.append("[STATS]")
        header.append("files=\(changes.count) added=\(added) deleted=\(deleted)")
        header.append("[SYMBOLS]")
        header.append(symbols.isEmpty ? "(none)" : symbols.joined(separator: " "))
        header.append("[DIFF]")

        var used = header.reduce(0) { $0 + PythonText.splitWords($1).count }
        var kept: [String] = []
        for line in allDiffLines {
            let words = PythonText.splitWords(line).count
            if used + words > maxWords {
                kept.append("... (diff truncated)")
                break
            }
            kept.append(line)
            used += words
        }
        return (header + kept).joined(separator: "\n")
    }

    private static func splitFiles(_ diff: String) -> [(FileChange, [String])] {
        var chunks: [(FileChange, [String])] = []
        var curLines: [String]?
        var curPath: String?
        var curOld: String?
        var curKind = "M"

        func flush() {
            if let path = curPath {
                chunks.append((FileChange(path: path, kind: curKind, oldPath: curOld), curLines ?? []))
            }
            curLines = nil
            curPath = nil
            curOld = nil
            curKind = "M"
        }

        for line in PythonText.splitlines(diff) {
            if line.hasPrefix("diff --git ") {
                flush()
                let ns = line as NSString
                if let match = diffGit.firstMatch(in: line, options: [], range: NSRange(location: 0, length: ns.length)),
                   match.numberOfRanges >= 3
                {
                    curOld = ns.substring(with: match.range(at: 1))
                    curPath = ns.substring(with: match.range(at: 2))
                } else {
                    curOld = nil
                    curPath = nil
                }
                curKind = "M"
                curLines = []
            } else if curLines == nil {
                continue
            } else if line.hasPrefix("new file") {
                curKind = "A"
            } else if line.hasPrefix("deleted file") {
                curKind = "D"
            } else if line.hasPrefix("rename to ") {
                curKind = "R"
                curPath = String(line.dropFirst("rename to ".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("rename from ") {
                curKind = "R"
                curOld = String(line.dropFirst("rename from ".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("+++ b/") {
                curPath = String(line.dropFirst("+++ b/".count)).trimmingCharacters(in: .whitespaces)
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
                curLines?.append(line)
            }
        }
        flush()
        return chunks
    }

    private static func changedOnly(_ body: [String]) -> [String] {
        var out: [String] = []
        for line in body {
            if line.hasPrefix("@@") { continue }
            if line.hasPrefix("+") || line.hasPrefix("-") {
                let content = String(line.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty {
                    let ns = content as NSString
                    let collapsed = literalSlashS.stringByReplacingMatches(
                        in: content,
                        options: [],
                        range: NSRange(location: 0, length: ns.length),
                        withTemplate: " "
                    )
                    out.append("\(line.first!) \(collapsed)")
                }
            }
        }
        return out
    }
}
