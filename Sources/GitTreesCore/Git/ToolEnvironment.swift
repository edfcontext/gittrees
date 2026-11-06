import Foundation

/// Finder-launched apps may inherit only the system PATH. Git filters, hooks,
/// credential helpers and gh's child Git processes also need installed tools.
enum ToolEnvironment {
    static func addingSearchPaths(to inherited: [String: String], executable: URL) -> [String: String] {
        var environment = inherited
        var paths = (inherited["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        // An absent PATH is different from an explicit empty component (current directory).
        if inherited["PATH"] == nil { paths = [] }
        let additionalPaths = [
            executable.deletingLastPathComponent().path,
            "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin"
        ]
        for path in additionalPaths where !paths.contains(path) {
            paths.append(path)
        }
        environment["PATH"] = paths.joined(separator: ":")
        return environment
    }
}
