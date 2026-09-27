import Foundation

/// A minimal reader for `~/.ssh/config`, just enough to resolve a `Host` alias to the
/// `HostName` ssh would connect to.
///
/// This exists so a remote written against an SSH alias — `git@github-work:owner/repo`
/// — can still be recognised as GitHub, even though the URL never contains "github.com".
/// It mirrors what `gh` does when it decides whether a remote is a GitHub remote.
///
/// It is not a full ssh_config implementation: it understands `Host` pattern lines
/// (including `*`/`?` globs and `!` negation) and `HostName`, following ssh's rule that
/// the value is taken from the first matching block that sets it. Includes, Match blocks,
/// and other keywords are ignored — none affect this decision.
public struct SSHConfig: Sendable {
    private struct Block: Sendable {
        let patterns: [String]
        let hostName: String?
    }

    private let blocks: [Block]

    /// Parsed once from the user's `~/.ssh/config`. Empty when it cannot be read, so a
    /// machine without the file simply falls back to matching literal hosts.
    public static let user: SSHConfig = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return SSHConfig(text: text)
    }()

    public init(text: String) {
        var blocks: [Block] = []
        var patterns: [String]?
        var hostName: String?

        func flush() {
            if let patterns { blocks.append(Block(patterns: patterns, hostName: hostName)) }
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let (key, value) = Self.keyValue(line)
            switch key.lowercased() {
            case "host":
                flush()
                patterns = value.split(whereSeparator: \.isWhitespace).map(String.init)
                hostName = nil
            case "hostname":
                // ssh takes the first HostName within a block.
                if hostName == nil, !value.isEmpty { hostName = value }
            default:
                break
            }
        }
        flush()
        self.blocks = blocks
    }

    /// The `HostName` ssh would use for `alias` — the first matching `Host` block that
    /// sets one — or nil when the alias is unknown or sets no `HostName`.
    public func hostName(for alias: String) -> String? {
        for block in blocks where block.hostName != nil {
            if Self.block(block.patterns, matches: alias) { return block.hostName }
        }
        return nil
    }

    // MARK: - Parsing helpers

    /// Splits `Keyword Value` on the first whitespace or `=`, unquoting the value.
    private static func keyValue(_ line: String) -> (key: String, value: String) {
        guard let separator = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" })
        else { return (line, "") }
        let key = String(line[..<separator])
        var value = String(line[line.index(after: separator)...])
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t="))
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        return (key, value)
    }

    /// ssh block-match semantics: a block matches when at least one positive pattern
    /// matches and no negated (`!`) pattern does.
    private static func block(_ patterns: [String], matches alias: String) -> Bool {
        var positive = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                if glob(String(pattern.dropFirst()), matches: alias) { return false }
            } else if glob(pattern, matches: alias) {
                positive = true
            }
        }
        return positive
    }

    /// Matches an ssh `Host` pattern (`*` = any run, `?` = one character) against an alias.
    private static func glob(_ pattern: String, matches alias: String) -> Bool {
        if !pattern.contains("*"), !pattern.contains("?") { return pattern == alias }
        let regex = "^" + NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".") + "$"
        return alias.range(of: regex, options: .regularExpression) != nil
    }
}
