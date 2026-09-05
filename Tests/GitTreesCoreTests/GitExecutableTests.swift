import Foundation
import Testing
@testable import GitTreesCore

/// Covers the configurable git executable: the check Settings surfaces as a warning,
/// and the refusal that backs it.
@Suite("Git executable")
struct GitExecutableTests {

    static func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("gittrees-exe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a path with no executable is refused before anything is launched")
    func missingExecutableIsRefused() async throws {
        let runner = GitProcessRunner(executablePath: "/nonexistent/bin/git")

        await #expect(throws: GitError.self) {
            try await runner.run(GitCommand(["--version"]))
        }

        do {
            _ = try await runner.run(GitCommand(["--version"]))
            Issue.record("running a missing executable should have thrown")
        } catch let error as GitError {
            // Specifically not `launchFailed`: nothing was ever spawned.
            guard case .executableNotFound(let path) = error else {
                Issue.record("expected executableNotFound, got \(error)")
                return
            }
            #expect(path == "/nonexistent/bin/git")
            #expect(error.errorDescription?.contains("/nonexistent/bin/git") == true)
            #expect(error.recoverySuggestion?.isEmpty == false)
        }
    }

    @Test("a file that exists but is not executable is refused too")
    func nonExecutableFileIsRefused() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // The mistake this guards against: pointing the setting at a plain file.
        let file = directory.appendingPathComponent("git")
        try "not a program\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

        #expect(!FileManager.default.isExecutableFile(atPath: file.path))

        do {
            _ = try await GitProcessRunner(executablePath: file.path).run(GitCommand(["--version"]))
            Issue.record("running a non-executable file should have thrown")
        } catch let error as GitError {
            guard case .executableNotFound = error else {
                Issue.record("expected executableNotFound, got \(error)")
                return
            }
        }
    }

    @Test(
        "a custom executable path is honoured rather than falling back to the default",
        .enabled(if: FileManager.default.isExecutableFile(atPath: GitProcessRunner.defaultExecutablePath))
    )
    func customExecutablePathIsUsed() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Stands in for a Homebrew git at a non-default location.
        let alias = directory.appendingPathComponent("git")
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: URL(fileURLWithPath: GitProcessRunner.defaultExecutablePath)
        )

        let runner = GitProcessRunner(executablePath: alias.path)
        #expect(runner.executablePath == alias.path)

        let result = try await runner.run(GitCommand(["--version"]))
        #expect(result.exitCode == 0)
        #expect(result.trimmedStdout.hasPrefix("git version"))
    }

    @Test("the default is the system git, not a bare name resolved through PATH")
    func defaultIsAnAbsolutePath() {
        // A bare "git" would be resolved against the inherited PATH, which is exactly
        // the kind of ambiguity this application avoids.
        #expect(GitProcessRunner.defaultExecutablePath.hasPrefix("/"))
        #expect(GitProcessRunner().executablePath == GitProcessRunner.defaultExecutablePath)
    }
}
