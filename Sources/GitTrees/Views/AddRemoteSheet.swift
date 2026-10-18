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
                // Existing remotes come first: on a repository that already has them, the
                // reason to open this sheet is usually to repoint one, not to add another.
                // Burying that under the add form is what made editing hard to find.
                if !service.remotes.isEmpty {
                    Section("Existing Remotes") {
                        ForEach(service.remotes) { remote in
                            remoteRow(remote)
                        }
                    }
                }

                Section(service.remotes.isEmpty ? "" : "Add a Remote") {
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
            Text(service.remotes.isEmpty ? "Add Remote" : "Remotes")
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

    /// One existing-remote row: its URL and an Edit button that opens a popover. The
    /// popover carries its own always-visible Save/Cancel, so changing a URL never depends
    /// on scrolling the sheet to find the save control.
    @ViewBuilder
    private func remoteRow(_ remote: Remote) -> some View {
        LabeledContent(remote.name) {
            HStack(spacing: 8) {
                Text(remote.fetchURL ?? "No URL configured")
                    .font(GitTreesUI.monospaced)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Edit…") { beginEditing(remote) }
                    .disabled(isAdding)
                    .popover(isPresented: editingBinding(for: remote), arrowEdge: .bottom) {
                        editPopover(remote)
                    }
            }
        }
    }

    /// The URL editor, shown in a popover anchored to the row's Edit button.
    @ViewBuilder
    private func editPopover(_ remote: Remote) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Remote URL — \(remote.name)")
                .font(.headline)

            TextField("", text: $editedURL, prompt: Text("git@github-ctx:owner/repo.git"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(GitTreesUI.monospaced)
                .frame(width: 360)
                .focused($editedURLFocused)
                .onSubmit { saveEdit(remote) }

            Text("Change the host or path Git uses for this remote — e.g. a plain git@github.com host to an SSH config alias like git@github-ctx so it authenticates as the right account.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 360, alignment: .leading)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if isUpdating { ProgressView().controlSize(.small) }
                Button("Cancel") { cancelEdit() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isUpdating)
                Button("Save") { saveEdit(remote) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSaveEdit || isUpdating)
            }
        }
        .padding(14)
    }

    /// Drives the row popover from `editingRemote`: opening starts an edit, dismissing it
    /// (Save, Cancel or click-away) clears the draft.
    private func editingBinding(for remote: Remote) -> Binding<Bool> {
        Binding(
            get: { editingRemote == remote.name },
            set: { isOpen in
                if isOpen { beginEditing(remote) }
                else if editingRemote == remote.name { cancelEdit() }
            }
        )
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
