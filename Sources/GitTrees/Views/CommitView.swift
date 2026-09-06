import GitTreesCore
import SwiftUI

/// The commit message editor and commit button.
struct CommitView: View {
    @Environment(RepositoryService.self) private var service
    @Environment(AppCommands.self) private var commands

    @State private var message = ""
    @FocusState private var messageFocused: Bool

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

                Button("Commit") { commit() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canCommit)
                    .help("Commit the staged files (⌘↩). Hooks and Git configuration run as usual.")
            }
        }
        .padding(10)
        .onChange(of: commands.commitFocusRequested) { _, requested in
            if requested {
                messageFocused = true
                commands.commitFocusRequested = false
            }
        }
    }

    private var stagedCount: Int { service.status.stagedChanges.count }

    private var canCommit: Bool {
        stagedCount > 0
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && service.status.conflicts.isEmpty
            && service.identity.isComplete
            && service.activeOperation == nil
    }

    private func commit() {
        let text = message
        Task {
            if await service.commit(message: text) {
                message = ""
            }
        }
    }
}
