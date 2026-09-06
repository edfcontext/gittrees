import GitTreesCore
import SwiftUI
import UniformTypeIdentifiers

/// The selected worktree's branch, plus the repository-wide settings that used to live
/// in Settings: commit identity, remotes, and where new worktrees are suggested.
struct BranchInfoView: View {
    @Environment(RepositoryService.self) private var service
    @Environment(PreferencesService.self) private var preferences

    let worktree: Worktree
    let onAddRemote: () -> Void

    @State private var nameDraft = ""
    @State private var emailDraft = ""
    @State private var worktreeRootDraft = ""
    @State private var choosingWorktreeRoot = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                worktreeSection
                branchSection
                identitySection
                remotesSection
                worktreeRootSection
                otherWorktreesSection
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            syncIdentityDraft()
            syncWorktreeRootDraft()
        }
        .onChange(of: service.identity) { _, _ in syncIdentityDraft() }
        .onChange(of: service.repository) { _, _ in syncWorktreeRootDraft() }
    }

    // MARK: - Worktree / branch

    private var worktreeSection: some View {
        InfoSection(title: "Worktree") {
            InfoRow(label: "Path", value: worktree.path.path, monospaced: true)
            InfoRow(label: "Type", value: worktree.isMain ? "Main worktree" : "Linked worktree")
            InfoRow(label: "HEAD", value: worktree.head ?? "—", monospaced: true)
            if worktree.isDetached {
                InfoRow(label: "State", value: "Detached HEAD")
            }
            InfoRow(label: "Locked", value: lockedValue)
            if let reason = worktree.prunableReason {
                InfoRow(label: "Prunable", value: reason)
            }
            InfoRow(label: "Working Tree", value: service.status.isClean ? "Clean" : dirtyValue)
        }
    }

    @ViewBuilder
    private var branchSection: some View {
        if let branch = service.branch(for: worktree) {
            InfoSection(title: "Branch") {
                InfoRow(label: "Name", value: branch.name)
                InfoRow(label: "Ref", value: branch.refName, monospaced: true)
                InfoRow(label: "Commit", value: branch.objectName, monospaced: true)
                InfoRow(label: "Upstream", value: branch.upstreamName ?? "None")
                if branch.hasUpstream {
                    InfoRow(label: "Ahead", value: "\(branch.ahead ?? 0)")
                    InfoRow(label: "Behind", value: "\(branch.behind ?? 0)")
                    if branch.upstreamIsGone {
                        InfoRow(label: "Note", value: "The upstream branch no longer exists.")
                    }
                }
            }
        } else {
            InfoSection(title: "Branch") {
                InfoRow(label: "State", value: "No branch is checked out in this worktree.")
            }
        }
    }

    // MARK: - Repository settings

    /// `git config --local user.name` / `user.email` — repository-wide, not per worktree.
    private var identitySection: some View {
        InfoSection(title: "Commit Identity") {
            let identity = service.identity
            InfoRow(label: "Currently", value: identity.displayName ?? "Not configured")
            InfoRow(label: "Source", value: identity.scopeDescription)
            if !identity.isComplete {
                InfoRow(label: "Note", value: "Git will refuse to commit until user.name and user.email are set.")
            }

            editorRow(label: "Name") {
                TextField("Dev", text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
            }
            editorRow(label: "Email") {
                TextField("dev@example.com", text: $emailDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(GitTreesUI.monospaced)
            }

            HStack(spacing: 8) {
                Button("Set for This Repository") { applyIdentity() }
                    .disabled(!identityDraftIsUsable)
                if identity.isPinnedToRepository {
                    Button("Use Global Identity") {
                        Task {
                            await service.setLocalIdentity(name: nil, email: nil)
                            syncIdentityDraft()
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            .padding(.top, 4)

            Text("Writes git config --local, which applies to every worktree of this repository. Your global ~/.gitconfig is never modified.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    private var remotesSection: some View {
        InfoSection(title: "Remotes") {
            if service.remotes.isEmpty {
                InfoRow(label: "Configured", value: "None")
            } else {
                ForEach(service.remotes) { remote in
                    InfoRow(
                        label: remote.name,
                        value: remote.fetchURL ?? "No URL configured",
                        monospaced: true
                    )
                }

                editorRow(label: "In use") {
                    Picker("Remote", selection: remoteBinding) {
                        Text("Automatic").tag(String?.none)
                        ForEach(service.remotes) { remote in
                            Text(remote.name).tag(String?.some(remote.name))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                }
            }

            HStack {
                Button("Add Remote…", action: onAddRemote)
                    .controlSize(.small)
                Spacer(minLength: 0)
            }
            .padding(.top, 4)

            Text(service.remotes.isEmpty
                 ? "Add a remote to fetch, pull or publish a branch."
                 : "Automatic fetches every remote and lets pull and push follow each branch's tracking configuration.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    /// Where Create Worktree suggests a directory. Not a Git setting — stored by GitTrees.
    private var worktreeRootSection: some View {
        InfoSection(title: "New Worktrees") {
            editorRow(label: "Root") {
                HStack(spacing: 6) {
                    TextField("", text: $worktreeRootDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(GitTreesUI.monospaced)
                        .onSubmit { applyWorktreeRoot() }
                    Button("Choose…") { choosingWorktreeRoot = true }
                        .controlSize(.small)
                        .fileImporter(
                            isPresented: $choosingWorktreeRoot,
                            allowedContentTypes: [.folder],
                            allowsMultipleSelection: false
                        ) { result in
                            guard case .success(let urls) = result,
                                  let url = urls.first,
                                  let repository = service.repository else { return }
                            preferences.setWorktreeRoot(url, for: repository)
                            syncWorktreeRootDraft()
                        }
                    Button("Apply") { applyWorktreeRoot() }
                        .controlSize(.small)
                }
            }

            Text("New worktrees are suggested inside this directory, named after the branch with prefixes such as feature/ removed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            if let repository = service.repository, preferences.hasCustomWorktreeRoot(for: repository) {
                HStack {
                    Button("Reset to Default") {
                        preferences.setWorktreeRoot(nil, for: repository)
                        syncWorktreeRootDraft()
                    }
                    .controlSize(.small)
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private var otherWorktreesSection: some View {
        let others = service.worktrees.filter { $0.id != worktree.id && !$0.isBare }
        if !others.isEmpty {
            InfoSection(title: "Branches Checked Out Elsewhere") {
                ForEach(others) { other in
                    InfoRow(
                        label: other.branchName ?? other.displayName,
                        value: RepositorySidebar.abbreviate(other.path),
                        monospaced: true
                    )
                }
            }
        }
    }

    // MARK: - Rows

    private func editorRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 2)
    }

    private var remoteBinding: Binding<String?> {
        Binding(
            get: { service.selectedRemote },
            set: { service.selectedRemote = $0 }
        )
    }

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

    private func syncIdentityDraft() {
        nameDraft = service.identity.name ?? ""
        emailDraft = service.identity.email ?? ""
    }

    private func syncWorktreeRootDraft() {
        guard let repository = service.repository else {
            worktreeRootDraft = ""
            return
        }
        worktreeRootDraft = RepositorySidebar.abbreviate(preferences.worktreeRoot(for: repository))
    }

    private func applyWorktreeRoot() {
        guard let repository = service.repository else { return }
        let expanded = (worktreeRootDraft as NSString).expandingTildeInPath
        if expanded.isEmpty {
            preferences.setWorktreeRoot(nil, for: repository)
        } else {
            preferences.setWorktreeRoot(URL(fileURLWithPath: expanded), for: repository)
        }
        syncWorktreeRootDraft()
    }

    private var lockedValue: String {
        guard worktree.isLocked else { return "No" }
        return worktree.lockReason.map { "Yes — \($0)" } ?? "Yes"
    }

    private var dirtyValue: String {
        let summary = service.status.dirtySummary
        return summary.isEmpty ? "Modified" : summary.joined(separator: ", ")
    }
}

struct InfoSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionHeaderLabel(title: title)
            VStack(alignment: .leading, spacing: 3) {
                content
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panelChrome()
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)

            Text(value)
                .font(monospaced ? GitTreesUI.monospaced : .callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
