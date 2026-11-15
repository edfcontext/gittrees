import Foundation

/// Recover source names recorded in conventional merge subjects, even after the
/// branches have been deleted. Custom messages remain unknown rather than guessed.
enum MergeSourceParser {
    static func names(subject: String, sourceCount: Int) -> [String]? {
        guard sourceCount > 0 else { return nil }
        if sourceCount == 1 {
            for prefix in ["Merge branch '", "Merge remote-tracking branch '"] where subject.hasPrefix(prefix) {
                let tail = String(subject.dropFirst(prefix.count))
                let name: String
                if let into = tail.range(of: "' into ") {
                    name = String(tail[..<into.lowerBound])
                } else if tail.hasSuffix("'") {
                    name = String(tail.dropLast())
                } else {
                    return nil
                }
                return valid(name) ? [RefName.shortenLocal(name)] : nil
            }
            let pullRequestPrefix = "Merge pull request #"
            if subject.hasPrefix(pullRequestPrefix) {
                let parts = subject.dropFirst(pullRequestPrefix.count).components(separatedBy: " from ")
                if parts.count == 2, Int(parts[0]) != nil, valid(parts[1]) { return [parts[1]] }
            }
            let bitbucketPrefix = "Merged in "
            if subject.hasPrefix(bitbucketPrefix), subject.hasSuffix(")") {
                let parts = subject.dropFirst(bitbucketPrefix.count).dropLast().components(separatedBy: " (pull request #")
                if parts.count == 2, Int(parts[1]) != nil, valid(parts[0]) { return [parts[0]] }
            }
        }
        for prefix in ["Merge branches ", "Merge remote-tracking branches "] where subject.hasPrefix(prefix) {
            let sources = String(subject.dropFirst(prefix.count)).components(separatedBy: " into ")[0]
            let range = NSRange(sources.startIndex..., in: sources)
            let matches = quotedNames.matches(in: sources, range: range)
            guard matches.count == sourceCount else { return nil }
            var names: [String] = []
            var end = sources.startIndex
            for (index, match) in matches.enumerated() {
                guard let full = Range(match.range, in: sources),
                      let name = Range(match.range(at: 1), in: sources) else { return nil }
                let separator = String(sources[end..<full.lowerBound])
                guard index == 0 ? separator.isEmpty : [", ", " and ", ", and "].contains(separator) else { return nil }
                names.append(RefName.shortenLocal(String(sources[name])))
                end = full.upperBound
            }
            return end == sources.endIndex ? names : nil
        }
        return nil
    }

    private static let quotedNames = try! NSRegularExpression(pattern: "'([^\\s]+)'")

    private static func valid(_ name: String) -> Bool {
        !name.isEmpty && !name.contains(where: { $0.isWhitespace || $0.isNewline })
    }
}
