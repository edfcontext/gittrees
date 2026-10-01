import GitTreesCore
import SwiftUI

/// Adds a remote with `git remote add`, and repoints an existing one with
/// `git remote set-url`.
///
/// Adding takes a name and a URL; each existing remote can have its URL edited in place —
/// the common reason being a host switch, e.g. `git@github.com:…` to an SSH alias like
/// `git@github-ctx:…` so the repository authenticates as the right account. Renaming and
/// removing a remote are still command-line work.
struct AddRemoteSheet: View {
    @Environment(RepositoryService.self) private var service
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var url = ""
    @State private var isAdding = false
    @FocusState private var urlFocused: Bool

    /// The remote whose URL is being edited in the list, and the draft being typed. Only
    /// one row edits at a time; `nil` means the list is showing plain values.
    @State private var editingRemote: String?
    @State private var editedURL = ""
    @State private var isUpdating = false
    @FocusState private var editedURLFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            Form {
                Section {
                    LabelledFieldRow(label: "Name") {
                        TextField("", text: $name, prompt: Text("origin"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                    }

                    if let problem = nameProblem {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    LabelledFieldRow(label: "URL") {
                        TextField("", text: $url, prompt: Text("git@github.com:owner/repo.git"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .font(GitTreesUI.monospaced)
                            .focused($urlFocused)
                    }

                    Text("SSH (git@host:owner/repo.git), HTTPS (https://host/owner/repo.git) and local paths all work — GitTrees passes the URL to Git unchanged.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !service.remotes.isEmpty {
                    Section("Existing Remotes") {
                        ForEach(service.remotes) { remote in
                            remoteRow(remote)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .frame(width: 520)
        .onAppear {
            // `origin` is the conventional first remote, so offer it and put the caret
            // where the user actually has to type.
            if service.remotes.isEmpty { name = "origin" }
            urlFocused = true
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Add Remote")
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

    private var footer: some View {
        HStack(spacing: 10) {
            if isAdding {
                ProgressView().controlSize(.small)
                Text("Running git remote add…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button("Add") { add() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd || isAdding)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// One existing-remote row: its URL, read-only with an Edit button, or an editable
    /// field with Save/Cancel while this is the row being edited.
    @ViewBuilder
    private func remoteRow(_ remote: Remote) -> some View {
        if editingRemote == remote.name {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(remote.name)
                    Spacer(minLength: 0)
                }
                TextField("", text: $editedURL, prompt: Text("git@github-ctx:owner/repo.git"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(GitTreesUI.monospaced)
                    .focused($editedURLFocused)
                    .onSubmit { saveEdit(remote) }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Cancel") { cancelEdit() }
                        .disabled(isUpdating)
                    Button("Save") { saveEdit(remote) }
                        .disabled(!canSaveEdit || isUpdating)
                    if isUpdating { ProgressView().controlSize(.small) }
                }
            }
        } else {
            LabeledContent(remote.name) {
                HStack(spacing: 8) {
                    Text(remote.fetchURL ?? "No URL configured")
                        .font(GitTreesUI.monospaced)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Edit…") { beginEditing(remote) }
                        .disabled(isAdding || isUpdating || editingRemote != nil)
                }
            }
        }
    }

    private var canSaveEdit: Bool {
        !editedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func beginEditing(_ remote: Remote) {
        editedURL = remote.fetchURL ?? ""
        editingRemote = remote.name
        editedURLFocused = true
    }

    private func cancelEdit() {
        editingRemote = nil
        editedURL = ""
    }

    private func saveEdit(_ remote: Remote) {
        guard canSaveEdit else { return }
        let newURL = editedURL
        isUpdating = true
        Task {
            let updated = await service.setRemoteURL(name: remote.name, url: newURL)
            isUpdating = false
            if updated { cancelEdit() }
        }
    }

    /// Only the cases worth catching before Git does; Git remains the authority on
    /// what a valid remote name is.
    private var nameProblem: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if service.remoteNames.contains(trimmed) {
            return "A remote named \(trimmed) already exists."
        }
        if trimmed.rangeOfCharacter(from: .whitespaces) != nil {
            return "A remote name cannot contain spaces."
        }
        return nil
    }

    private var canAdd: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && nameProblem == nil
    }

    private func add() {
        isAdding = true
        Task {
            let added = await service.addRemote(name: name, url: url)
            isAdding = false
            if added { dismiss() }
        }
    }
}
