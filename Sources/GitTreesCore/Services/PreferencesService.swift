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
        static let preferredEditor = "preferredEditor"
        static let openInEditorAfterCreate = "openInEditorAfterCreate"
        static let recentRepositories = "recentRepositories"
        static let lastRepositoryPath = "lastRepositoryPath"
        static let restoreLastRepository = "restoreLastRepository"
        static let worktreeRoots = "worktreeRoots"
        static let diffContextLines = "diffContextLines"
        static let showRemoteBranches = "showRemoteBranches"
    }

    /// The number of recently opened repositories kept in the Open Recent menu.
    public static let recentLimit = 12

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.gitExecutablePath = defaults.string(forKey: Key.gitExecutablePath)
            ?? GitProcessRunner.defaultExecutablePath
        self.preferredEditor = defaults.string(forKey: Key.preferredEditor)
            .flatMap(WorkspaceApplication.init(rawValue:)) ?? .intelliJ
        self.openInEditorAfterCreate = defaults.object(forKey: Key.openInEditorAfterCreate) as? Bool ?? false
        self.restoreLastRepository = defaults.object(forKey: Key.restoreLastRepository) as? Bool ?? true
        self.diffContextLines = defaults.object(forKey: Key.diffContextLines) as? Int ?? 3
        self.showRemoteBranches = defaults.object(forKey: Key.showRemoteBranches) as? Bool ?? false
        self.recentRepositories = Self.decode([RecentRepository].self, from: defaults, key: Key.recentRepositories) ?? []
        self.worktreeRoots = defaults.dictionary(forKey: Key.worktreeRoots) as? [String: String] ?? [:]
        self.lastRepositoryPath = defaults.string(forKey: Key.lastRepositoryPath)
    }

    // MARK: - Stored settings

    /// Which `git` binary to run. `/usr/bin/git` is the system shim; a user with a
    /// newer Git from Homebrew can point this at `/opt/homebrew/bin/git`.
    public var gitExecutablePath: String {
        didSet { defaults.set(gitExecutablePath, forKey: Key.gitExecutablePath) }
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

    public private(set) var lastRepositoryPath: String? {
        didSet { defaults.set(lastRepositoryPath, forKey: Key.lastRepositoryPath) }
    }

    // MARK: - Recent repositories

    public func noteOpened(_ repository: Repository) {
        var entries = recentRepositories.filter { $0.path != repository.mainWorktreePath }
        entries.insert(
            RecentRepository(path: repository.mainWorktreePath, name: repository.name),
            at: 0
        )
        recentRepositories = Array(entries.prefix(Self.recentLimit))
        lastRepositoryPath = repository.mainWorktreePath.path
    }

    public func removeRecent(_ recent: RecentRepository) {
        recentRepositories.removeAll { $0.id == recent.id }
    }

    public func clearRecents() {
        recentRepositories = []
    }

    /// The repository to reopen at launch, when the user has asked for that and the
    /// directory still exists.
    public func repositoryToRestore() -> URL? {
        guard restoreLastRepository, let path = lastRepositoryPath else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: path)
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
