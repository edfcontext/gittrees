import GitTreesCore
import SwiftUI

/// The commit message editor and commit button.
struct CommitView: View {
    @Environment(RepositoryService.self) private var service
    @Environment(AppCommands.self) private var commands

    @State private var message = ""
    @FocusState private var messageFocused: Bool
    /// Last model/heuristic suggestion applied to the editor, so a later restage
    /// can replace it without clobbering a message the user has started typing.
    @State private var lastSuggestion = ""
    @State private var suggestionCaption = ""
    @State private var suggestionRequest = UUID()
    @State private var amend = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                SectionHeaderLabel(title: "Commit Message")
                Spacer(minLength: 0)
                if stagedCount > 0 {
                    Text("\(stagedCount) staged")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let behind = behindMessage {
                behindBanner(behind)
            }

            TextEditor(text: $message)
                .font(GitTreesUI.monospaced)
                .scrollContentBackground(.hidden)
                .focused($messageFocused)
                .frame(minHeight: 58, maxHeight: 110)
                .padding(4)
                .panelChrome(cornerRadius: GitTreesUI.cornerRadius)
                .overlay(alignment: .topLeading) {
                    if message.isEmpty {
                        Text("Summary of the change")
                            .font(GitTreesUI.monospaced)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 9)
                            .allowsHitTesting(false)
                    }
                }

