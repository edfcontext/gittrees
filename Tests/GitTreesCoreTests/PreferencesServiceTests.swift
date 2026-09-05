import Foundation
import Testing
@testable import GitTreesCore

@MainActor
@Suite("PreferencesService")
struct PreferencesServiceTests {

    /// A throwaway defaults suite so tests never touch the real application domain.
    static func makeDefaults() -> (UserDefaults, String) {
        let name = "com.gittrees.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    static func repository(at path: String = "/tmp/summit") -> Repository {
        Repository(
            mainWorktreePath: URL(fileURLWithPath: path),
            commonGitDir: URL(fileURLWithPath: path + "/.git"),
            isBare: false
        )
    }

    @Test("the preferred remote round-trips through UserDefaults")
    func preferredRemotePersists() {
        let (defaults, name) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let repository = Self.repository()

        let first = PreferencesService(defaults: defaults)
        #expect(first.preferredRemote(for: repository) == nil)

        first.setPreferredRemote("gitea", for: repository)
        #expect(first.preferredRemote(for: repository) == "gitea")

        // A fresh instance must see the stored value, which is what a relaunch does.
        let second = PreferencesService(defaults: defaults)
        #expect(second.preferredRemote(for: repository) == "gitea")

        second.setPreferredRemote(nil, for: repository)
        #expect(second.preferredRemote(for: repository) == nil)
        #expect(PreferencesService(defaults: defaults).preferredRemote(for: repository) == nil)
    }

    @Test("remotes are stored per repository, keyed by the shared git directory")
    func preferredRemoteIsPerRepository() {
        let (defaults, name) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let summit = Self.repository(at: "/tmp/summit")
        let other = Self.repository(at: "/tmp/other")
        let preferences = PreferencesService(defaults: defaults)

        preferences.setPreferredRemote("gitea", for: summit)
        #expect(preferences.preferredRemote(for: summit) == "gitea")
        #expect(preferences.preferredRemote(for: other) == nil)
    }

    @Test("a repository reached through a linked worktree resolves to the same key")
    func worktreesShareRepositoryScopedSettings() {
        let (defaults, name) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        // Both of these are what `discoverRepository` produces from the main worktree
        // and from a linked worktree: the same common git dir.
        let fromMain = Self.repository(at: "/tmp/summit")
        let fromLinked = Repository(
            mainWorktreePath: URL(fileURLWithPath: "/tmp/summit"),
            commonGitDir: URL(fileURLWithPath: "/tmp/summit/.git"),
            isBare: false
        )
        #expect(fromMain.id == fromLinked.id)

        let preferences = PreferencesService(defaults: defaults)
        preferences.setPreferredRemote("gitea", for: fromMain)
        #expect(preferences.preferredRemote(for: fromLinked) == "gitea")

        preferences.setWorktreeRoot(URL(fileURLWithPath: "/tmp/wt"), for: fromMain)
        #expect(preferences.worktreeRoot(for: fromLinked).path == "/tmp/wt")
    }

    @Test("the worktree root falls back to the convention when none is stored")
    func worktreeRootDefault() {
        let (defaults, name) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let repository = Self.repository(at: "/Users/me/Development/nalcus/summit")
        let preferences = PreferencesService(defaults: defaults)

        #expect(!preferences.hasCustomWorktreeRoot(for: repository))
        #expect(
            preferences.worktreeRoot(for: repository).path
                == "/Users/me/Development/nalcus/worktrees/summit"
        )
    }

    @Test("only the first window consumes the launch restore")
    func launchRestoreIsConsumedOnce() {
        let (defaults, name) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let preferences = PreferencesService(defaults: defaults)
        preferences.restoreLastRepository = true
        preferences.noteOpened(Self.repository(at: "/tmp"))

        let first = preferences.consumeLaunchRestore()
        #expect(first?.path == "/tmp")
        #expect(preferences.consumeLaunchRestore() == nil)
        #expect(preferences.repositoryToRestore()?.path == "/tmp")
    }
}
