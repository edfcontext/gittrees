import GitTreesCore
import SwiftUI

/// Application-wide settings: which git and gh binaries to run, the preferred IDE,
/// and a few display options. Per-repository settings live on the Repository tab.
struct PreferencesView: View {
    @Environment(PreferencesService.self) private var preferences
    @Environment(RepositoryService.self) private var service
    @Environment(WorkspaceLauncher.self) private var launcher

    @State private var choosingGitExecutable = false
    @State private var choosingGitHubExecutable = false

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section("Git") {
                LabelledFieldRow(label: "Git executable") {
                    HStack(spacing: 6) {
                        TextField("", text: $preferences.gitExecutablePath)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .font(GitTreesUI.monospaced)
                        Button("Choose…") { choosingGitExecutable = true }
                            .fileImporter(
                                isPresented: $choosingGitExecutable,
                                allowedContentTypes: [.unixExecutable, .executable],
                                allowsMultipleSelection: false
                            ) { result in
                                guard case .success(let urls) = result,
                                      let url = urls.first else { return }
                                preferences.gitExecutablePath = url.path
                                service.rebuildClientIfNeeded()
                            }
                    }
                }
                if gitExecutableIsValid {
                    Text("Commands run this binary directly with an argument array. No shell is involved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // Without this, a bad path only shows up as every later Git
                    // operation failing, one error at a time.
                    Label(
                        "No executable at this path. Git operations will fail until it is corrected.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)

                    Button("Reset to \(GitProcessRunner.defaultExecutablePath)") {
                        preferences.gitExecutablePath = GitProcessRunner.defaultExecutablePath
                        service.rebuildClientIfNeeded()
                    }
                }

                Stepper(
                    "Diff context: \(preferences.diffContextLines) lines",
                    value: $preferences.diffContextLines,
                    in: 0...20
                )
            }

            Section("Workspace") {
                Picker("Preferred IDE", selection: $preferences.preferredEditor) {
                    ForEach(WorkspaceApplication.editors) { editor in
                        Text(editor.displayName + (launcher.isInstalled(editor) ? "" : " (not installed)"))
                            .tag(editor)
                    }
                }
                Toggle("Open new worktrees in the preferred IDE", isOn: $preferences.openInEditorAfterCreate)
            }

            Section("GitHub") {
                LabelledFieldRow(label: "GitHub CLI (gh)") {
                    HStack(spacing: 6) {
                        TextField("", text: $preferences.gitHubExecutablePath)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .font(GitTreesUI.monospaced)
                        Button("Choose…") { choosingGitHubExecutable = true }
                            .fileImporter(
                                isPresented: $choosingGitHubExecutable,
                                allowedContentTypes: [.unixExecutable, .executable],
                                allowsMultipleSelection: false
                            ) { result in
                                guard case .success(let urls) = result,
                                      let url = urls.first else { return }
                                preferences.gitHubExecutablePath = url.path
                                service.rebuildClientIfNeeded()
                            }
                    }
                }

                if gitHubExecutableIsValid {
                    LabeledContent("Status") {
                        Label(service.gitHubAuth.summary, systemImage: gitHubStatusSymbol)
                            .foregroundStyle(gitHubStatusTint)
                    }
                    if !service.gitHubAuth.isAuthenticated {
                        Text("Run gh auth login in a terminal to sign in, then Check Again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Check Again") { service.refreshGitHub() }
                } else {
                    Label(
                        "No executable at this path. Pull request features are unavailable until it is corrected.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)

                    Button("Reset to \(GitHubProcessRunner.defaultExecutablePath)") {
                        preferences.gitHubExecutablePath = GitHubProcessRunner.defaultExecutablePath
                        service.rebuildClientIfNeeded()
                    }
                }
            }

            Section("Display") {
                Toggle("Show remote branches in the sidebar", isOn: $preferences.showRemoteBranches)
                Toggle("Reopen repository windows at launch", isOn: $preferences.restoreLastRepository)
            }

            Section("Remote") {
                Toggle("Fetch automatically when returning to a window", isOn: $preferences.autoFetchOnActivation)
                Text("Runs git fetch in the background, at most every few minutes, so the “behind upstream” notice stays current. A fetch only updates remote-tracking refs — it never changes your files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 480)
        .onChange(of: preferences.gitExecutablePath) { _, _ in service.rebuildClientIfNeeded() }
    }

    private var gitExecutableIsValid: Bool {
        FileManager.default.isExecutableFile(atPath: preferences.gitExecutablePath)
    }

    private var gitHubExecutableIsValid: Bool {
        FileManager.default.isExecutableFile(atPath: preferences.gitHubExecutablePath)
    }

    private var gitHubStatusSymbol: String {
        if service.gitHubAuth.isReady { return "checkmark.seal.fill" }
        if service.gitHubAuth.isInstalled { return "person.crop.circle.badge.exclamationmark" }
        return "xmark.seal"
    }

    private var gitHubStatusTint: Color {
        if service.gitHubAuth.isReady { return .green }
        return .secondary
    }
}
