import Foundation
import Observation

/// Application preferences, backed by `UserDefaults`.
///
/// Per-repository settings (the worktree root) are keyed by the repository's common
/// git directory, so every worktree of a repository resolves to the same entry.
@MainActor
@Observable
public final class PreferencesService {
    private enum Key {
        static let gitExecutablePath = "gitExecutablePath"
        static let gitHubExecutablePath = "gitHubExecutablePath"
        static let preferredEditor = "preferredEditor"
        static let openInEditorAfterCreate = "openInEditorAfterCreate"
        static let recentRepositories = "recentRepositories"
        static let lastRepositoryPath = "lastRepositoryPath"
        static let openRepositoryPaths = "openRepositoryPaths"
        static let restoreLastRepository = "restoreLastRepository"
        static let worktreeRoots = "worktreeRoots"
        static let diffContextLines = "diffContextLines"
        static let showRemoteBranches = "showRemoteBranches"
        static let preferredRemotes = "preferredRemotes"
    }

    /// The number of recently opened repositories kept in the Open Recent menu.
    public static let recentLimit = 12

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.gitExecutablePath = defaults.string(forKey: Key.gitExecutablePath)
            ?? GitProcessRunner.defaultExecutablePath
        self.gitHubExecutablePath = defaults.string(forKey: Key.gitHubExecutablePath)
            ?? GitHubProcessRunner.defaultExecutablePath
        self.preferredEditor = defaults.string(forKey: Key.preferredEditor)
            .flatMap(WorkspaceApplication.init(rawValue:)) ?? .intelliJ
        self.openInEditorAfterCreate = defaults.object(forKey: Key.openInEditorAfterCreate) as? Bool ?? false
        self.restoreLastRepository = defaults.object(forKey: Key.restoreLastRepository) as? Bool ?? true
        self.diffContextLines = defaults.object(forKey: Key.diffContextLines) as? Int ?? 3
        self.showRemoteBranches = defaults.object(forKey: Key.showRemoteBranches) as? Bool ?? false
        self.recentRepositories = Self.decode([RecentRepository].self, from: defaults, key: Key.recentRepositories) ?? []
        self.worktreeRoots = defaults.dictionary(forKey: Key.worktreeRoots) as? [String: String] ?? [:]
        self.preferredRemotes = defaults.dictionary(forKey: Key.preferredRemotes) as? [String: String] ?? [:]
        let lastPath = defaults.string(forKey: Key.lastRepositoryPath)
        self.lastRepositoryPath = lastPath
        // A previous version stored only the last window. Lift that into the list so
        // an upgrade still reopens it, then prefer the multi-window list once written.
        if let stored = defaults.stringArray(forKey: Key.openRepositoryPaths), !stored.isEmpty {
            self.openRepositoryPaths = stored
        } else if let lastPath {
            self.openRepositoryPaths = [lastPath]
        } else {
            self.openRepositoryPaths = []
        }
        defaults.set(openRepositoryPaths, forKey: Key.openRepositoryPaths)
    }

    // MARK: - Stored settings

    /// Which `git` binary to run. `/usr/bin/git` is the system shim; a user with a
    /// newer Git from Homebrew can point this at `/opt/homebrew/bin/git`.
    public var gitExecutablePath: String {
        didSet { defaults.set(gitExecutablePath, forKey: Key.gitExecutablePath) }
    }

    /// Which `gh` binary to run. Defaults to the first known install location; a user
    /// whose GitHub CLI lives elsewhere can point this at it.
    public var gitHubExecutablePath: String {
        didSet { defaults.set(gitHubExecutablePath, forKey: Key.gitHubExecutablePath) }
    }

    public var preferredEditor: WorkspaceApplication {
        didSet { defaults.set(preferredEditor.rawValue, forKey: Key.preferredEditor) }
    }

    public var openInEditorAfterCreate: Bool {
        didSet { defaults.set(openInEditorAfterCreate, forKey: Key.openInEditorAfterCreate) }
    }

    public var restoreLastRepository: Bool {
        didSet { defaults.set(restoreLastRepository, forKey: Key.restoreLastRepository) }
    }

    public var diffContextLines: Int {
        didSet { defaults.set(diffContextLines, forKey: Key.diffContextLines) }
    }

    public var showRemoteBranches: Bool {
        didSet { defaults.set(showRemoteBranches, forKey: Key.showRemoteBranches) }
    }

    public private(set) var recentRepositories: [RecentRepository] {
        didSet { Self.encode(recentRepositories, into: defaults, key: Key.recentRepositories) }
    }

    private var worktreeRoots: [String: String] {
        didSet { defaults.set(worktreeRoots, forKey: Key.worktreeRoots) }
    }

    private var preferredRemotes: [String: String] {
        didSet { defaults.set(preferredRemotes, forKey: Key.preferredRemotes) }
    }

    public private(set) var lastRepositoryPath: String? {
        didSet { defaults.set(lastRepositoryPath, forKey: Key.lastRepositoryPath) }
    }

    /// Paths of repository windows open in the current session, in open order.
    public private(set) var openRepositoryPaths: [String] {
        didSet { defaults.set(openRepositoryPaths, forKey: Key.openRepositoryPaths) }
    }

    /// In-memory: launch restore is handed out once so extra windows opened later
    /// stay empty rather than repeating the session.
    private var didConsumeLaunchRestore = false

    // MARK: - Recent repositories

    public func noteOpened(_ repository: Repository) {
        var entries = recentRepositories.filter { $0.path != repository.mainWorktreePath }
        entries.insert(
            RecentRepository(path: repository.mainWorktreePath, name: repository.name),
            at: 0
        )
        recentRepositories = Array(entries.prefix(Self.recentLimit))
        let path = repository.mainWorktreePath.path
        lastRepositoryPath = path
        rememberOpen(path)
    }

    /// Records a repository window as part of the session to restore at next launch.
    public func rememberOpen(_ path: String) {
        if !openRepositoryPaths.contains(path) {
            openRepositoryPaths.append(path)
        }
    }

    /// Drops a repository window from the restore list (the window closed, or the
    /// repository was closed in place).
    public func forgetOpen(_ path: String) {
        openRepositoryPaths.removeAll { $0 == path }
    }

    public func removeRecent(_ recent: RecentRepository) {
        recentRepositories.removeAll { $0.id == recent.id }
    }

    public func clearRecents() {
        recentRepositories = []
    }

    /// Directories of repository windows to reopen at launch, skipping any that
    /// no longer exist on disk.
    public func repositoriesToRestore() -> [URL] {
        guard restoreLastRepository else { return [] }
        return openRepositoryPaths.compactMap { path in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return nil
            }
            return URL(fileURLWithPath: path)
        }
    }

    /// Returns every restore URL once. The first window opens the first path and
    /// creates further windows for the rest; later New Window calls stay empty.
    public func consumeLaunchRestore() -> [URL] {
        guard !didConsumeLaunchRestore else { return [] }
        didConsumeLaunchRestore = true
        return repositoriesToRestore()
    }

    // MARK: - Per-repository worktree root

    /// The configured worktree root for a repository, or the convention-based default.
    public func worktreeRoot(for repository: Repository) -> URL {
        if let stored = worktreeRoots[repository.id], !stored.isEmpty {
            return URL(fileURLWithPath: (stored as NSString).expandingTildeInPath)
        }
        return WorktreePathSuggester.defaultWorktreeRoot(forRepositoryAt: repository.mainWorktreePath)
    }

    public func setWorktreeRoot(_ root: URL?, for repository: Repository) {
        if let root {
            worktreeRoots[repository.id] = root.path
        } else {
            worktreeRoots.removeValue(forKey: repository.id)
        }
    }

    public func hasCustomWorktreeRoot(for repository: Repository) -> Bool {
        worktreeRoots[repository.id] != nil
    }

    // MARK: - Per-repository remote

    /// The remote the user last chose for this repository, if any.
    ///
    /// Nil means "let Git decide" — fetch every remote, and let pull and push follow the
    /// branch's own tracking configuration.
    public func preferredRemote(for repository: Repository) -> String? {
        preferredRemotes[repository.id]
    }

    public func setPreferredRemote(_ remote: String?, for repository: Repository) {
        if let remote, !remote.isEmpty {
            preferredRemotes[repository.id] = remote
        } else {
            preferredRemotes.removeValue(forKey: repository.id)
        }
    }

    // MARK: - Codable storage

    private static func encode<T: Encodable>(_ value: T, into defaults: UserDefaults, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
