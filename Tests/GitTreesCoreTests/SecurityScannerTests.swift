import Foundation
import Testing
@testable import GitTreesCore

@Suite("Security scanner")
struct SecurityScannerTests {
    let root = URL(fileURLWithPath: "/tmp/security-fixture")

    func output(paths: [String] = ["test.py"], errors: [[String: Any]] = [],
                matches: [[String: Any]] = [], exit: Int32 = 0) throws -> GitResult {
        GitResult(stdout: try JSONSerialization.data(withJSONObject: [
            "results": matches, "errors": errors, "paths": ["scanned": paths]
        ]), stderr: Data(), exitCode: exit)
    }

    func match(path: String = "test.py") -> [String: Any] {
        ["check_id": "gittrees.test", "path": path, "start": ["line": 4],
         "extra": ["severity": "WARNING", "message": "Review command input."]]
    }

    @Test("uses only local rules, disables metrics and never requests fixes")
    func arguments() throws {
        let rules = try #require(SecurityScanner.bundledRulesURL)
        #expect(FileManager.default.fileExists(atPath: rules.path))
        let args = SecurityScanner.arguments(rules: rules)
        #expect(args.contains("--metrics=off"))
        #expect(args.contains("--disable-version-check"))
        #expect(args.contains("--no-autofix"))
        #expect(args.contains("--oss-only"))
        #expect(!args.contains("--autofix"))
        #expect(args[args.firstIndex(of: "--config")! + 1] == rules.path)
        #expect(Array(args.suffix(2)) == ["--", "."])
    }

    @Test("parses findings and keeps distinct IDs for matches on the same line")
    func findings() throws {
        let report = try SecurityScanner.parse(output(matches: [match(), match()]), worktree: root)
        #expect(report.isComplete)
        #expect(report.findings.count == 2)
        #expect(Set(report.findings.map(\.id)).count == 2)
        #expect(report.findings.first?.line == 4)
    }

    @Test("errors, nonzero exits and empty scans cannot appear clean")
    func incomplete() throws {
        let nonzero = try SecurityScanner.parse(output(matches: [match()], exit: 2), worktree: root)
        #expect(!nonzero.isComplete)
        #expect(nonzero.findings.count == 1)
        #expect(!nonzero.issues.isEmpty)
        #expect(try !SecurityScanner.parse(output(errors: [["message": "Timed out"]]), worktree: root).isComplete)
        #expect(try !SecurityScanner.parse(output(paths: []), worktree: root).isComplete)
        #expect(try SecurityScanner.parse(output(), worktree: root).isComplete)
        #expect(throws: SecurityScanError.self) {
            try SecurityScanner.parse(GitResult(stdout: Data("{}".utf8), stderr: Data(), exitCode: 0), worktree: root)
        }
    }

    @Test("findings cannot reveal files outside the worktree, including symlinks")
    func containment() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/etc"))
        #expect(SecurityScanner.safeFile("../outside", in: directory) == nil)
        #expect(SecurityScanner.safeFile("/etc/hosts", in: directory) == nil)
        #expect(SecurityScanner.safeFile("escape/hosts", in: directory) == nil)
        #expect(SecurityScanner.safeFile("valid file.py", in: directory) != nil)
        let report = try SecurityScanner.parse(output(matches: [match(path: "../outside")]), worktree: directory)
        #expect(report.findings.isEmpty)
        #expect(!report.isComplete)
    }

    @Test("missing scanner fails with installation instructions")
    func missingExecutable() async {
        await #expect(throws: SecurityScanError.self) {
            try await SecurityScanner(executablePath: "/nonexistent/semgrep").scan(worktree: root)
        }
    }

    @Test("scanner executable preference persists") @MainActor
    func preference() {
        let (defaults, name) = PreferencesServiceTests.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        PreferencesService(defaults: defaults).semgrepExecutablePath = "/tmp/custom semgrep"
        #expect(PreferencesService(defaults: defaults).semgrepExecutablePath == "/tmp/custom semgrep")
    }

    @Test("live baseline finds unsafe examples and ignores safe argument arrays",
          .enabled(if: ProcessInfo.processInfo.environment["GITTREES_TEST_SEMGREP_PATH"] != nil))
    func liveBaseline() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["GITTREES_TEST_SEMGREP_PATH"])
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("gittrees-security-\(UUID())")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let files = [
            "unsafe.swift": "import Foundation\nlet p = Process()\np.arguments = [\"-c\", input]\nlet c = URLCredential(trust: trust)\n",
            "unsafe.py": "import subprocess\nimport yaml\nsubprocess.run(command, shell=True)\nyaml.unsafe_load(document)\n",
            "unsafe.js": "eval(input);\n",
            "Unsafe.java": "class Unsafe { void run(String input) throws Exception { Runtime.getRuntime().exec(input); } }\n",
            "Info.plist": "<plist><dict><key>NSAllowsArbitraryLoads</key><true/></dict></plist>\n",
            // Synthetic marker, not a real credential.
            "fixture.pem": "-----BEGIN PRIVATE KEY-----\nAAAAAAAAAAAAAAAAAAAAAA==\n-----END PRIVATE KEY-----\n",
            "safe.swift": "import Foundation\nlet p = Process()\np.arguments = [\"status\", \"--short\"]\n",
            "safe.py": "import subprocess\nimport yaml\nsubprocess.run([\"git\", \"status\"], shell=False)\nyaml.safe_load(document)\n"
        ]
        for (name, contents) in files {
            try contents.write(to: fixture.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let result = try await SecurityScanner(executablePath: executable).scan(worktree: fixture)
        #expect(result.isComplete, "Issues: \(result.issues)")
        #expect(Set(result.findings.map(\.rule)) == Set([
            "gittrees.swift-shell-command", "gittrees.swift-accept-server-trust",
            "gittrees.python-shell-execution", "gittrees.python-unsafe-yaml",
            "gittrees.javascript-eval", "gittrees.java-runtime-exec",
            "gittrees.private-key-material", "gittrees.ats-arbitrary-loads"
        ]))
        #expect(!result.findings.contains { $0.path.hasPrefix("safe.") })
        for (name, contents) in files {
            #expect(try String(contentsOf: fixture.appendingPathComponent(name), encoding: .utf8) == contents)
        }
    }
}
