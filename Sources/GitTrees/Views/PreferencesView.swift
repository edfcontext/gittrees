import GitTreesCore
import SwiftUI

/// Application settings: which git binary to run, the preferred IDE, the worktree root
/// for the open repository, and a few display options.
struct PreferencesView: View {
    @Environment(PreferencesService.self) private var preferences
    @Environment(RepositoryService.self) private var service
    @Environment(WorkspaceLauncher.self) private var launcher

    @State private var worktreeRootDraft = ""
    @State private var choosingWorktreeRoot = false
    @State private var choosingGitExecutable = false

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section("Git") {
                HStack(spacing: 6) {
                    TextField("Git executable", text: $preferences.gitExecutablePath)
                        .textFieldStyle(.roundedBorder)
                        .font(GitTreesUI.monospaced)
                    Button("Choose…") { choosingGitExecutable = true }
                }
                Text("Commands run this binary directly with an argument array. No shell is involved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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

            Section("Repository") {
                if let repository = service.repository {
                    LabeledContent("Repository") {
                        Text(RepositorySidebar.abbreviate(repository.mainWorktreePath))
                            .font(GitTreesUI.monospaced)
                    }

                    HStack(spacing: 6) {
                        TextField("Worktree root", text: $worktreeRootDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(GitTreesUI.monospaced)
                            .onSubmit { applyWorktreeRoot(repository) }
                        Button("Choose…") { choosingWorktreeRoot = true }
                        Button("Apply") { applyWorktreeRoot(repository) }
                    }

                    Text("New worktrees are suggested inside this directory, named after the branch with prefixes such as feature/ removed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if preferences.hasCustomWorktreeRoot(for: repository) {
                        Button("Reset to Default") {
                            preferences.setWorktreeRoot(nil, for: repository)
                            worktreeRootDraft = RepositorySidebar.abbreviate(preferences.worktreeRoot(for: repository))
                        }
                    }
                } else {
                    Text("Open a repository to configure its worktree root.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Display") {
                Toggle("Show remote branches in the sidebar", isOn: $preferences.showRemoteBranches)
                Toggle("Reopen the last repository at launch", isOn: $preferences.restoreLastRepository)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 480)
        .onAppear(perform: syncDraft)
        .onChange(of: service.repository) { _, _ in syncDraft() }
        .onChange(of: preferences.gitExecutablePath) { _, _ in service.rebuildClientIfNeeded() }
        .fileImporter(
            isPresented: $choosingWorktreeRoot,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first,
                  let repository = service.repository else { return }
            preferences.setWorktreeRoot(url, for: repository)
            worktreeRootDraft = (url.path as NSString).abbreviatingWithTildeInPath
        }
        .fileImporter(
            isPresented: $choosingGitExecutable,
            allowedContentTypes: [.unixExecutable, .executable],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            preferences.gitExecutablePath = url.path
            service.rebuildClientIfNeeded()
        }
    }

    private func syncDraft() {
        guard let repository = service.repository else {
            worktreeRootDraft = ""
            return
        }
        worktreeRootDraft = RepositorySidebar.abbreviate(preferences.worktreeRoot(for: repository))
    }

    private func applyWorktreeRoot(_ repository: Repository) {
        let expanded = (worktreeRootDraft as NSString).expandingTildeInPath
        guard !expanded.isEmpty else {
            preferences.setWorktreeRoot(nil, for: repository)
            syncDraft()
            return
        }
        preferences.setWorktreeRoot(URL(fileURLWithPath: expanded), for: repository)
    }
}
