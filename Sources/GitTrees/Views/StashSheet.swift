import GitTreesCore
import SwiftUI

/// Prompts for a stash message, pre-filled with a sensible default, and stashes the
/// selected worktree's changes.
struct StashSheet: View {
    @Environment(RepositoryService.self) private var service
    @Environment(\.dismiss) private var dismiss

    @State private var message = ""
    @State private var includeUntracked = true
    @State private var isStashing = false
    @FocusState private var messageFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            Form {
                Section {
                    LabelledFieldRow(label: "Message") {
                        TextField("", text: $message, prompt: Text(service.suggestedStashMessage))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .focused($messageFocused)
                            .onSubmit(stash)
                    }
                }

                Section {
                    Toggle("Include untracked files", isOn: $includeUntracked)
                    Text("Untracked files are stashed too, so the worktree is left clean. Ignored files are never stashed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(width: 460)

            Divider()
            footer
        }
        .frame(width: 460)
        .onAppear {
            // Start from the default so a plain Return stashes with it, but select it so
            // the first keystroke replaces it.
            message = service.suggestedStashMessage
            messageFocused = true
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Stash Changes")
                .font(.headline)
            if let worktree = service.selectedWorktree {
                Text(summary(for: worktree))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if isStashing {
                ProgressView().controlSize(.small)
                Text("Running git stash…").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Stash") { stash() }
                .keyboardShortcut(.defaultAction)
                .disabled(isStashing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func summary(for worktree: Worktree) -> String {
        let parts = service.status.dirtySummary
        let where_ = "in \(worktree.displayName)"
        guard !parts.isEmpty else { return "Stash the local changes \(where_)." }
        return "Stash \(parts.joined(separator: ", ")) \(where_)."
    }

    private func stash() {
        guard !isStashing else { return }
        let text = message
        let untracked = includeUntracked
        isStashing = true
        Task {
            await service.createStash(message: text, includeUntracked: untracked)
            isStashing = false
            dismiss()
        }
    }
}
