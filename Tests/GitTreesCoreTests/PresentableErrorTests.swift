import Foundation
import Testing
@testable import GitTreesCore

@Suite("Error explanations and recovery")
struct PresentableErrorTests {
    private func present(
        _ stderr: String, stdout: String = "", program: String = "git", arguments: [String] = ["pull"]
    ) -> PresentableError {
        let failure = GitFailure(
            program: program, arguments: arguments, workingDirectory: "/tmp/example repo",
            exitCode: 1, stdout: stdout, stderr: stderr
        )
        let error: Error = program == "gh" ? GitHubError.commandFailed(failure) : GitError.commandFailed(failure)
        return PresentableError(title: "Operation Failed", error: error)
    }

    @Test("known diagnostics produce specific guidance", arguments: [
        ("git-lfs filter-process: git-lfs: command not found\nfatal: the remote end hung up unexpectedly", "Git LFS", "brew install git-lfs"),
        ("pre-push: git-lfs is required but was not found on PATH.", "Git LFS", "brew install git-lfs"),
        ("Permission denied (publickey).", "authenticate", "SSH"),
        ("Host key verification failed.", "server's identity", "fingerprint"),
        ("fatal: Could not resolve host: example.com", "connect", "VPN"),
        ("fatal: SSL certificate problem: unable to get local issuer certificate", "certificate", "trusted certificate"),
        ("fatal: No space left on device", "full", "Free space"),
        ("fatal: Unable to create '/repo/.git/index.lock': File exists.", "lock", "confirm no Git process"),
        ("error: Your local changes to the following files would be overwritten by merge:", "Local changes", "commit or stash"),
        ("CONFLICT (content): Merge conflict in file.txt\nAutomatic merge failed; fix conflicts and then commit the result.", "conflicts", "stage"),
        ("! [rejected] main -> main (fetch first)", "remote branch", "Fetch"),
        ("! [rejected] main -> main (non-fast-forward)", "remote branch", "Fetch"),
        ("! [rejected] main -> main (stale info)", "remote branch", "Fetch"),
        ("remote: error: GH006: Protected branch update failed", "rule or hook", "pull request"),
        ("fatal: Need to specify how to reconcile divergent branches.", "diverged", "merge or rebase"),
        ("fatal: The current branch topic has no upstream branch.", "upstream", "Push (Set Upstream)"),
        ("Author identity unknown\n*** Please tell me who you are.", "name and email", "Commit Identity"),
        ("fatal: 'topic' is already checked out at '/tmp/other'", "another worktree", "sidebar"),
        ("remote: Repository not found.", "remote repository", "account"),
        ("fatal: not a git repository (or any of the parent directories): .git", "valid repository", ".git"),
        ("error: open('file.txt'): Permission denied", "file or folder", "permissions")
    ])
    func recognizedFailure(_ sample: (String, String, String)) {
        let error = present(sample.0)
        #expect(error.summary.contains(sample.1))
        #expect(error.recoveryText.contains(sample.2))
        #expect(error.diagnosticText.contains(sample.0))
        #expect(!error.recoverySteps.isEmpty)
    }

    @Test("a push that cannot start Node explains the cause and preserves Git's output")
    func missingNodeDuringPush() {
        let stderr = """
            env: node: No such file or directory
            error: failed to push some refs to 'github-ctx:edfcontext/TheArcherJS.git'
            """
        let error = present(stderr, arguments: GitCommand.globalFlags + ["push"])
        #expect(error.summary.contains("Node.js"))
        #expect(error.recoveryText.contains("node --version"))
        #expect(error.recoveryText.contains("nvm"))
        #expect(error.reportText.contains("stderr:\n" + stderr))
    }

    @Test("shell and env errors identify the missing executable", arguments: [
        ("env: ‘pnpm’: No such file or directory", "pnpm"),
        ("/usr/bin/env: python3: No such file or directory", "python3"),
        ("tools/git-hooks/pre-push: line 7: npm: command not found", "npm"),
        ("/bin/sh: line 1: yarn: command not found", "yarn"),
        ("sh: 1: ruby: not found", "ruby"),
        ("zsh: command not found: pre-commit", "pre-commit")
    ])
    func missingLocalExecutable(_ sample: (String, String)) {
        let error = present(sample.0, arguments: ["commit"])
        #expect(error.summary.contains(sample.1))
        #expect(error.recoveryText.contains("command -v " + sample.1))
    }

