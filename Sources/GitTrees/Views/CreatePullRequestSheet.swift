import Foundation
import GitTreesCore
import SwiftUI

/// Opens and manages pull requests from the selected worktree.
struct CreatePullRequestSheet: View {
    @Environment(RepositoryService.self) private var service
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var descriptionText = ""
    @State private var base = ""
    @State private var isDraft = false
    @State private var reference = ""
    @State private var viewedRequest: PullRequest?
    @State private var progress: String?
    @State private var feedback: String?
    @State private var approvalSubmitted = false
    @State private var mergeSubmitted = false
    @State private var mergeConfirmation: MergeConfirmation?
    @State private var showingMergeConfirmation = false
    @State private var openRequestsRevision = 0
    @State private var reviewTab: ReviewTab = .files
    @FocusState private var lookupFocused: Bool

    private struct MergeConfirmation {
        let request: PullRequest
        let method: PullRequestMergeMethod
    }

    private enum ReviewTab {
        case files, checks
    }

    private var displayedRequest: PullRequest? {
        viewedRequest ?? service.pullRequest.flatMap { $0.isOpen ? $0 : nil }
    }

    private var showsOpenRequests: Bool {
        service.gitHubAuth.isReady && service.hasGitHubRemote && service.repository != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                if showsOpenRequests {
                    OpenPullRequestsList(
                        selectedURL: displayedRequest?.url,
                        revision: openRequestsRevision,
                        selectRequest: selectRequest,
                        updateRequests: updateSelectedRequest
                    )
                    .frame(width: 290)
                    .disabled(progress != nil || service.activeOperation != nil)
                    Divider()
                }
                requestPane
            }
            Divider()
            footer
        }
        .frame(
            width: showsOpenRequests ? 1_020 : (displayedRequest == nil ? 560 : 760),
            height: displayedRequest != nil ? 640 : (showsOpenRequests ? 520 : nil)
        )
        .onAppear(perform: prefill)
        .interactiveDismissDisabled(progress != nil)
        .confirmationDialog(
            "Merge pull request?", isPresented: $showingMergeConfirmation,
            titleVisibility: .visible, presenting: mergeConfirmation
        ) { confirmation in
            Button(confirmation.method.label) {
                perform(.merge(confirmation.method), on: confirmation.request)
            }
        } message: { confirmation in
            let request = confirmation.request
            Text("#\(request.number) · \(request.title)\n\(request.baseRefName) ← \(request.headRefName)")
        }
    }

    private var requestPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if service.gitHubAuth.isReady {
                lookup
                Divider()
            }

            if let request = displayedRequest {
                requestDetails(request)
                Divider()
                reviewPane(request)
            } else {
                form
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func reviewPane(_ request: PullRequest) -> some View {
        VStack(spacing: 0) {
            Picker("Pull request tab", selection: $reviewTab) {
                Text("Files Changed").tag(ReviewTab.files)
                Text("Checks").tag(ReviewTab.checks)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 220)
            .padding(8)
            Divider()
            switch reviewTab {
            case .files:
                PullRequestChangesView(request: request) { updated in
                    updateDisplayedRequest(updated, replacing: request)
                }
                .id(request.url)
            case .checks:
                PullRequestChecksView(request: request)
                    .id(request.url)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Pull Requests")
                .font(.headline)
            if displayedRequest == nil,
               let head = service.pullRequestHeadBranch, let base = baseForDisplay {
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

    private var lookup: some View {
        HStack {
            TextField("Pull request number or URL", text: $reference)
                .textFieldStyle(.roundedBorder)
                .focused($lookupFocused)
                .onSubmit(loadRequest)
            Button("View PR", action: loadRequest)
                .disabled(lookupReference == nil)
            if viewedRequest != nil {
                Button("Current Branch", action: showCurrentBranch)
            }
        }
        .disabled(progress != nil || service.activeOperation != nil)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var lookupReference: String? {
        let input = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Int(input.hasPrefix("#") ? String(input.dropFirst()) : input), number > 0 {
            return String(number)
        }
        guard let url = URL(string: input), url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.port == nil else { return nil }
        let path = url.path.split(separator: "/")
        guard path.count == 4, path[2] == "pull", let number = Int(path[3]), number > 0 else {
            return nil
        }
        return "https://github.com/\(path[0])/\(path[1])/pull/\(number)"
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
        .disabled(progress != nil)
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

    private func requestDetails(_ pr: PullRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            pullRequestCard(pr)
            if let feedback {
                Label(feedback, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if pr.isOpen {
                requestActions(pr)
            }
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
            if let author = pr.author?.login, !author.isEmpty {
                Text("by \(author)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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

    private func requestActions(_ pr: PullRequest) -> some View {
        let ownRequest = service.gitHubAuth.host?.lowercased() == URL(string: pr.url)?.host?.lowercased()
            && pr.isAuthored(by: service.gitHubAuth.account)
        return HStack {
            Button(approvalSubmitted ? "Approved" : "Approve") {
                perform(.approve, on: pr)
            }
            .disabled(ownRequest || pr.isDraft || approvalSubmitted)
            Menu("Merge…") {
                ForEach(PullRequestMergeMethod.allCases, id: \.self) { method in
                    Button(method.label) {
                        mergeConfirmation = MergeConfirmation(request: pr, method: method)
                        showingMergeConfirmation = true
                    }
                }
            }
            .fixedSize()
            .disabled(pr.isDraft || mergeSubmitted || pr.headRefOid?.isEmpty != false)
            if pr.isDraft {
                Text("Mark the PR ready for review on GitHub.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if ownRequest {
                Text("Authors can’t approve their own PRs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(progress != nil || service.activeOperation != nil || !service.gitHubAuth.isReady)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let progress {
                ProgressView().controlSize(.small)
                Text(progress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if let request = displayedRequest {
                Button("Open in Browser") {
                    Task { await service.openPullRequestInBrowser(request) }
                }
                .disabled(progress != nil || service.activeOperation != nil)
                Button("Done") { dismiss() }
                    .keyboardShortcut(lookupFocused ? nil : .defaultAction)
                    .disabled(progress != nil)
            } else {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(progress != nil)
                Button("Create") { create() }
                    .keyboardShortcut(lookupFocused ? nil : .defaultAction)
                    .disabled(!canCreate || progress != nil || service.activeOperation != nil)
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
        progress = "Creating pull request…"
        Task {
            defer { progress = nil }
            let result = await service.createPullRequest(draft)
            if let result {
                viewedRequest = result
                feedback = "Pull request created."
                openRequestsRevision += 1
            }
            // Leave failures in lastError: the scrollable presenter opens above this
            // form, preserving both the complete diagnostics and the user's draft.
        }
    }

    private func loadRequest() {
        guard let lookupReference, progress == nil else { return }
        progress = "Loading pull request…"
        Task {
            defer { progress = nil }
            guard let request = await service.loadPullRequest(lookupReference) else { return }
            selectRequest(request)
        }
    }

    private func selectRequest(_ request: PullRequest) {
        resetFeedback()
        viewedRequest = request
        lookupFocused = false
    }

    private func updateSelectedRequest(_ requests: [PullRequest]) {
        guard progress == nil, let previous = displayedRequest, previous.isOpen,
              let updated = requests.first(where: { $0.url == previous.url }) else { return }
        updateDisplayedRequest(updated, replacing: previous)
    }

    private func updateDisplayedRequest(_ updated: PullRequest, replacing previous: PullRequest) {
        guard displayedRequest == previous else { return }
        if !previous.hasSameRevision(as: updated) { resetFeedback() }
        if updated != displayedRequest { viewedRequest = updated }
    }

    private func showCurrentBranch() {
        reference = ""
        viewedRequest = nil
        resetFeedback()
        service.refreshGitHub()
    }

    private func resetFeedback() {
        feedback = nil
        approvalSubmitted = false
        mergeSubmitted = false
    }

    private func perform(_ action: PullRequestAction, on request: PullRequest) {
        guard progress == nil else { return }
        switch action {
        case .approve: progress = "Approving pull request…"
        case .merge: progress = "Merging pull request…"
        }
        Task {
            defer { progress = nil }
            guard let result = await service.performPullRequestAction(action, on: request) else { return }
            viewedRequest = result.pullRequest ?? request
            feedback = result.message
            switch action {
            case .approve: approvalSubmitted = true
            case .merge:
                mergeSubmitted = true
                openRequestsRevision += 1
            }
        }
    }
}
