import Foundation

/// Conservative matches for known command diagnostics. Never match command arguments:
/// a filename or commit message containing an error phrase is not evidence of failure.
enum ErrorRecovery {
    struct Guidance {
        let summary: String
        let steps: [String]
    }

    static func guidance(for failure: GitFailure) -> Guidance? {
        let output = failure.message.lowercased()
        func contains(_ phrases: String...) -> Bool { phrases.contains { output.contains($0) } }
        func guide(_ summary: String, _ steps: String...) -> Guidance {
            Guidance(summary: summary, steps: steps)
        }

        if contains("git-lfs: command not found", "git-lfs: not found", "git: 'lfs' is not a git command") {
            return guide("This repository needs Git LFS, but Git could not find it.",
                         "Install Git LFS if needed (with Homebrew: brew install git-lfs), then run git lfs install in Terminal.",
                         "Quit and reopen GitTrees, then try again. If Git LFS is already installed, check that its executable is in a standard tool directory such as /opt/homebrew/bin or /usr/local/bin.")
        }
        if contains("host key verification failed", "remote host identification has changed") {
            return guide("SSH could not verify the remote server's identity.",
                         "Verify the server's SSH fingerprint with your Git host or administrator before changing any saved host keys.",
                         "Once the host identity is confirmed, repair the SSH known_hosts entry in Terminal and try again.")
        }
        if contains("permission denied (publickey", "authentication failed", "could not read username",
                    "terminal prompts disabled", "invalid username or token", "http 401", "http 403",
                    "gh auth login") {
            return guide("The remote server could not authenticate you, or your account lacks access.",
                         failure.program == "gh"
                            ? "Run gh auth login in Terminal for the GitHub host used by this repository, then try again."
                            : "Check the remote URL and your account's repository access. For SSH, ensure your key is loaded and registered with the Git host; for HTTPS, refresh the credentials in your credential manager.",
                         "Git may need an interactive sign-in. Open this worktree in Terminal to complete it, then retry in GitTrees.")
        }
        if contains("could not resolve host", "could not resolve hostname", "failed to connect",
                    "connection timed out", "connection refused", "network is unreachable", "connection reset") {
            return guide("Git could not connect to the remote server.",
                         "Check your internet connection, VPN and the repository's remote URL. Check whether the Git host is available.",
                         "Once connectivity is restored, refresh the worktree and check History before retrying; the server may have received part of the operation.")
        }
        if contains("ssl certificate problem", "server certificate verification failed") {
            return guide("Git could not verify the server's TLS certificate.",
                         "Check the Mac's date and time. If your organization uses a private certificate or proxy, ask its administrator to configure the trusted certificate for Git.",
                         "Retry after trust is configured. Keep certificate verification enabled.")
        }
        if contains("no space left on device", "disk quota exceeded") {
            return guide("Git could not write because the disk or storage quota is full.",
                         "Free space on the volume holding this repository, or ask for a larger storage quota.",
                         "Refresh the worktree and inspect Changes before retrying the operation.")
        }
        if contains(".lock") && contains("file exists", "another git process") {
            return guide("A Git lock is preventing this operation.",
                         "Wait for any running Git operation to finish, and close any commit editor that is still open. Then try again.",
                         "If the lock persists, confirm no Git process is using this repository before removing only the lock file named in the technical details. Ask for help if you are unsure.")
        }
        if contains("would be overwritten", "please commit your changes or stash", "please commit or stash",
                    "cannot pull with rebase: you have unstaged changes", "your index contains uncommitted changes") {
            return guide("Local changes are blocking this operation.",
                         "Review Changes, then commit or stash the work you want to keep. For a pull, you can use Stash, Pull & Re-apply.",
                         "If untracked files are listed, back them up or include them in a stash before continuing. Retry after the blocking files are protected.")
        }
        if contains("conflict (", "automatic merge failed", "unmerged files", "unresolved conflict",
                    "you need to resolve your current index first", "fix conflicts and then commit") {
            return guide("Git found conflicts that need to be resolved.",
                         "Open Changes, review each conflicted file, edit the final contents and stage the resolved files.",
                         "If a rebase is in progress, choose Continue. For a merge, commit the resolution. If a stash was involved, review the saved stash and recovery notice before applying it again.")
        }
        if contains("non-fast-forward", "(fetch first)", "[rejected] (stale info)", "(stale info)") {
            return guide("The remote branch has changes that this push would overwrite.",
                         "Fetch and review the incoming commits in History. Pull or rebase to integrate the remote changes, then resolve any conflicts and push again.",
                         "If you intentionally rewrote published history, review it with collaborators before using Force Push (With Lease).")
        }
        if contains("protected branch", "pre-receive hook declined", "hook declined", "repository rule violations") {
            return guide("A repository rule or hook rejected this operation.",
                         "Read the hook or server output in Technical details, and fix the reported checks or policy violations.",
                         "For a protected branch, push to a permitted branch and open a pull request, or ask a repository maintainer which workflow is required.")
        }
        if contains("need to specify how to reconcile divergent branches", "not possible to fast-forward") {
            return guide("The branches have diverged and cannot be updated by fast-forward alone.",
                         "Fetch and review both branches in History, then explicitly choose a merge or rebase from the Pull menu to integrate the commits.",
                         "Resolve any conflicts before continuing. Choose the strategy appropriate for your team's history policy.")
        }
        if contains("no tracking information", "has no upstream branch") {
            return guide("This branch has no upstream configured.",
                         "Check the selected remote. To publish a new branch, use Push (Set Upstream).",
                         "To follow an existing remote branch, configure it as this branch's upstream in Terminal, then pull.")
        }
        if contains("author identity unknown", "unable to auto-detect email address", "please tell me who you are") {
            return guide("Git needs your name and email before it can create a commit.",
                         "Open the Repository tab, enter your name and email under Commit Identity, and choose Set for This Repository. Then try the commit again.")
        }
        if contains("already checked out at", "already used by worktree") {
            return guide("This branch is already checked out in another worktree.",
                         "Select the existing worktree in the sidebar, or choose a different branch for the new worktree.",
                         "If that checkout no longer exists, review its unavailable-worktree notice before pruning the stale record.")
        }
        if contains("repository not found", "does not appear to be a git repository") {
            return guide("Git could not access the remote repository.",
                         "Check the remote URL, confirm the repository still exists and verify that your signed-in account has access.")
        }
        if contains("not a git repository") {
            return guide("Git could not find a valid repository at this location.",
                         "Check that the folder or external drive is available and that the checkout still contains its .git entry. Reopen the correct repository folder.")
        }
        if contains("permission denied", "operation not permitted", "read-only file system") {
            return guide("Git could not access a required file or folder.",
                         "Check the path in Technical details, its ownership and write permissions, and whether the volume is read-only. If macOS blocked access, review GitTrees under System Settings → Privacy & Security → Files and Folders.",
                         "Retry when the folder is accessible. Ask its owner or administrator for access if necessary.")
        }
        return nil
    }

    static func steps(for error: Error) -> [String]? {
        guard let error = error as? GitError else { return nil }
        switch error {
        case .operationInProgress:
            return ["Wait for the current operation to finish in this worktree, then try again."]
        case .invalidReferenceName:
            return ["Choose a branch or tag name without spaces, '..', or Git's special reference characters, then try again."]
        case .noLocalChanges:
            return ["Refresh Changes and select the worktree containing the edits you want to transfer."]
        default:
            return nil
        }
    }
}