    @Test("remote output, patches and missing files do not identify a missing local executable", arguments: [
        "remote: env: node: No such file or directory",
        "+ env: node: No such file or directory",
        "+ tools/git-hooks/pre-push: line 7: node: command not found",
        "config.json: not found",
        "fatal: config.json: No such file or directory",
        "Error: Cannot find module 'node'"
    ])
    func ambiguousMissingFile(_ stderr: String) {
        let error = present(stderr, arguments: ["push"])
        #expect(error.summary.contains("could not complete"))
        #expect(error.diagnosticText.contains(stderr))
    }

    @Test("GitHub CLI authentication guidance uses gh, rather than Git HTTPS credentials")
    func gitHubAuthentication() {
        let error = present("HTTP 401: Bad credentials", program: "gh", arguments: ["pr", "create"])
        #expect(error.recoveryText.contains("gh auth login"))
        #expect(error.diagnosticText.contains("gh pr create"))
    }

    @Test("a generic failure preserves both full streams, command, directory and exit code")
    func unknownFailure() {
        let output = String(repeating: "large output with details\n", count: 2_000)
        let error = present("an unrecognized failure", stdout: output)
        #expect(error.message == "an unrecognized failure")
        #expect(error.summary.contains("could not complete"))
        #expect(error.recoveryText.contains("Copy Details"))
        #expect(error.reportText.contains("stdout:\n" + output))
        #expect(error.reportText.contains("stderr:\nan unrecognized failure"))
        #expect(error.reportText.contains("directory: /tmp/example repo"))
        #expect(error.reportText.contains("exit code: 1"))
        #expect(error.reportText.components(separatedBy: output).count == 2)
    }

    @Test("stdout is classified when stderr is empty, but diagnostic-like arguments are ignored")
    func stdoutAndArguments() {
        let conflict = present("", stdout: "CONFLICT (content): Merge conflict in file.txt")
        #expect(conflict.summary.contains("conflicts"))
        let other = present("unrecognized failure", arguments: ["commit", "-m", "Fix Permission denied (publickey)"])
        #expect(other.summary.contains("could not complete"))
        #expect(!other.recoveryText.contains("SSH"))
        let patch = present("unrecognized failure", stdout: "+ fatal: Authentication failed")
        #expect(!patch.recoveryText.contains("SSH"))
    }

    @Test("existing LocalizedError recovery suggestions are guidance, not raw diagnostics")
    func localizedRecovery() {
        let missingGit = PresentableError(title: "Missing Git", error: GitError.executableNotFound(path: "/missing/git"))
        #expect(missingGit.summary.contains("/missing/git"))
        #expect(missingGit.recoveryText.contains("Xcode Command Line Tools"))
        #expect(missingGit.detail == nil)
        let github = PresentableError(title: "Sign In", error: GitHubError.notAuthenticated)
        #expect(github.recoveryText.contains("gh auth login"))
    }

    @Test("authored recovery messages and explicit steps take precedence over nested diagnostics")
    func authoredRecovery() {
        var error = PresentableError(
            title: "Re-applied With Conflicts",
            message: "Changes are saved in stash abc1234. Some files need review.",
            detail: "CONFLICT (content): Merge conflict in file.txt",
            recoverySteps: ["Review Changes and the saved stash before applying it again."]
        )
        #expect(error.summary == error.message)
        #expect(error.reportText.contains("stash abc1234"))
        #expect(error.recoverySteps == ["Review Changes and the saved stash before applying it again."])
        error.detail = "more output\n" + (error.detail ?? "")
        #expect(error.reportText.contains("more output"))
    }

    @Test("non-command errors always have a recovery path")
    func nonCommandFailure() {
        let error = PresentableError(title: "Could Not Open", error: CocoaError(.fileReadNoSuchFile))
        #expect(!error.summary.isEmpty)
        #expect(!error.recoverySteps.isEmpty)
        #expect(error.reportText.contains("How to resolve"))
        let invalidName = PresentableError(title: "Could Not Create Tag", error: GitError.invalidReferenceName(name: "bad name"))
        #expect(invalidName.recoveryText.contains("without spaces"))
    }
}
