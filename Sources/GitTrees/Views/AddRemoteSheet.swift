import GitTreesCore
import SwiftUI

/// Adds a remote with `git remote add`.
///
/// Deliberately minimal: a name and a URL. Renaming, changing a URL and removing a
/// remote are still command-line work, but a repository created here can now be
/// connected to something, which `git init` on its own left impossible.
struct AddRemoteSheet: View {
    @Environment(RepositoryService.self) private var service
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var url = ""
    @State private var isAdding = false
    @FocusState private var urlFocused: Bool

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
                            LabeledContent(remote.name) {
                                Text(remote.fetchURL ?? "No URL configured")
                                    .font(GitTreesUI.monospaced)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
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
