import GitTreesCore
import SwiftUI

/// The path an ignore rule is being built for, as handed from the Changes context menu
/// to the window that presents the sheet.
struct IgnoreRequest: Identifiable, Hashable {
    let path: String

    var id: String { path }
}

/// Builds one ignore rule for an untracked path and writes it to the chosen ignore file.
///
/// The context menu can only guess: it offers the exact file, or the one folder directly
/// above it. Neither is what is usually wanted — the folder worth ignoring is `build` or
/// `node_modules`, several levels up, and it often should not be committed at all. This
/// sheet makes both of those choices explicit, and shows what the rule would hide before
/// anything is written.
struct IgnoreSheet: View {
    /// What the rule is built around.
    enum Choice: String, CaseIterable, Identifiable {
        case file
        case folder
        case fileExtension
        case name
        case custom

        var id: String { rawValue }
    }

    @Environment(RepositoryService.self) private var service
    @Environment(\.dismiss) private var dismiss

    /// The untracked path the sheet was opened for. Always a file: `git status
    /// --untracked-files=all` reports the files inside an untracked directory, not the
    /// directory itself, so the folders on offer are the ones above it.
    let path: String

    @State private var choice: Choice = .folder
    @State private var folder: String = ""
    /// Switches the folder rule from "this exact folder" to "a folder with this name".
    @State private var folderAnywhere = false
    @State private var custom = ""
    @State private var destination: Gitignore.Destination = .repository
    @State private var preview: [String] = []
    @State private var isPreviewing = false
    @State private var isSaving = false
    /// The untracked walk and global excludes, captured once: they are the same for every
    /// pattern tried here, so reusing them halves the Git work per option. Nil until the
    /// first capture lands; early previews fall back to recomputing it.
    @State private var baseline: GitClient.IgnorePreviewBaseline?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            Form {
                ruleSection
                destinationSection
                previewSection
            }
            .formStyle(.grouped)
            .frame(width: 560)

            Divider()
            footer
        }
        .frame(width: 560)
        .onAppear(perform: configureInitialState)
        // Capture the invariant half of the preview once; the working tree does not change
        // while this modal is open, so every pattern can reuse it.
        .task { baseline = await service.ignorePreviewBaseline() }
        // SwiftUI cancels the running task when the id changes, so a fast click through
        // the options cannot leave a stale preview behind the current one.
        .task(id: pattern) { await refreshPreview() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Ignore")
                .font(.headline)
            Text(path)
                .font(GitTreesUI.monospaced)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var ruleSection: some View {
        Section("Rule") {
            choiceRow(.file, title: "This file", pattern: filePattern)

            if !folders.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    choiceRow(.folder, title: "This folder", pattern: folderPattern)

                    HStack(spacing: 8) {
                        Picker("", selection: $folder) {
                            ForEach(folders, id: \.self) { candidate in
                                Text(candidate).tag(candidate)
                            }
                        }
                        .labelsHidden()
                        .font(GitTreesUI.monospaced)
                        .frame(maxWidth: 260)

                        Toggle("Wherever it appears", isOn: $folderAnywhere)
                            .toggleStyle(.checkbox)
                            .font(.callout)
                    }
                    .padding(.leading, 20)
                    .disabled(choice != .folder)
                    .opacity(choice == .folder ? 1 : 0.5)
                }
            }

            if let extensionPattern {
                choiceRow(.fileExtension, title: "All “\(fileExtensionName)” files", pattern: extensionPattern)
            }

            choiceRow(.name, title: "Files named “\(lastComponent)”", pattern: namePattern)

            VStack(alignment: .leading, spacing: 6) {
                choiceRow(.custom, title: "Custom", pattern: nil)
                TextField("", text: $custom, prompt: Text("**/*.generated.ts"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(GitTreesUI.monospaced)
                    .padding(.leading, 20)
                    .disabled(choice != .custom)
            }
        }
    }

    private var destinationSection: some View {
        Section("Write To") {
            ForEach(Gitignore.Destination.allCases) { option in
                Button {
                    destination = option
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: destination == option ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(destination == option ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.displayName)
                                .font(GitTreesUI.monospaced)
                            Text(option.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        Section("Effect") {
            if pattern.isEmpty {
                Text("Enter a pattern.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isPreviewing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking…").font(.caption).foregroundStyle(.secondary)
                }
            } else if preview.isEmpty {
                Label(
                    "This rule matches none of the untracked files here.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hides \(preview.count) untracked file\(preview.count == 1 ? "" : "s"):")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(preview.prefix(8), id: \.self) { hidden in
                        Text(hidden)
                            .font(GitTreesUI.monospaced)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if preview.count > 8 {
                        Text("and \(preview.count - 8) more")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(pattern.isEmpty ? " " : pattern)
                .font(GitTreesUI.monospaced)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Spacer(minLength: 0)

            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button("Ignore") { apply() }
                .keyboardShortcut(.defaultAction)
                .disabled(pattern.isEmpty || isSaving)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func choiceRow(_ option: Choice, title: String, pattern: String?) -> some View {
        Button {
            choice = option
        } label: {
            HStack(spacing: 8) {
                Image(systemName: choice == option ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(choice == option ? Color.accentColor : .secondary)
                Text(title)
                Spacer(minLength: 8)
                if let pattern {
                    Text(pattern)
                        .font(GitTreesUI.monospaced)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Patterns

    private var folders: [String] {
        Gitignore.ancestorFolders(of: path)
    }

    private var lastComponent: String {
        String(path.split(separator: "/").last ?? Substring(path))
    }

    private var filePattern: String {
        Gitignore.pattern(forPath: path)
    }

    private var folderPattern: String {
        guard !folder.isEmpty else { return "" }
        return folderAnywhere
            ? Gitignore.pattern(forDirectoryNamed: folder)
            : Gitignore.pattern(forDirectory: folder)
    }

    private var extensionPattern: String? {
        Gitignore.pattern(forExtensionOf: path)
    }

    private var fileExtensionName: String {
        extensionPattern.map { String($0.dropFirst()) } ?? ""
    }

    private var namePattern: String {
        Gitignore.pattern(forNameOf: path)
    }

    /// The line that would be written, for the preview, the footer and the write itself —
    /// one definition, so what is shown cannot differ from what lands in the file.
    private var pattern: String {
        switch choice {
        case .file: filePattern
        case .folder: folderPattern
        case .fileExtension: extensionPattern ?? ""
        case .name: namePattern
        case .custom: custom.trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: - Behaviour

    private func configureInitialState() {
        folder = folders.first ?? ""
        // A folder is the usual reason for opening this sheet, but a file at the top of
        // the repository has no folder above it to offer.
        choice = folders.isEmpty ? .file : .folder
    }

    private func refreshPreview() async {
        let candidate = pattern
        guard !candidate.isEmpty else {
            preview = []
            return
        }
        isPreviewing = true
        let hidden = await service.previewIgnore(pattern: candidate, baseline: baseline)
        // A superseded preview leaves both the spinner and the list to its replacement,
        // which has already set them for the pattern now on screen.
        guard !Task.isCancelled else { return }
        preview = hidden
        isPreviewing = false
    }

    private func apply() {
        let candidate = pattern
        let target = destination
        isSaving = true
        Task {
            await service.addIgnoreRule(pattern: candidate, destination: target)
            isSaving = false
            dismiss()
        }
    }
}
