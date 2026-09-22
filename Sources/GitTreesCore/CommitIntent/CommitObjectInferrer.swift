import Foundation

/// Deterministic object/topic guess from symbols + paths. Port of `_infer_object`.
public enum CommitObjectInferrer {
    private static let camel = try! NSRegularExpression(
        pattern: #"[A-Z]?[a-z]+|[A-Z]+(?![a-z])|\d+"#
    )

    private static let stop: Set<String> = [
        "the", "a", "an", "manager", "view", "controller", "swift", "py", "ts",
        "delete", "remove", "add", "fix", "update", "handle", "refresh", "set",
        "get", "make", "create", "prevent", "support", "rename", "improve",
        "simplify", "load", "save", "with", "for", "func", "is"
    ]

    /// Weighted rather than by raw frequency: words from the diff's changed
    /// symbols outrank words from file names, and an earlier changed symbol
    /// outranks a later one — so the object leans toward the primary changed
    /// identifier instead of whatever word merely repeats most.
    public static func infer(diff: String, files: [String]) -> String {
        var weight: [String: Int] = [:]
        var order: [String] = []
        func add(_ word: String, _ w: Int) {
            let lower = word.lowercased()
            guard lower.count > 2, !stop.contains(lower) else { return }
            if weight[lower] == nil {
                order.append(lower)
            }
            weight[lower, default: 0] += w
        }
        let symbols = SymbolExtractor.extract(from: diff, limit: 6)
        for (i, symbol) in symbols.enumerated() {
            for word in split(symbol) { add(word, symbols.count - i) } // earlier -> higher
        }
        for file in files.prefix(3) {
            for word in split(stem(file)) { add(word, 1) }             // weak fallback
        }
        let top = order.sorted { a, b in
            let wa = weight[a] ?? 0
            let wb = weight[b] ?? 0
            if wa != wb { return wa > wb }
            return (order.firstIndex(of: a) ?? 0) < (order.firstIndex(of: b) ?? 0)
        }.prefix(2)
        return top.joined(separator: " ")
    }

    private static func split(_ name: String) -> [String] {
        let ns = name as NSString
        let range = NSRange(location: 0, length: ns.length)
        return camel.matches(in: name, options: [], range: range).map { ns.substring(with: $0.range) }
    }

    /// `pathlib.Path(f).stem` — last path component without the final suffix.
    private static func stem(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }
}
