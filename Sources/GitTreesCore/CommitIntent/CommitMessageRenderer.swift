import Foundation

/// Turns `{type, action, scope}` plus an optional object into a short subject.
///
/// Port of `runtime/renderer.py`. No model.
public enum CommitMessageRenderer {
    public enum Style: String, Sendable {
        case plain
        case conventional
    }

    private static let verb: [String: String] = [
        "ADD": "Add", "FIX": "Fix", "UPDATE": "Update", "REMOVE": "Remove",
        "REFACTOR": "Refactor", "IMPROVE": "Improve", "SUPPORT": "Support",
        "HANDLE": "Handle", "PREVENT": "Prevent", "RENAME": "Rename",
        "SIMPLIFY": "Simplify"
    ]

    private static let scopeNoun: [String: String] = [
        "WORKTREE": "worktree", "BRANCH": "branch", "REPOSITORY": "repository",
        "COMMIT": "commit", "STATUS": "status", "SETTINGS": "settings",
        "FILESYSTEM": "filesystem", "UI": "UI", "GIT": "git", "TESTS": "tests",
        "GENERAL": ""
    ]

    private static let conventionalType: [String: String] = [
        "FEATURE": "feat", "FIX": "fix", "REFACTOR": "refactor", "UI": "feat",
        "TEST": "test", "DOCS": "docs", "CONFIG": "chore", "DEPENDENCY": "build",
        "PERFORMANCE": "perf", "CLEANUP": "refactor"
    ]

    public static func render(
        _ intent: CommitIntent,
        object: String? = nil,
        style: Style = .plain
    ) -> String {
        let subject = subject(intent: intent, object: object)
        guard style == .conventional else { return subject }
        let ctype = conventionalType[intent.type] ?? "chore"
        let scope = scopeNoun[intent.scope] ?? ""
        let body: String
        if let first = subject.first {
            body = String(first).lowercased() + subject.dropFirst()
        } else {
            body = subject
        }
        return scope.isEmpty ? "\(ctype): \(body)" : "\(ctype)(\(scope)): \(body)"
    }

    private static func subject(intent: CommitIntent, object: String?) -> String {
        let word = Self.verb[intent.action] ?? "Update"
        let obj = (object ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !obj.isEmpty {
            return "\(word) \(obj)"
        }
        let noun = Self.scopeNoun[intent.scope] ?? ""
        if noun.isEmpty {
            return "\(word) changes"
        }
        let suffix = (intent.action == "ADD" || intent.action == "SUPPORT") ? "support" : "handling"
        return "\(word) \(noun) \(suffix)"
    }
}
