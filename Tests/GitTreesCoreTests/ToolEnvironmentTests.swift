import Foundation
import Testing
@testable import GitTreesCore

@Suite("Tool environment")
struct ToolEnvironmentTests {
    @Test("a desktop PATH gains package manager tools without changing existing precedence")
    func desktopSearchPath() async {
        let inherited = ["PATH": "/custom/bin:/usr/bin:/bin", "HOME": "/Users/example"]
        let environment = await ToolEnvironment.addingSearchPaths(
            to: inherited, executable: URL(fileURLWithPath: "/custom/git/bin/git")
        )
        let paths = environment["PATH"]!.components(separatedBy: ":")
        #expect(Array(paths.prefix(3)) == ["/custom/bin", "/usr/bin", "/bin"])
        #expect(paths.contains("/custom/git/bin"))
        #expect(paths.contains("/opt/homebrew/bin"))
        #expect(paths.contains("/usr/local/bin"))
        #expect(paths.contains("/opt/local/bin"))
        #expect(paths.filter { $0 == "/usr/bin" }.count == 1)
        #expect(environment["HOME"] == inherited["HOME"])
    }

    @Test("a missing PATH is usable without adding the working directory")
    func missingSearchPath() async {
        let environment = await ToolEnvironment.addingSearchPaths(
            to: [:], executable: URL(fileURLWithPath: "/usr/bin/git")
        )
        let paths = environment["PATH"]!.components(separatedBy: ":")
        #expect(!paths.contains(""))
        #expect(paths.contains("/bin"))
        #expect(paths.contains("/opt/homebrew/bin"))
    }

    @Test("nvm lookup finds the default Node even when the desktop PATH has no nvm tools")
    func nvmLookup() async throws {
        let home = try GitExecutableTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let nvm = home.appendingPathComponent("custom nvm")
        let bin = nvm.appendingPathComponent("versions/node/v24.19.0/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let node = bin.appendingPathComponent("node")
        try "#!/bin/sh\n".write(to: node, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)
        try """
            nvm() {
                [ "$1" = which ] && [ "$2" = default ] || return 1
                printf '%s\\n' "$NVM_DIR/versions/node/v24.19.0/bin/node"
            }
            """.write(to: nvm.appendingPathComponent("nvm.sh"), atomically: true, encoding: .utf8)

        let inherited = ["PATH": "/usr/bin:/bin", "HOME": home.path, "NVM_DIR": nvm.path]
        #expect(await ToolEnvironment.resolveNVMBin(in: inherited) == bin.path)
        let active = inherited.merging(["PATH": bin.path + ":/usr/bin:/bin"]) { _, new in new }
        let environment = await ToolEnvironment.addingSearchPaths(
            to: active, executable: URL(fileURLWithPath: "/usr/bin/git")
        ) {
            Issue.record("An inherited Node should take precedence over nvm's default")
            return nil
        }
        #expect(environment["PATH"]?.components(separatedBy: ":").first == bin.path)
    }

    @Test("both runners make sibling helpers available and honour explicit PATH overrides")
    func runnersFindHelpers() async throws {
        let directory = try GitExecutableTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let helperName = "gittrees-helper-\(UUID().uuidString)"
        let helper = directory.appendingPathComponent(helperName)
        try "#!/bin/sh\nprintf 'helper found'\n".write(to: helper, atomically: true, encoding: .utf8)
        let executable = directory.appendingPathComponent("tool")
        try "#!/bin/sh\nexec \(helperName)\n".write(to: executable, atomically: true, encoding: .utf8)
        for file in [helper, executable] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }

        let git = GitProcessRunner(executablePath: executable.path)
        let gh = GitHubProcessRunner(executablePath: executable.path)
        #expect(try await git.run(GitCommand(["--version"])).trimmedStdout == "helper found")
        #expect(try await gh.run(GitHubCommand(["--version"])).trimmedStdout == "helper found")

        let overrides = ["PATH": "/usr/bin:/bin"]
        let gitResult = try await git.run(GitCommand(
            ["--version"], environmentOverrides: overrides, acceptableExitCodes: [127]
        ))
        let ghResult = try await gh.run(GitHubCommand(
            ["--version"], environmentOverrides: overrides, acceptableExitCodes: [127]
        ))
        #expect(gitResult.exitCode == 127)
        #expect(ghResult.exitCode == 127)
    }

    @Test("staging an LFS asset stores a pointer using the installed filter", .enabled(if:
        ["/opt/homebrew/bin/git-lfs", "/usr/local/bin/git-lfs", "/opt/local/bin/git-lfs"]
            .contains { FileManager.default.isExecutableFile(atPath: $0) }
    ))
    func stagesLFSAsset() async throws {
        let directory = try GitExecutableTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = GitProcessRunner()
        let environment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"]
        func git(_ arguments: [String]) async throws -> GitResult {
            try await runner.run(GitCommand(
                arguments, workingDirectory: directory, environmentOverrides: environment
            ))
        }

        _ = try await git(["init", "--quiet"])
        _ = try await git(["config", "filter.lfs.process", "git-lfs filter-process"])
        _ = try await git(["config", "filter.lfs.required", "true"])
        try "*.bin filter=lfs diff=lfs merge=lfs -text\n".write(
            to: directory.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8
        )
        let contents = Data("asset contents\n".utf8)
        try contents.write(to: directory.appendingPathComponent("asset.bin"))
        _ = try await git(["add", "--", ".gitattributes", "asset.bin"])
        let staged = try await git(["show", ":asset.bin"])
        #expect(staged.stdoutText.hasPrefix("version https://git-lfs.github.com/spec/v1\n"))
        #expect(staged.stdoutText.contains("oid sha256:"))
        #expect(staged.stdoutText.contains("size \(contents.count)\n"))
        #expect(try Data(contentsOf: directory.appendingPathComponent("asset.bin")) == contents)
    }
}
