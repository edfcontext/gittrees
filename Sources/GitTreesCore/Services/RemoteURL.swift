import Foundation

/// Helpers for Git remote URLs as the user types them: SSH, HTTPS, and local paths.
public enum RemoteURL {
    /// The last path component of a remote URL, with a trailing `.git` stripped.
    ///
    /// Used to suggest a folder name while the user pastes `git@host:owner/repo.git`
    /// or `https://host/owner/repo.git`. Returns nil when nothing usable can be read.
    public static func suggestedDirectoryName(from raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        while value.hasSuffix("/") { value.removeLast() }
        if value.lowercased().hasSuffix(".git") {
            value = String(value.dropLast(4))
            while value.hasSuffix("/") { value.removeLast() }
        }
        guard !value.isEmpty else { return nil }

        let component: String
        if let url = URL(string: value), url.scheme != nil, url.host != nil {
            component = url.lastPathComponent
        } else if !value.contains("://"),
                  let colon = value.lastIndex(of: ":"),
                  value[value.startIndex..<colon].contains("@") {
            let rest = String(value[value.index(after: colon)...])
            component = URL(fileURLWithPath: rest).lastPathComponent
        } else {
            component = URL(fileURLWithPath: value).lastPathComponent
        }

        let name = component.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return name.isEmpty ? nil : name
    }
}
