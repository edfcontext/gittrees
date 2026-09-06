import Foundation
import Testing
@testable import GitTreesCore

@Suite("RemoteURL")
struct RemoteURLTests {

    @Test("HTTPS GitHub URLs yield the repository name")
    func httpsGitHub() {
        #expect(RemoteURL.suggestedDirectoryName(from: "https://github.com/owner/summit.git") == "summit")
        #expect(RemoteURL.suggestedDirectoryName(from: "https://github.com/owner/summit") == "summit")
        #expect(RemoteURL.suggestedDirectoryName(from: "  https://github.com/owner/summit.git  ") == "summit")
    }

    @Test("SSH scp-style URLs yield the repository name")
    func scpSSH() {
        #expect(RemoteURL.suggestedDirectoryName(from: "git@github.com:owner/summit.git") == "summit")
        #expect(RemoteURL.suggestedDirectoryName(from: "git@github.com:owner/summit") == "summit")
    }

    @Test("ssh:// URLs yield the repository name")
    func sshScheme() {
        #expect(RemoteURL.suggestedDirectoryName(from: "ssh://git@github.com/owner/summit.git") == "summit")
    }

    @Test("a nested group path still uses the last component")
    func nestedPath() {
        #expect(RemoteURL.suggestedDirectoryName(from: "https://gitlab.com/group/sub/repo.git") == "repo")
    }

    @Test("a local path yields the last component")
    func localPath() {
        #expect(RemoteURL.suggestedDirectoryName(from: "/tmp/local-mirror.git") == "local-mirror")
        #expect(RemoteURL.suggestedDirectoryName(from: "/tmp/local-mirror") == "local-mirror")
    }

    @Test("empty or unusable input yields nil")
    func emptyInput() {
        #expect(RemoteURL.suggestedDirectoryName(from: "") == nil)
        #expect(RemoteURL.suggestedDirectoryName(from: "   ") == nil)
        #expect(RemoteURL.suggestedDirectoryName(from: ".git") == nil)
    }
}
