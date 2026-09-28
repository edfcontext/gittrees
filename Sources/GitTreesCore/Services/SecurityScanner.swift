import Foundation

public struct SecurityFinding: Identifiable, Sendable, Equatable {
    public let rule: String
    public let path: String
    public let line: Int
    public let severity: String
    public let message: String
    public let id: Int
}

public struct SecurityScanReport: Sendable {
    public let findings: [SecurityFinding]
    public let scannedFileCount: Int
    public let issues: [String]
    public let finishedAt: Date
    public var isComplete: Bool { issues.isEmpty && scannedFileCount > 0 }
}

public enum SecurityScanError: Error, LocalizedError {
    case unavailable(String)
    case failed(String)
    case invalidOutput

    public var errorDescription: String? {
        switch self {
        case .unavailable(let path): "Semgrep was not found at \(path). Install it with brew install semgrep or pipx install semgrep, then set its executable path in Settings → Security Scan."
        case .failed(let reason): "Security scan failed: \(reason)"
        case .invalidOutput: "Semgrep returned an unreadable report. The scan could not be verified."
        }
    }
}

/// Local Semgrep CE with bundled first-party rules. No registry, login, autofix or AI.
public struct SecurityScanner: Sendable {
    public static var defaultExecutablePath: String {
        ["/opt/homebrew/bin/semgrep", "/usr/local/bin/semgrep",
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/semgrep").path]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/semgrep"
    }

    public static var bundledRulesURL: URL? {
        Bundle.module.url(forResource: "baseline", withExtension: "yml", subdirectory: "SecurityRules")
    }

    public let executablePath: String
    public init(executablePath: String = Self.defaultExecutablePath) { self.executablePath = executablePath }

    static func arguments(rules: URL) -> [String] {
        ["scan", "--config", rules.path, "--oss-only", "--json", "--strict",
         "--metrics=off", "--disable-version-check", "--no-autofix", "--no-rewrite-rule-ids",
         "--timeout=5", "--max-target-bytes=1000000", "--jobs=2",
         "--exclude", ".build", "--exclude", ".git", "--exclude", "node_modules",
         "--exclude", ".venv*", "--exclude", "vendor", "--exclude", "*.mlpackage",
         "--", "."]
    }

    public func scan(worktree: URL) async throws -> SecurityScanReport {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw SecurityScanError.unavailable(executablePath)
        }
        guard let rules = Self.bundledRulesURL else {
            throw SecurityScanError.failed("The bundled security rules are missing. Rebuild the app with its resources.")
        }
        // Isolate Semgrep's settings/logs from both the scanned repository and existing
        // account settings. CLI environment knobs cannot opt this scan into cloud use.
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("gittrees-scan-\(UUID())")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: state) }
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("SEMGREP_") }
        environment["SEMGREP_SETTINGS_FILE"] = state.appendingPathComponent("settings.yml").path
        environment["SEMGREP_LOG_FILE"] = state.appendingPathComponent("scan.log").path
        environment["SEMGREP_SEND_METRICS"] = "off"
        environment["SEMGREP_ENABLE_VERSION_CHECK"] = "0"
        environment["NO_COLOR"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        // Finder-launched apps may lack package-manager paths required by CLI shebangs.
        environment["PATH"] = URL(fileURLWithPath: executablePath).deletingLastPathComponent().path
            + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:"
            + (environment["PATH"] ?? "")
        let result: GitResult
        do {
            result = try await Subprocess.run(executable: URL(fileURLWithPath: executablePath),
                arguments: Self.arguments(rules: rules), workingDirectory: worktree, environment: environment)
        } catch let error as ProcessLaunchFailure {
            throw SecurityScanError.failed(error.reason)
        }
        try Task.checkCancellation()
        // Nonzero exits may include usable findings plus errors. They must never be
        // represented as a clean scan, even if the JSON error list happens to be empty.
        return try Self.parse(result, worktree: worktree)
    }

    static func parse(_ result: GitResult, worktree: URL) throws -> SecurityScanReport {
        guard let root = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
              let matches = root["results"] as? [[String: Any]],
              let errors = root["errors"] as? [[String: Any]],
              let paths = root["paths"] as? [String: Any], let scanned = paths["scanned"] as? [String] else {
            if result.exitCode != 0 {
                throw SecurityScanError.failed(String(result.stderrText.prefix(2_000)))
            }
            throw SecurityScanError.invalidOutput
        }
        var issues = errors.map { ($0["message"] as? String) ?? ($0["short_msg"] as? String) ?? "Semgrep reported an analysis error." }
        if result.exitCode != 0 { issues.append("Semgrep exited with status \(result.exitCode). Results may be incomplete.") }
        if scanned.isEmpty { issues.append("No supported files were scanned. This is not a clean security result.") }
        var findings: [SecurityFinding] = []
        for (index, match) in matches.enumerated() {
            guard let rule = match["check_id"] as? String, let path = match["path"] as? String,
                  let start = match["start"] as? [String: Any], let line = start["line"] as? Int, line > 0,
                  let extra = match["extra"] as? [String: Any], let severity = extra["severity"] as? String,
                  let message = extra["message"] as? String else { throw SecurityScanError.invalidOutput }
            guard safeFile(path, in: worktree) != nil else {
                issues.append("A finding outside the selected worktree was omitted."); continue
            }
            findings.append(SecurityFinding(rule: rule, path: path, line: line, severity: severity, message: message, id: index))
        }
        return SecurityScanReport(findings: findings.sorted { ($0.path, $0.line, $0.rule) < ($1.path, $1.line, $1.rule) },
                                  scannedFileCount: scanned.count, issues: issues, finishedAt: Date())
    }

    public static func safeFile(_ path: String, in worktree: URL) -> URL? {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
        let root = worktree.resolvingSymlinksInPath().standardizedFileURL
        let file = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        return file.path.hasPrefix(root.path + "/") ? file : nil
    }
}
