import GitTreesCore
import SwiftUI

/// Creates a worktree, either for a branch that already exists or for a new branch
/// created in the same `git worktree add -b`.
struct NewWorktreeSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case existing = "Existing Branch"
        case new = "New Branch"

        var id: String { rawValue }
    }

    @Environment(RepositoryService.self) private var service
    @Environment(PreferencesService.self) private var preferences
    @Environment(WorkspaceLauncher.self) private var launcher
    @Environment(\.dismiss) private var dismiss

    /// Pre-selects the branch the user right-clicked in the sidebar.
    let preselectedBranch: String?

    @State private var mode: Mode = .new
    @State private var existingBranch: String = ""
    @State private var newBranchName: String = ""
    @State private var startPoint: String = ""
    @State private var location: String = ""
    /// Once the user edits the path by hand, it stops following the branch name.
    @State private var locationEdited = false
    @State private var openInEditor = false
    @State private var choosingLocation = false
    @State private var isCreating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            Form {
                branchSection
                if mode == .new { basedOnSection }
                locationSection
                optionsSection
            }
            .formStyle(.grouped)
            .frame(width: 520)

            Divider()
            footer
        }
        .frame(width: 520)
        .onAppear(perform: configureInitialState)
        .onChange(of: mode) { _, _ in refreshSuggestedLocation() }
        .onChange(of: newBranchName) { _, _ in refreshSuggestedLocation() }
        .onChange(of: existingBranch) { _, _ in refreshSuggestedLocation() }
        .fileImporter(
            isPresented: $choosingLocation,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            // The panel picks the parent; the branch directory is created inside it.
            guard case .success(let urls) = result, let parent = urls.first else { return }
            let name = WorktreePathSuggester.directoryName(forBranch: chosenBranchName)
            location = parent.appendingPathComponent(name, isDirectory: true).path
            locationEdited = true
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Create Worktree")
                .font(.headline)
            if let repository = service.repository {
                Text(RepositorySidebar.abbreviate(repository.mainWorktreePath))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var branchSection: some View {
        Section("Branch") {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            switch mode {
            case .existing:
                Picker("Branch", selection: $existingBranch) {
                    ForEach(availableBranches, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .disabled(availableBranches.isEmpty)

                if availableBranches.isEmpty {
                    Text("Every local branch already has a worktree.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .new:
                TextField("Branch name", text: $newBranchName, prompt: Text("feature/zpl-templates"))
                    .textFieldStyle(.roundedBorder)

                if let conflict = branchNameConflict {
                    Label(conflict, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var basedOnSection: some View {
        Section("Based On") {
            Picker("Start point", selection: $startPoint) {
                ForEach(startPointOptions, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
        }
    }

    private var locationSection: some View {
        Section("Location") {
            HStack(spacing: 6) {
                TextField("Path", text: $location)
                    .textFieldStyle(.roundedBorder)
                    .font(GitTreesUI.monospaced)
                    .onChange(of: location) { _, _ in locationEdited = true }

                Button("Choose…") { choosingLocation = true }
            }

            if let repository = service.repository {
                Text("Worktree root: \(RepositorySidebar.abbreviate(preferences.worktreeRoot(for: repository)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if locationExists {
                Label("That directory already exists. Git will refuse to use it.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
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
                Text("Running git worktree add…")
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

    // MARK: - Derived state

    /// Only branches without a worktree can be checked out into a new one; Git allows a
    /// branch in exactly one worktree at a time.
    private var availableBranches: [String] {
        service.localBranches
            .filter { service.worktree(for: $0) == nil }
            .map(\.name)
    }

    private var startPointOptions: [String] {
        let locals = service.localBranches.map(\.name)
        let remotes = preferences.showRemoteBranches ? service.remoteBranches.map(\.name) : []
        return locals + remotes
    }

    private var chosenBranchName: String {
        mode == .existing ? existingBranch : newBranchName
    }

    private var branchNameConflict: String? {
        let trimmed = newBranchName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard service.branches.contains(where: { $0.kind == .local && $0.name == trimmed }) else { return nil }
        return "A branch named \(trimmed) already exists. Use Existing Branch instead."
    }

    private var locationExists: Bool {
        !location.isEmpty && FileManager.default.fileExists(atPath: expandedLocation.path)
    }

    private var expandedLocation: URL {
        URL(fileURLWithPath: (location as NSString).expandingTildeInPath)
    }

    private var canCreate: Bool {
        guard !location.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch mode {
        case .existing:
            return !existingBranch.isEmpty
        case .new:
            return !newBranchName.trimmingCharacters(in: .whitespaces).isEmpty
                && branchNameConflict == nil
                && !startPoint.isEmpty
        }
    }

    // MARK: - Behaviour

    private func configureInitialState() {
        openInEditor = preferences.openInEditorAfterCreate

        if let preselectedBranch, service.branches.contains(where: { $0.name == preselectedBranch }) {
            // A branch that exists but has no worktree is exactly the "existing branch"
            // case, so start there rather than making the user switch.
            if availableBranches.contains(preselectedBranch) {
                mode = .existing
                existingBranch = preselectedBranch
            } else {
                mode = .new
                newBranchName = ""
                startPoint = preselectedBranch
            }
        } else {
            // New Branch is the common case; Existing Branch is one click away.
            existingBranch = availableBranches.first ?? ""
            mode = .new
        }

        if startPoint.isEmpty {
            startPoint = defaultStartPoint
        }
        refreshSuggestedLocation()
    }

    /// The branch of the selected worktree is the most likely base, falling back to a
    /// conventional default branch and then to whatever exists.
    private var defaultStartPoint: String {
        if let current = service.selectedWorktree?.branchName { return current }
        let names = service.localBranches.map(\.name)
        for candidate in ["main", "master", "develop"] where names.contains(candidate) {
            return candidate
        }
        return names.first ?? ""
    }

    private func refreshSuggestedLocation() {
        guard !locationEdited, let repository = service.repository else { return }
        let branch = chosenBranchName
        guard !branch.trimmingCharacters(in: .whitespaces).isEmpty else {
            location = ""
            return
        }
        let root = preferences.worktreeRoot(for: repository)
        let suggestion = WorktreePathSuggester.availablePath(
            WorktreePathSuggester.suggestedPath(worktreeRoot: root, branch: branch)
        )
        // Assigning to `location` fires onChange, which would otherwise mark the field
        // as user-edited and freeze the suggestion.
        let wasEdited = locationEdited
        location = (suggestion.path as NSString).abbreviatingWithTildeInPath
        locationEdited = wasEdited
    }

    private func create() {
        let request = NewWorktreeRequest(
            mode: mode == .existing
                ? .existingBranch(existingBranch)
                : .newBranch(
                    name: newBranchName.trimmingCharacters(in: .whitespaces),
                    startPoint: startPoint
                ),
            path: expandedLocation,
            openInEditor: openInEditor
        )
        preferences.openInEditorAfterCreate = openInEditor

        isCreating = true
        Task {
            let created = await service.createWorktree(request)
            isCreating = false
            guard let created else { return }
            if request.openInEditor {
                try? await launcher.open(created.path, in: preferences.preferredEditor)
            }
            dismiss()
        }
    }
}
