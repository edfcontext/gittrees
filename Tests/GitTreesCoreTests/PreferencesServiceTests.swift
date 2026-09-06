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

    @Test("only the first wave of windows consumes the launch restore")
    func launchRestoreIsConsumedOnce() throws {
        let (defaults, name) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let preferences = PreferencesService(defaults: defaults)
        preferences.restoreLastRepository = true
        preferences.noteOpened(Self.repository(at: directory.path))

        let first = preferences.consumeLaunchRestore()
        #expect(first.map(\.path) == [directory.path])
        #expect(preferences.consumeLaunchRestore().isEmpty)
        #expect(preferences.repositoriesToRestore().map(\.path) == [directory.path])
    }

    @Test("every open repository is restored, in the order the windows were opened")
    func launchRestoreReturnsEveryOpenRepository() throws {
        let (defaults, name) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let firstDir = try Self.makeDirectory()
        let secondDir = try Self.makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: firstDir)
            try? FileManager.default.removeItem(at: secondDir)
        }

        let preferences = PreferencesService(defaults: defaults)
        preferences.restoreLastRepository = true
        preferences.noteOpened(Self.repository(at: firstDir.path))
        preferences.noteOpened(Self.repository(at: secondDir.path))
        preferences.noteOpened(Self.repository(at: firstDir.path))

        #expect(preferences.openRepositoryPaths == [firstDir.path, secondDir.path])
        #expect(preferences.consumeLaunchRestore().map(\.path) == [firstDir.path, secondDir.path])
    }

    @Test("a previous last-repository setting is promoted into the open-window list")
    func launchRestoreMigratesSingleLastRepository() throws {
        let (defaults, name) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        defaults.set(directory.path, forKey: "lastRepositoryPath")

        let preferences = PreferencesService(defaults: defaults)
        preferences.restoreLastRepository = true
        #expect(preferences.openRepositoryPaths == [directory.path])
        #expect(PreferencesService(defaults: defaults).openRepositoryPaths == [directory.path])
        #expect(preferences.consumeLaunchRestore().map(\.path) == [directory.path])
    }

    @Test("directories that no longer exist are skipped rather than restored")
    func launchRestoreSkipsMissingDirectories() throws {
        let (defaults, name) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let existing = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: existing) }

        let preferences = PreferencesService(defaults: defaults)
        preferences.restoreLastRepository = true
        preferences.noteOpened(Self.repository(at: existing.path))
        preferences.noteOpened(Self.repository(at: "/tmp/gittrees-does-not-exist-\(UUID().uuidString)"))

        #expect(preferences.repositoriesToRestore().map(\.path) == [existing.path])
    }

    @Test("closing a repository window drops it from the restore list")
    func forgetOpenRemovesFromRestoreList() throws {
        let (defaults, name) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let kept = try Self.makeDirectory()
        let closed = try Self.makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: kept)
            try? FileManager.default.removeItem(at: closed)
        }

        let preferences = PreferencesService(defaults: defaults)
        preferences.restoreLastRepository = true
        preferences.noteOpened(Self.repository(at: kept.path))
        preferences.noteOpened(Self.repository(at: closed.path))
        preferences.forgetOpen(closed.path)

        #expect(preferences.consumeLaunchRestore().map(\.path) == [kept.path])
    }

    @Test("restore can be turned off without forgetting which windows were open")
    func restoreToggleDoesNotClearOpenList() throws {
        let (defaults, name) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let preferences = PreferencesService(defaults: defaults)
        preferences.noteOpened(Self.repository(at: directory.path))
        preferences.restoreLastRepository = false

        #expect(preferences.consumeLaunchRestore().isEmpty)
        #expect(preferences.openRepositoryPaths == [directory.path])
    }

    @Test("the last New Repository parent is remembered")
    func workspaceParentPersists() throws {
        let (defaults, name) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let parent = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }

        let first = PreferencesService(defaults: defaults)
        first.noteWorkspaceParent(parent)
        #expect(first.defaultWorkspaceParent().standardizedFileURL == parent.standardizedFileURL)

        let second = PreferencesService(defaults: defaults)
        #expect(second.defaultWorkspaceParent().standardizedFileURL == parent.standardizedFileURL)
    }

    static func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gittrees-prefs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }
}
