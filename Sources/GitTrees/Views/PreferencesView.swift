import GitTreesCore
import SwiftUI

/// Application settings: which git binary to run, the preferred IDE, the worktree root
/// for the open repository, and a few display options.
struct PreferencesView: View {
    @Environment(PreferencesService.self) private var preferences
    @Environment(RepositoryService.self) private var service
    @Environment(WorkspaceLauncher.self) private var launcher

    @State private var worktreeRootDraft = ""
    @State private var nameDraft = ""
    @State private var emailDraft = ""
    @State private var choosingWorktreeRoot = false
    @State private var choosingGitExecutable = false
    @State private var choosingGitHubExecutable = false
    @State private var addingRemote = false

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

            Section("Repository") {
                if let repository = service.repository {
                    LabeledContent("Repository") {
                        Text(RepositorySidebar.abbreviate(repository.mainWorktreePath))
                            .font(GitTreesUI.monospaced)
                    }

                    LabelledFieldRow(label: "Worktree root") {
                        HStack(spacing: 6) {
                            TextField("", text: $worktreeRootDraft)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .font(GitTreesUI.monospaced)
                                .onSubmit { applyWorktreeRoot(repository) }
                            Button("Choose…") { choosingWorktreeRoot = true }
                                .fileImporter(
                                    isPresented: $choosingWorktreeRoot,
                                    allowedContentTypes: [.folder],
                                    allowsMultipleSelection: false
                                ) { result in
                                    guard case .success(let urls) = result,
                                          let url = urls.first,
                                          let repository = service.repository else { return }
                                    preferences.setWorktreeRoot(url, for: repository)
                                    worktreeRootDraft = (url.path as NSString)
                                        .abbreviatingWithTildeInPath
                                }
                            Button("Apply") { applyWorktreeRoot(repository) }
                        }
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

            if service.repository != nil {
                identitySection
                remoteSection
            }

            Section("Display") {
                Toggle("Show remote branches in the sidebar", isOn: $preferences.showRemoteBranches)
                Toggle("Reopen the last repository at launch", isOn: $preferences.restoreLastRepository)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 620)
        .onAppear {
            syncDraft()
            syncIdentityDraft()
        }
        .onChange(of: service.repository) { _, _ in
            syncDraft()
            syncIdentityDraft()
        }
        .onChange(of: service.identity) { _, _ in syncIdentityDraft() }
        .onChange(of: preferences.gitExecutablePath) { _, _ in service.rebuildClientIfNeeded() }
    }

    // MARK: - Commit identity

    /// Reads and writes `git config --local user.name` / `user.email`.
    ///
    /// `--local` config lives in the shared git directory, so this is a property of the
    /// repository rather than of one worktree — the label says so, because with several
    /// worktrees open that distinction is easy to get wrong.
    private var identitySection: some View {
        Section("Commit Identity") {
            LabeledContent("Currently") {
                VStack(alignment: .leading, spacing: 1) {
                    Text(service.identity.displayName ?? "Not configured")
                        .font(GitTreesUI.monospaced)
                        .foregroundStyle(service.identity.isComplete ? .primary : .secondary)
                    Text(service.identity.scopeDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            LabelledFieldRow(label: "Name") {
                TextField("", text: $nameDraft, prompt: Text("Dev"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
            }
            LabelledFieldRow(label: "Email") {
                TextField("", text: $emailDraft, prompt: Text("dev@example.com"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 8) {
                Button("Set for This Repository") { applyIdentity() }
                    .disabled(!identityDraftIsUsable)

                if service.identity.isPinnedToRepository {
                    Button("Use Global Identity") {
                        Task {
                            await service.setLocalIdentity(name: nil, email: nil)
                            syncIdentityDraft()
                        }
                    }
                }
            }

            Text("Writes git config --local, which applies to every worktree of this repository. Your global ~/.gitconfig is never modified.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Both fields must be present: Git needs a name and an email to author a commit.
    private var identityDraftIsUsable: Bool {
        !nameDraft.trimmingCharacters(in: .whitespaces).isEmpty
            && !emailDraft.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func applyIdentity() {
        Task {
            await service.setLocalIdentity(
                name: nameDraft.trimmingCharacters(in: .whitespaces),
                email: emailDraft.trimmingCharacters(in: .whitespaces)
            )
            syncIdentityDraft()
        }
    }

    // MARK: - Remote

    private var remoteSection: some View {
        Section("Remote") {
            Picker("Fetch, pull and push use", selection: Binding(
                get: { service.selectedRemote },
                set: { service.selectedRemote = $0 }
            )) {
                Text("Automatic").tag(String?.none)
                ForEach(service.remotes) { remote in
                    Text(remote.name).tag(String?.some(remote.name))
                }
            }
            .disabled(service.remotes.isEmpty)

            Button("Add Remote…") { addingRemote = true }
                // The Settings window presents its own sheet; the main window's
                // presenter belongs to a different scene.
                .sheet(isPresented: $addingRemote) {
                    AddRemoteSheet()
                        .environment(service)
                }

            if service.remotes.isEmpty {
                Text("This repository has no remotes configured. Add one to fetch, pull or publish a branch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Automatic fetches every remote and lets pull and push follow each branch's own tracking configuration. Choosing a remote names it explicitly, and is the remote a new branch is published to.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func syncIdentityDraft() {
        // Seed the fields with whatever Git resolves, so editing starts from the truth
        // rather than from an empty box.
        nameDraft = service.identity.name ?? ""
        emailDraft = service.identity.email ?? ""
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
