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
    /// Opens with the current worktree's uncommitted changes already set to move across,
    /// which is how "Move Changes to New Worktree…" enters the sheet.
    var movingChanges: Bool = false

    @State private var mode: Mode = .new
    @State private var existingBranch: String = ""
    @State private var newBranchName: String = ""
    @State private var startPoint: String = ""
    @State private var location: String = ""
    /// Once the user edits the path by hand, it stops following the branch name.
    @State private var locationEdited = false
    @State private var openInEditor = false
    @State private var uncommittedChanges: NewWorktreeRequest.UncommittedChanges = .leave
    @State private var ignoreWorktreeRoot = true
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
                if !service.status.isClean, service.selectedWorktree != nil { changesSection }
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
                LabelledFieldRow(label: "Branch name") {
                    TextField("", text: $newBranchName, prompt: Text("feature/zpl-templates"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                }

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
            LabelledFieldRow(label: "Path") {
                HStack(spacing: 6) {
                    TextField("", text: $location)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(GitTreesUI.monospaced)
                        .onChange(of: location) { _, _ in locationEdited = true }

                    Button("Choose…") { choosingLocation = true }
                }
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

    /// Offers to carry the current worktree's uncommitted work into the new one.
    ///
    /// This is the shape of the thing people actually do by hand — start editing in the
    /// worktree that happens to be open, realise it wants its own branch, then juggle a
    /// stash to get it there. Doing it here keeps the staged/unstaged split and the
    /// untracked files intact, which the by-hand version usually loses.
    @ViewBuilder
    private var changesSection: some View {
        Section("Uncommitted Changes") {
            if let source = service.selectedWorktree {
                Text("\(summary) in \(source.displayName).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("", selection: $uncommittedChanges) {
                    Text("Leave them where they are").tag(NewWorktreeRequest.UncommittedChanges.leave)
                    Text("Move them to the new worktree").tag(NewWorktreeRequest.UncommittedChanges.move)
                    Text("Copy them to the new worktree").tag(NewWorktreeRequest.UncommittedChanges.copy)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                if let warning = transferWarning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var optionsSection: some View {
        Section {
            Toggle("Open in \(preferences.preferredEditor.displayName) after creation", isOn: $openInEditor)
                .disabled(!launcher.isInstalled(preferences.preferredEditor))

            if let rule = worktreeRootRule {
                Toggle("Add “\(rule)” to \(Gitignore.Destination.local.displayName)", isOn: $ignoreWorktreeRoot)
                Text(ignoreRuleExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if isCreating {
                ProgressView().controlSize(.small)
                Text(uncommittedChanges == .leave ? "Running git worktree add…" : "Moving your changes across…")
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

    /// The rule that would keep the worktree root out of `git status`, or nil when there
    /// is nothing to offer — no repository, or the rule is already in the file.
    ///
    /// The pattern follows the root's own directory name rather than a fixed string, so a
    /// repository pointed at a differently named root gets a rule that matches it.
    private var worktreeRootRule: String? {
        guard let repository = service.repository else { return nil }
        let name = preferences.worktreeRoot(for: repository).lastPathComponent
        guard !name.isEmpty else { return nil }
        let rule = Gitignore.pattern(forDirectoryNamed: name)
        guard !service.hasIgnoreRule(pattern: rule, destination: .local) else { return nil }
        return rule
    }

    /// A root beside the repository is outside the work tree, so the rule changes nothing
    /// today — it is worth saying so rather than implying an effect it does not have.
    private var ignoreRuleExplanation: String {
        guard let repository = service.repository else { return "" }
        let root = preferences.worktreeRoot(for: repository).standardizedFileURL.path + "/"
        let inside = root.hasPrefix(repository.mainWorktreePath.standardizedFileURL.path + "/")
        return inside
            ? "The worktree root is inside the repository, so Git would otherwise report every worktree in it as untracked."
            : "The worktree root sits beside the repository, where Git cannot see it. The rule costs nothing and covers a root moved inside later."
    }

    /// "2 modified files and 1 untracked file", from the same counts the removal warning uses.
    private var summary: String {
        let parts = service.status.dirtySummary
        guard !parts.isEmpty else { return "Uncommitted changes" }
        guard parts.count > 1 else { return parts[0].prefix(1).uppercased() + parts[0].dropFirst() }
        let head = parts.dropLast().joined(separator: ", ")
        let joined = "\(head) and \(parts[parts.count - 1])"
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    /// Warns when the new worktree would not start where the changes came from.
    ///
    /// Applying them is a merge, so a different starting commit can conflict. Nothing is
    /// lost when it does — the changes stay in a stash GitTrees names — but it is worth
    /// saying before rather than after.
    private var transferWarning: String? {
        guard uncommittedChanges != .leave else { return nil }
        guard let current = service.selectedWorktree?.branchName else {
            return "This worktree has a detached HEAD, so the changes may not apply cleanly to the branch you picked."
        }
        let base = mode == .existing ? existingBranch : startPoint
        guard base != current else { return nil }
        return "The new worktree starts at \(base) rather than \(current), so the changes may not apply cleanly. If they don't, they are left in a stash and nothing is lost."
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
        if movingChanges, !service.status.isClean { uncommittedChanges = .move }

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
            openInEditor: openInEditor,
            uncommittedChanges: service.status.isClean ? .leave : uncommittedChanges,
            ignoreRule: ignoreWorktreeRoot ? worktreeRootRule : nil
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
