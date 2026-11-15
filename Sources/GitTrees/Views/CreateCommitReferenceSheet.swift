import GitTreesCore
import SwiftUI

/// Names a branch or tag at the commit captured by History's context menu.
struct CreateCommitReferenceSheet: View {
    enum Kind: String {
        case branch, tag

        var title: String { self == .branch ? "Create Branch" : "Create Tag" }
    }

    @Environment(RepositoryService.self) private var service
    @Environment(\.dismiss) private var dismiss

    let kind: Kind
    let commit: CommitSummary

    @State private var name = ""
    @State private var message = ""
    @State private var isCreating = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(kind.title) from Commit").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text(commit.hash).font(GitTreesUI.monospaced).textSelection(.enabled)
                Text(commit.subject).font(.callout).lineLimit(3)
            }
            .foregroundStyle(.secondary)

            LabeledContent(kind == .branch ? "Branch name" : "Tag name") {
                TextField("", text: $name, prompt: Text(kind == .branch ? "feature/my-branch" : "v1.0.0"))
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit { create() }
            }

            if kind == .tag {
                LabeledContent("Message (optional)") {
                    TextField("", text: $message)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { create() }
                }
                Text("Add a message to create an annotated tag. The tag is created locally.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Creates a local branch at this commit. You can check it out later from the sidebar.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let problem = nameConflict {
                Text(problem)
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            HStack {
                if isCreating { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCreating)
                Button(kind.title) { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .padding(20)
        .frame(width: 500)
        .disabled(isCreating)
        .interactiveDismissDisabled(isCreating)
        .onAppear { nameFocused = true }
        .onChange(of: service.repository?.id) { _, _ in dismiss() }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var nameConflict: String? {
        guard kind == .branch, service.localBranches.contains(where: { $0.name == trimmedName }) else { return nil }
        return "A branch named \(trimmedName) already exists. Choose a different name."
    }

    private var canCreate: Bool {
        !trimmedName.isEmpty && nameConflict == nil && !isCreating
            && service.repository != nil && service.activeOperation == nil
    }

    private func create() {
        guard canCreate else { return }
        let referenceName = trimmedName
        let tagMessage = message
        isCreating = true
        Task {
            let created: Bool
            switch kind {
            case .branch:
                created = await service.createBranch(name: referenceName, at: commit)
            case .tag:
                created = await service.createTag(name: referenceName, at: commit, message: tagMessage)
            }
            isCreating = false
            if created {
                dismiss()
            }
            // The error presenter opens above this form without losing the inputs.
        }
    }
}
