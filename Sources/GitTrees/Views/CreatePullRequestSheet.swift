import GitTreesCore
import SwiftUI

/// Opens a pull request with `gh pr create` for the selected worktree's branch.
///
/// The head is fixed — it is the branch this worktree has checked out, which is the
/// whole point of a worktree-first client. The user chooses the base, edits the title
/// and body, and optionally marks it a draft. Preconditions (gh installed, signed in, a
/// GitHub remote, the branch pushed) are shown up front rather than surfaced as a
/// failure after the user has written a description.
struct CreatePullRequestSheet: View {
    @Environment(RepositoryService.self) private var service
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var descriptionText = ""
    @State private var base = ""
    @State private var isDraft = false
    @State private var isCreating = false
    @State private var created: PullRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if let created {
                successView(created)
            } else if let existing = service.pullRequest, existing.isOpen {
                existingView(existing)
            } else {
                form
            }

            Divider()
            footer
        }
        .frame(width: 560)
        .onAppear(perform: prefill)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Create Pull Request")
                .font(.headline)
            if let head = service.pullRequestHeadBranch, let base = baseForDisplay {
                Text("\(base) ← \(head)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var baseForDisplay: String? {
        base.isEmpty ? service.defaultBaseBranch : base
    }

    // MARK: - Form

    private var form: some View {
        Form {
            if let blocker = service.pullRequestBlocker {
                Section {
                    Label(blocker, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    if let hint = blockerHint {
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                LabelledFieldRow(label: "Base branch") {
                    Picker("", selection: $base) {
                        ForEach(baseChoices, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                }
                LabeledContent("Merge from") {
                    Text(service.pullRequestHeadBranch ?? "—")
                        .font(GitTreesUI.monospaced)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                LabelledFieldRow(label: "Title") {
                    TextField("", text: $title, prompt: Text("Summary of the change"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                }
                LabelledFieldRow(label: "Description") {
                    TextEditor(text: $descriptionText)
                        .font(GitTreesUI.monospaced)
                        .frame(minHeight: 120, maxHeight: 200)
                        .overlay {
                            RoundedRectangle(cornerRadius: 5).stroke(GitTreesUI.border)
                        }
                }
                Toggle("Create as draft", isOn: $isDraft)
            }
        }
        .formStyle(.grouped)
    }

    /// Base defaults to the suggestion but must always include the head's siblings so
    /// the user can retarget; the head itself is never a valid base.
    private var baseChoices: [String] {
        let head = service.pullRequestHeadBranch
        return service.localBranches.map(\.name).filter { $0 != head }
    }

    private var blockerHint: String? {
        guard let blocker = service.pullRequestBlocker else { return nil }
        if blocker.contains("not installed") {
            return "Install it with brew install gh, then set its path in Settings."
        }
        if blocker.contains("not signed in") {
            return "Run gh auth login in a terminal, then reopen this sheet."
        }
        if blocker.contains("no GitHub remote") {
            return "Add a remote whose URL points at github.com."
        }
        if blocker.contains("not been pushed") {
            return "Push the branch first — the Push button in the toolbar will set its upstream."
        }
        return nil
    }

    // MARK: - Existing / success

    private func existingView(_ pr: PullRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("A pull request is already open for this branch.", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
            pullRequestCard(pr)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func successView(_ pr: PullRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Pull request created.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            pullRequestCard(pr)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pullRequestCard(_ pr: PullRequest) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("#\(pr.number)")
                    .font(.headline.monospacedDigit())
                BadgeLabel(text: pr.stateLabel, tint: pr.isOpen ? .green : .secondary)
            }
            Text(pr.title)
                .font(.callout)
            Text(pr.shortDescription)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text(pr.url)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelChrome()
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if isCreating {
                ProgressView().controlSize(.small)
                Text("Running gh pr create…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if created != nil || (service.pullRequest?.isOpen ?? false) {
                Button("Open in Browser") {
                    Task { await service.openPullRequestInBrowser() }
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate || isCreating)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var canCreate: Bool {
        service.canCreatePullRequest
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !base.isEmpty
    }

    // MARK: - Behaviour

    private func prefill() {
        base = service.defaultBaseBranch ?? ""
        // The most recent commit subject is the natural PR title.
        title = service.history.first?.subject ?? ""
    }

    private func create() {
        guard let head = service.pullRequestHeadBranch else { return }
        let draft = PullRequestDraft(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            body: descriptionText,
            base: base,
            head: head,
            isDraft: isDraft
        )
        isCreating = true
        Task {
            let result = await service.createPullRequest(draft)
            isCreating = false
            if let result { created = result }
        }
    }
}
