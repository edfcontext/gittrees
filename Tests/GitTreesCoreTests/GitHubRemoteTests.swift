import Testing
@testable import GitTreesCore

/// Cover for deciding whether a remote is a GitHub remote — the gate that shows or hides
/// the Create Pull Request button.
///
/// The subtle case, and the reason this file exists, is the SSH host alias: a remote
/// written `git@github-work:owner/repo` is a GitHub repo but the URL never says so, so the
/// decision has to resolve the alias through ssh config the way `gh` does.
@Suite("GitHub remote detection")
struct GitHubRemoteTests {

    // A stand-in for ~/.ssh/config with two GitHub aliases, one non-GitHub alias, and a
    // glob — enough to exercise resolution without touching the real file.
    private let config = SSHConfig(text: """
        Host github-work
          HostName github.com
          IdentityFile ~/.ssh/id_ed25519_wesco

        Host github-ctx
          User git
          HostName github.com

        Host gh-*
          HostName github.com

        Host gitlab-work
          HostName gitlab.com
        """)

    @Test("literal github.com remotes are GitHub, in every URL form")
    func literalGitHub() {
        let empty = SSHConfig(text: "")
        for url in [
            "git@github.com:owner/repo.git",
            "https://github.com/owner/repo",
            "https://github.com/owner/repo.git",
            "ssh://git@github.com/owner/repo.git",
            "GIT@GITHUB.COM:Owner/Repo.git"   // case-insensitive
        ] {
            #expect(GitHubClient.isGitHubRemoteURL(url, sshConfig: empty), "\(url)")
        }
    }

    @Test("an SSH alias that resolves to github.com is GitHub")
    func aliasResolvesToGitHub() {
        #expect(GitHubClient.isGitHubRemoteURL("git@github-work:WESCO-International/WMX_DDP.git", sshConfig: config))
        #expect(GitHubClient.isGitHubRemoteURL("git@github-ctx:edfcontext/gittrees.git", sshConfig: config))
        #expect(GitHubClient.isGitHubRemoteURL("ssh://git@github-ctx/edfcontext/gittrees.git", sshConfig: config))
        // matched by the `gh-*` glob
        #expect(GitHubClient.isGitHubRemoteURL("git@gh-personal:me/thing.git", sshConfig: config))
    }

    @Test("an alias that resolves elsewhere, or is unknown, is not GitHub")
    func nonGitHubHostsAreRejected() {
        #expect(!GitHubClient.isGitHubRemoteURL("git@gitlab-work:team/app.git", sshConfig: config))   // -> gitlab.com
        #expect(!GitHubClient.isGitHubRemoteURL("git@bitbucket.org:team/app.git", sshConfig: config))
        #expect(!GitHubClient.isGitHubRemoteURL("https://dev.azure.com/org/proj/_git/repo", sshConfig: config))
        #expect(!GitHubClient.isGitHubRemoteURL("git@unknown-alias:me/thing.git", sshConfig: config)) // not in config
    }

    @Test("a local path is not a remote host")
    func localPathIsNotGitHub() {
        let empty = SSHConfig(text: "")
        #expect(!GitHubClient.isGitHubRemoteURL("/Users/me/repos/thing", sshConfig: empty))
        #expect(!GitHubClient.isGitHubRemoteURL("../sibling", sshConfig: empty))
        #expect(!GitHubClient.isGitHubRemoteURL("", sshConfig: empty))
    }

    @Test("host extraction strips user and port across forms")
    func hostExtraction() {
        #expect(GitHubClient.remoteHost("git@github.com:owner/repo.git") == "github.com")
        #expect(GitHubClient.remoteHost("https://github.com/owner/repo") == "github.com")
        #expect(GitHubClient.remoteHost("ssh://git@github-ctx:22/owner/repo") == "github-ctx")
        #expect(GitHubClient.remoteHost("github-work:owner/repo") == "github-work")   // no user
        #expect(GitHubClient.remoteHost("/local/path") == nil)
    }

    @Test("ssh negation excludes a block that would otherwise match")
    func negationExcludes() {
        let cfg = SSHConfig(text: """
            Host github-* !github-personal
              HostName github.com
            """)
        #expect(cfg.hostName(for: "github-work") == "github.com")
        #expect(cfg.hostName(for: "github-personal") == nil)   // negated out
    }
}
