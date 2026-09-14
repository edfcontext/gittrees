import Foundation

/// Changed function/class/type names from a unified diff.
///
/// Language-agnostic regex, matching `data/extract_symbols.py` so the `[SYMBOLS]`
/// block the model sees is the same one it trained on.
public enum SymbolExtractor {
    private static let patterns: [NSRegularExpression] = [
        regex(#"\b(?:func|function|def)\s+([A-Za-z_][A-Za-z0-9_]*)"#),
        regex(#"\b(?:class|struct|enum|protocol|interface|actor|trait)\s+([A-Za-z_][A-Za-z0-9_]*)"#),
        regex(#"\bfunc\s+(?:\([^)]*\)\s*)?([A-Za-z_][A-Za-z0-9_]*)\s*\("#),
        regex(#"\b(?:const|let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::[^=]+)?=\s*(?:async\s*)?\("#),
        regex(#"\b(?:public|private|internal|open|static|override|func)\b[^\n(]*?\b([A-Za-z_][A-Za-z0-9_]*)\s*\("#)
    ]

    private static let stop: Set<String> = [
        "if", "for", "while", "switch", "return", "guard", "catch", "init", "self",
        "super", "print", "let", "var", "func", "const", "async", "await", "in"
    ]

    /// Identifiers in first-seen order, capped at `limit` (Python default 20).
    public static func extract(from diff: String, limit: Int = 20) -> [String] {
        var seen: [String] = []
        var seenSet: Set<String> = []
        for line in changedLines(in: diff) {
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            for pattern in patterns {
                pattern.enumerateMatches(in: line, options: [], range: range) { match, _, stopEnum in
                    guard let match, match.numberOfRanges >= 2 else { return }
                    let nameRange = match.range(at: 1)
                    guard nameRange.location != NSNotFound else { return }
                    let name = ns.substring(with: nameRange)
                    if stop.contains(name) || seenSet.contains(name) || name.count < 2 {
                        return
                    }
                    seenSet.insert(name)
                    seen.append(name)
                    if seen.count >= limit {
                        stopEnum.pointee = true
                    }
                }
                if seen.count >= limit { return seen }
            }
        }
        return seen
    }

    /// `+/-` content lines, excluding the `+++`/`---` file headers.
    static func changedLines(in diff: String) -> [String] {
        var out: [String] = []
        for line in PythonText.splitlines(diff) {
            if (line.hasPrefix("+") && !line.hasPrefix("+++"))
                || (line.hasPrefix("-") && !line.hasPrefix("---"))
            {
                out.append(String(line.dropFirst()))
            }
        }
        return out
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [])
    }
}
