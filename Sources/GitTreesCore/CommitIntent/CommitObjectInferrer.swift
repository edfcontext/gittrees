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

    public static func infer(diff: String, files: [String]) -> String {
        var words: [String] = []
        for symbol in SymbolExtractor.extract(from: diff, limit: 6) {
            words.append(contentsOf: split(symbol))
        }
        for file in files.prefix(3) {
            words.append(contentsOf: split(stem(file)))
        }
        var freq: [String: Int] = [:]
        var order: [String] = []
        for word in words {
            let lower = word.lowercased()
            guard lower.count > 2, !stop.contains(lower) else { continue }
            if freq[lower] == nil {
                order.append(lower)
            }
            freq[lower, default: 0] += 1
        }
        let top = order.sorted { a, b in
            let fa = freq[a] ?? 0
            let fb = freq[b] ?? 0
            if fa != fb { return fa > fb }
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
