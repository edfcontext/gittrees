import GitTreesCore
import SwiftUI
import UniformTypeIdentifiers

/// Creates a new folder, runs `git init`, and adds a remote in one step.
struct NewWorkspaceSheet: View {
    @Environment(RepositoryService.self) private var service
    @Environment(PreferencesService.self) private var preferences
    @Environment(WorkspaceLauncher.self) private var launcher
    @Environment(AppSession.self) private var session
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    @State private var folderName = ""
    @State private var parentPath = ""
    @State private var remoteName = "origin"
    @State private var remoteURL = ""
    @State private var openInEditor = false
    @State private var folderNameEdited = false
    @State private var choosingParent = false
    @State private var isCreating = false
    @FocusState private var urlFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            Form {
                locationSection
                remoteSection
                optionsSection
            }
            .formStyle(.grouped)
            .frame(width: 520)

            Divider()
            footer
        }
        .frame(width: 520)
        .onAppear {
            parentPath = (preferences.defaultWorkspaceParent().path as NSString).abbreviatingWithTildeInPath
            openInEditor = preferences.openInEditorAfterCreate
            urlFocused = true
        }
        .onChange(of: remoteURL) { _, newValue in
            guard !folderNameEdited else { return }
            folderName = RemoteURL.suggestedDirectoryName(from: newValue) ?? ""
        }
        .fileImporter(
            isPresented: $choosingParent,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let parent = urls.first else { return }
            parentPath = (parent.path as NSString).abbreviatingWithTildeInPath
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("New Repository")
                .font(.headline)
            Text("Create a folder, run git init, and add a remote.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var locationSection: some View {
        Section("Folder") {
            LabelledFieldRow(label: "Name") {
                TextField("", text: $folderName, prompt: Text("summit"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: folderName) { _, newValue in
                        let suggested = RemoteURL.suggestedDirectoryName(from: remoteURL) ?? ""
                        if newValue != suggested { folderNameEdited = true }
                    }
            }

            if let problem = folderNameProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            LabelledFieldRow(label: "Parent") {
                HStack(spacing: 6) {
                    TextField("", text: $parentPath, prompt: Text("~/Development"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(GitTreesUI.monospaced)

                    Button("Choose…") { choosingParent = true }
                }
            }

            if !trimmedFolderName.isEmpty {
                Text(RepositorySidebar.abbreviate(expandedDirectory))
                    .font(GitTreesUI.monospaced)
                    .foregroundStyle(.secondary)
            }

            if locationExists {
                Label("That directory already exists.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var remoteSection: some View {
        Section("Remote") {
            LabelledFieldRow(label: "Name") {
                TextField("", text: $remoteName, prompt: Text("origin"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
            }

            if let problem = remoteNameProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            LabelledFieldRow(label: "URL") {
                TextField("", text: $remoteURL, prompt: Text("git@github.com:owner/repo.git"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(GitTreesUI.monospaced)
                    .focused($urlFocused)
            }

            Text("SSH (git@host:owner/repo.git), HTTPS (https://host/owner/repo.git) and local paths all work — GitTrees passes the URL to Git unchanged.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var optionsSection: some View {
        Section {
            Toggle("Open in \(preferences.preferredEditor.displayName) after creation", isOn: $openInEditor)
                .disabled(!launcher.isInstalled(preferences.preferredEditor))
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if isCreating {
                ProgressView().controlSize(.small)
                Text("Creating workspace…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button("Create") { create() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate || isCreating)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var trimmedFolderName: String {
        folderName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedRemoteName: String {
        remoteName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedRemoteURL: String {
        remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var expandedParent: URL {
        URL(fileURLWithPath: (parentPath as NSString).expandingTildeInPath, isDirectory: true)
    }

    private var expandedDirectory: URL {
        expandedParent.appendingPathComponent(trimmedFolderName, isDirectory: true)
    }

    private var folderNameProblem: String? {
        guard !trimmedFolderName.isEmpty else { return nil }
        if trimmedFolderName == "." || trimmedFolderName == ".." {
            return "Choose a folder name other than . or .."
        }
        if trimmedFolderName.contains("/") || trimmedFolderName.contains(":") {
            return "A folder name cannot contain / or :."
        }
        return nil
    }

    private var remoteNameProblem: String? {
        guard !trimmedRemoteName.isEmpty else { return nil }
        if trimmedRemoteName.rangeOfCharacter(from: .whitespaces) != nil {
            return "A remote name cannot contain spaces."
        }
        return nil
    }

    private var locationExists: Bool {
        !trimmedFolderName.isEmpty && FileManager.default.fileExists(atPath: expandedDirectory.path)
    }

    private var canCreate: Bool {
        !trimmedFolderName.isEmpty
            && !parentPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && folderNameProblem == nil
            && !locationExists
            && !trimmedRemoteName.isEmpty
            && remoteNameProblem == nil
            && !trimmedRemoteURL.isEmpty
    }

    private func create() {
        let request = NewWorkspaceRequest(
            directory: expandedDirectory,
            remoteName: trimmedRemoteName,
            remoteURL: trimmedRemoteURL,
            openInEditor: openInEditor
        )
        preferences.openInEditorAfterCreate = openInEditor

        isCreating = true
        Task {
            let created = await service.createWorkspace(request)
            isCreating = false
            guard let created else { return }
            if service.repository == nil {
                await service.open(directory: created)
            } else {
                session.enqueuePendingDirectory(created)
                openWindow(id: GitTreesScene.repositoryWindowID)
            }
            if request.openInEditor {
                try? await launcher.open(created, in: preferences.preferredEditor)
            }
            dismiss()
        }
    }
}
