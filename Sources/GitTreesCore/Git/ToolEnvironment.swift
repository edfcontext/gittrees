import Foundation

/// Finder-launched apps may inherit only the system PATH. Git filters, hooks,
/// credential helpers and gh's child Git processes also need installed tools.
enum ToolEnvironment {
    static func forProcess(executable: URL, pathOverride: String?) async -> [String: String] {
        var inherited = ProcessInfo.processInfo.environment
        if let pathOverride {
            inherited["PATH"] = pathOverride
            return inherited
        }
        return await addingSearchPaths(to: inherited, executable: executable) {
            await defaultNVMBin.value
        }
    }

    static func addingSearchPaths(
        to inherited: [String: String],
        executable: URL,
        nvmBin: () async -> String? = { nil }
    ) async -> [String: String] {
        var environment = inherited
        var paths = (inherited["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        // An absent PATH is different from an explicit empty component (current directory).
        if inherited["PATH"] == nil { paths = [] }
        let additionalPaths = [
            executable.deletingLastPathComponent().path,
            "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin"
        ]
        // Keep the matching npm ahead of standalone npm shims in the fallback paths.
        if !(paths + additionalPaths).contains(where: { path in
            path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path + "/node")
        }), let bin = await nvmBin(), !paths.contains(bin) {
            paths.append(bin)
        }
        for path in additionalPaths where !paths.contains(path) {
            paths.append(path)
        }
        environment["PATH"] = paths.joined(separator: ":")
        return environment
    }

    // Git refreshes start many short-lived commands. Resolve nvm's alias once per app launch.
    private static let defaultNVMBin = Task.detached {
        await resolveNVMBin(in: ProcessInfo.processInfo.environment)
    }

    static func resolveNVMBin(in inherited: [String: String]) async -> String? {
        let home = inherited["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        let directory = inherited["NVM_DIR"] ?? home + "/.nvm"
        guard directory.hasPrefix("/") else { return nil }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        let script = root.appendingPathComponent("nvm.sh")
        guard FileManager.default.isReadableFile(atPath: script.path) else { return nil }

        // Let nvm handle aliases and version ordering without loading shell startup files.
        let result = try? await Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", ". \"$1\" --no-use && nvm which default", "nvm", script.path],
            workingDirectory: root,
            environment: ["HOME": home, "NVM_DIR": directory, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        )
        guard let result, result.exitCode == 0 else { return nil }
        let node = result.trimmedStdout
        guard node.hasPrefix("/"), node.hasSuffix("/node"), !node.contains("\n"), !node.contains(":"),
              FileManager.default.isExecutableFile(atPath: node) else { return nil }
        return URL(fileURLWithPath: node).deletingLastPathComponent().path
    }
}