            HStack(spacing: 8) {
                if !service.status.conflicts.isEmpty {
                    Label("Resolve conflicts first", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else if !service.identity.isComplete {
                    // Git would reject the commit; say so before the user writes a message.
                    Label("No commit identity set", systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("Set user.name and user.email on the Repository tab, or in your global Git configuration.")
                } else if let identity = service.identity.displayName {
                    Text("as \(identity)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(service.identity.scopeDescription)
                }

                Spacer(minLength: 0)

                Button {
                    Task { await refreshSuggestion(force: true) }
                } label: {
                    Image(systemName: "sparkles")
                }
                .buttonStyle(.borderless)
                .disabled(stagedCount == 0)
                .help("Draft a short subject with on-device Apple Intelligence, falling back to the local commit model or file names when unavailable. Replaces the current message.")

                Toggle("Amend", isOn: $amend)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .disabled(!service.canUndoLastCommit)
                    .help("Rewrite the previous commit instead of adding one — for a wrong message or a file left out. This rewrites history, so a branch already pushed then needs Push ▸ Force Push (with lease).")
                    .onChange(of: amend) { _, isOn in
                        // Amending starts from the message being rewritten, unless the
                        // user has already typed something of their own.
                        guard isOn,
                              message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              let subject = service.history.first?.subject
                        else { return }
                        message = subject
                    }

                Menu {
                    Button("Undo Last Commit") { Task { await service.undoLastCommit() } }
                        .disabled(!service.canUndoLastCommit)
                        .help("Removes the last commit but keeps everything it contained staged, ready to correct and commit again. Nothing is lost.")
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button(amend ? "Amend" : "Commit") { commit() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canCommit)
                    .help(amend
                          ? "Rewrite the previous commit with this message and the staged files (⌘↩)."
                          : "Commit the staged files (⌘↩). Hooks and Git configuration run as usual.")
            }

            if !suggestionCaption.isEmpty {
                Text(suggestionCaption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if stagedCount == 0 && !service.status.unstagedChanges.isEmpty {
                Text("Stage files to get a commit suggestion. Sparkles only runs on the index.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .onChange(of: commands.commitFocusRequested) { _, requested in
            if requested {
                messageFocused = true
                commands.commitFocusRequested = false
            }
        }
        .onChange(of: commands.pendingCommitMessage) { _, pending in
            guard let pending else { return }
            // Stage All offers a draft; adopt it only when the editor is untouched, so a
            // message the user has already started is never overwritten.
            if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                message = pending
                lastSuggestion = pending
                suggestionCaption = ""
            }
            commands.pendingCommitMessage = nil
        }
        .task(id: stagedSignature) {
            await refreshSuggestion()
        }
        .onDisappear { suggestionRequest = UUID() }
    }

    // MARK: - Behind-upstream notice

    /// An informational note that the upstream has commits this branch does not, so a
    /// commit now will diverge. The count is as of the last fetch — the honest word for
    /// it — and committing is not blocked; this only surfaces the choice to pull first.
    private var behindMessage: String? {
        guard let behind = service.status.behind, behind > 0 else { return nil }
        let upstream = service.status.upstream ?? "the upstream"
        let commits = behind == 1 ? "1 commit" : "\(behind) commits"
        return "\(upstream) has \(commits) you haven't pulled (as of the last fetch). Committing now will diverge from it."
    }

    /// Offers the fitting remedy inline: a dirty worktree cannot fast-forward, so it gets
    /// Stash & Apply; a clean one gets a plain Pull.
    @ViewBuilder
    private func behindBanner(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Label(text, systemImage: "info.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer(minLength: 4)

            if service.status.isClean {
                Button("Pull") { Task { await service.pull() } }
            } else {
                Button("Stash & Apply") { Task { await service.stashPullAndReapply() } }
                    .help("Stash your changes, pull, then re-apply them. You'll be told if a file conflicts.")
            }
        }
        .buttonStyle(.link)
        .font(.caption2)
        .disabled(service.activeOperation != nil)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(GitTreesUI.hoverFill, in: RoundedRectangle(cornerRadius: GitTreesUI.cornerRadius))
    }

    private var stagedCount: Int { service.status.stagedChanges.count }

    /// Identity of the staged set, so a restage re-runs the suggester.
    private var stagedSignature: String {
        ([service.selectedWorktreePath ?? ""] + service.status.stagedChanges.map {
            "\($0.indexStatus.rawValue):\($0.path)"
        }).joined(separator: "\n")
    }

    private var canCommit: Bool {
        // Amending needs no staged files — correcting just the message is the common case.
        (stagedCount > 0 || amend)
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && service.status.conflicts.isEmpty
            && service.identity.isComplete
            && service.activeOperation == nil
    }

    private func commit() {
        suggestionRequest = UUID()
        let text = message
        let isAmend = amend
        Task {
            if await service.commit(message: text, amend: isAmend) {
                message = ""
                lastSuggestion = ""
                suggestionCaption = ""
                amend = false
            }
        }
    }

    /// Prefills from Apple Intelligence with local fallbacks. Sparkles replaces the
    /// current message, but never edits made while generation is in flight.
    private func refreshSuggestion(force: Bool = false) async {
        let request = UUID()
        suggestionRequest = request
        suggestionCaption = ""
        let changes = service.status.stagedChanges
        if changes.isEmpty {
            if message == lastSuggestion {
                message = ""
            }
            lastSuggestion = ""
            suggestionCaption = ""
            return
        }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard force || trimmed.isEmpty || message == lastSuggestion else { return }
        let originalMessage = message
        let signature = stagedSignature
        suggestionCaption = "Drafting commit suggestion…"
        defer {
            if suggestionRequest == request && suggestionCaption == "Drafting commit suggestion…" {
                suggestionCaption = ""
            }
        }
        let diff = (try? await service.stagedDiff()) ?? ""
        guard !Task.isCancelled, suggestionRequest == request, stagedSignature == signature else { return }
        let suggestion = await CommitDescriptionService.shared.suggest(
            stagedChanges: changes,
            stagedDiff: diff
        )
        guard !Task.isCancelled, suggestionRequest == request,
              stagedSignature == signature, message == originalMessage else { return }
        // A file can be restaged with different contents while its status stays M.
        let currentDiff = (try? await service.stagedDiff()) ?? ""
        guard !Task.isCancelled, suggestionRequest == request,
              stagedSignature == signature, currentDiff == diff,
              message == originalMessage else { return }
        message = suggestion.message
        lastSuggestion = suggestion.message
        suggestionCaption = suggestion.diagnostic
    }
}
