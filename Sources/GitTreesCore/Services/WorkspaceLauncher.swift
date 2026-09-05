import AppKit
import Foundation
import Observation

/// An external application a worktree directory can be handed to.
public enum WorkspaceApplication: String, CaseIterable, Identifiable, Sendable, Codable {
    case finder
    case terminal
    case intelliJ
    case vsCode
    case cursor

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .finder: "Finder"
        case .terminal: "Terminal"
        case .intelliJ: "IntelliJ IDEA"
        case .vsCode: "VS Code"
        case .cursor: "Cursor"
        }
    }

    public var symbolName: String {
        switch self {
        case .finder: "folder"
        case .terminal: "terminal"
        case .intelliJ, .vsCode, .cursor: "chevron.left.forwardslash.chevron.right"
        }
    }

    /// Candidate bundle identifiers, most preferred first. IntelliJ ships as separate
    /// Ultimate and Community bundles.
    public var bundleIdentifiers: [String] {
        switch self {
        case .finder: ["com.apple.finder"]
        case .terminal: ["com.apple.Terminal"]
        case .intelliJ: ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"]
        case .vsCode: ["com.microsoft.VSCode", "com.visualstudio.code.oss"]
        case .cursor: ["com.todesktop.230313mzl4w4u92"]
        }
    }

    /// Applications offerable as "the IDE" in preferences and the toolbar.
    public static var editors: [WorkspaceApplication] { [.intelliJ, .vsCode, .cursor] }
}

/// Opens worktree directories in Finder, Terminal and the supported editors.
///
/// Everything goes through `NSWorkspace`, which is the supported way to launch an
/// application on macOS: no shell, and no dependency on a command line launcher
/// (`code`, `idea`) being installed on the user's `PATH`.
@MainActor
@Observable
public final class WorkspaceLauncher {
    public init() {}

    /// The installed application bundle for `application`, if there is one.
    public func applicationURL(for application: WorkspaceApplication) -> URL? {
        for identifier in application.bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                return url
            }
        }
        return nil
    }

    public func isInstalled(_ application: WorkspaceApplication) -> Bool {
        applicationURL(for: application) != nil
    }

    /// The editors actually present on this Mac, so the UI can hide the rest.
    public func installedEditors() -> [WorkspaceApplication] {
        WorkspaceApplication.editors.filter(isInstalled)
    }

    /// Opens `directory` in `application`.
    public func open(_ directory: URL, in application: WorkspaceApplication) async throws {
        switch application {
        case .finder:
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        default:
            guard let applicationURL = applicationURL(for: application) else {
                throw WorkspaceLauncherError.applicationNotInstalled(application.displayName)
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            do {
                _ = try await NSWorkspace.shared.open(
                    [directory],
                    withApplicationAt: applicationURL,
                    configuration: configuration
                )
            } catch {
                throw WorkspaceLauncherError.launchFailed(
                    application.displayName,
                    error.localizedDescription
                )
            }
        }
    }

    /// Reveals the directory in Finder, selecting it inside its parent.
    public func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

public enum WorkspaceLauncherError: Error, LocalizedError, Sendable {
    case applicationNotInstalled(String)
    case launchFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .applicationNotInstalled(let name):
            "\(name) is not installed."
        case .launchFailed(let name, let reason):
            "Could not open \(name): \(reason)"
        }
    }
}
