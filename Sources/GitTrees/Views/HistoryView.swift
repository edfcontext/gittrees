import AppKit
import GitTreesCore
import SwiftUI

/// A flat commit list for the selected worktree, with an inspector for the selection.
///
/// Deliberately not a commit graph: this exists to answer "what is on this branch"
/// and "what did this commit change". Graph rendering is out of scope.
struct HistoryView: View {
    @Environment(RepositoryService.self) private var service

    @State private var selectedCommitID: CommitSummary.ID?
    @State private var detail: CommitDetail?
    @State private var selectedFileID: CommitFileChange.ID?
    @State private var diffText = ""
    @State private var isLoadingDetail = false
    @State private var isLoadingDiff = false
    @State private var detailError: String?
    @State private var diffError: String?

    var body: some View {
        Group {
            if service.history.isEmpty {
                ContentUnavailableView(
                    "No Commits",
                    systemImage: "clock",
                    description: Text("This worktree has no commit history yet.")
                )
            } else {
                VSplitView {
                    commitTable
                        .frame(minHeight: 110, idealHeight: 220)

                    CommitInspector(
                        detail: detail,
                        selectedFileID: $selectedFileID,
                        diffText: diffText,
                        isLoadingDetail: isLoadingDetail,
                        isLoadingDiff: isLoadingDiff,
                        detailError: detailError,
                        diffError: diffError
                    )
                    .frame(minHeight: 180)
                }
            }
        }
        .contextMenu {
            if let commit = selectedCommit {
                Button("Copy Hash") { copy(commit.hash) }
                Button("Copy Subject") { copy(commit.subject) }
                Divider()
            }
            Button("Refresh") { service.refreshSelectedWorktree() }
        }
        .task(id: selectedCommitID) { await loadDetail() }
        .task(id: diffReloadKey) { await loadDiff() }
        .onChange(of: service.history) { _, history in
            if let selectedCommitID, !history.contains(where: { $0.id == selectedCommitID }) {
                self.selectedCommitID = nil
            }
        }
        .onChange(of: service.selectedWorktreePath) { _, _ in
            selectedCommitID = nil
        }
    }

    // MARK: - Table

    private var commitTable: some View {
        Table(service.history, selection: $selectedCommitID) {
            TableColumn("Commit") { commit in
                Text(commit.abbreviatedHash)
                    .font(GitTreesUI.monospaced)
                    .foregroundStyle(.secondary)
            }
            .width(min: 64, ideal: 72, max: 90)

            TableColumn("Subject") { commit in
                HStack(spacing: 5) {
                    Text(commit.subject)
                        .lineLimit(1)
                        .layoutPriority(1)

                    let badges = refBadges(for: commit)
                    ForEach(badges.prefix(Self.maximumBadges), id: \.self) { ref in
                        BadgeLabel(text: ref, tint: .accentColor)
                            .fixedSize()
                    }
                    if badges.count > Self.maximumBadges {
                        Text("+\(badges.count - Self.maximumBadges)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .help(badges.joined(separator: ", "))
                    }
                    Spacer(minLength: 0)
                }
            }

            TableColumn("Author") { commit in
                Text(commit.authorName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 90, ideal: 130, max: 200)

            TableColumn("Date") { commit in
                Text(commit.authorDate, format: .dateTime.year().month().day().hour().minute())
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 120, ideal: 150, max: 190)
        }
        .tableStyle(.inset)
        .font(.callout)
    }

    // MARK: - Loading

    private var selectedCommit: CommitSummary? {
        guard let selectedCommitID else { return nil }
        return service.history.first { $0.id == selectedCommitID }
    }

    private var diffReloadKey: String {
        "\(selectedCommitID ?? "")|\(detail?.hash ?? "")|\(selectedFileID ?? "")"
    }

    private func loadDetail() async {
        guard let selectedCommitID else {
            detail = nil
            selectedFileID = nil
            diffText = ""
            detailError = nil
            diffError = nil
            return
        }
        isLoadingDetail = true
        detailError = nil
        defer { isLoadingDetail = false }
        do {
            let loaded = try await service.commitDetail(hash: selectedCommitID)
            guard !Task.isCancelled else { return }
            detail = loaded
            if selectedFileID == nil || !loaded.files.contains(where: { $0.id == selectedFileID }) {
                selectedFileID = loaded.files.first?.id
            }
        } catch is CancellationError {
            return
        } catch {
            detail = nil
            selectedFileID = nil
            diffText = ""
            detailError = error.localizedDescription
        }
    }

    private func loadDiff() async {
        guard let hash = selectedCommitID,
              let detail, detail.hash == hash,
              let fileID = selectedFileID,
              let file = detail.files.first(where: { $0.id == fileID }) else {
            diffText = ""
            diffError = nil
            return
        }
        isLoadingDiff = true
        diffError = nil
        defer { isLoadingDiff = false }
        do {
            diffText = try await service.commitDiff(hash: hash, path: file.path)
        } catch is CancellationError {
            return
        } catch {
            diffText = ""
            diffError = error.localizedDescription
        }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private static let maximumBadges = 3

    /// `%D` gives a comma-separated decoration such as `HEAD -> main, origin/main`.
    private func refBadges(for commit: CommitSummary) -> [String] {
        commit.refNames
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// Message, changed files and the unified diff of the selected file.
struct CommitInspector: View {
    let detail: CommitDetail?
    @Binding var selectedFileID: CommitFileChange.ID?
    let diffText: String
    let isLoadingDetail: Bool
    let isLoadingDiff: Bool
    let detailError: String?
    let diffError: String?

    var body: some View {
        VStack(spacing: 0) {
            if let detailError {
                ContentUnavailableView(
                    "Could Not Load Commit",
                    systemImage: "exclamationmark.triangle",
                    description: Text(detailError)
                )
            } else if let detail {
                header(detail)
                Divider()
                HSplitView {
                    fileList(detail)
                        .frame(minWidth: 180, idealWidth: 240, maxWidth: 360)
                    diffPane
                        .frame(minWidth: 280)
                }
            } else if isLoadingDetail {
                ProgressView("Loading commit…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No Commit Selected",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Select a commit to see the files it changed.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GitTreesUI.barBackground)
    }

    private func header(_ detail: CommitDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(detail.abbreviatedHash)
                    .font(GitTreesUI.monospaced)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .help(detail.hash)

                Text(detail.subject)
                    .font(.headline)
                    .lineLimit(2)
                    .textSelection(.enabled)

                Spacer(minLength: 0)

                if isLoadingDetail {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                }
            }

            HStack(spacing: 8) {
                Text(detail.authorName)
                    .lineLimit(1)
                Text(detail.authorEmail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Text(detail.authorDate, format: .dateTime.year().month().day().hour().minute())
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }
            .font(.caption)

            if !detail.body.isEmpty {
                ScrollView {
                    Text(detail.body)
                        .font(GitTreesUI.monospaced)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 72)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func fileList(_ detail: CommitDetail) -> some View {
        List(selection: $selectedFileID) {
            Section {
                ForEach(detail.files) { file in
                    CommitFileRow(change: file)
                        .tag(file.id)
                        .contextMenu {
                            Button("Copy Path") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(file.path, forType: .string)
                            }
                        }
                }
            } header: {
                SectionHeaderLabel(title: "Files", count: detail.files.count)
            }
        }
        .listStyle(.inset)
        .environment(\.defaultMinListRowHeight, 20)
        .overlay {
            if detail.files.isEmpty && !isLoadingDetail {
                Text("No files changed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var diffPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let file = selectedFile {
                    Text(file.path)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                    if let original = file.originalPath {
                        Text("← \(original)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 0)
                    if isLoadingDiff {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                    }
                } else {
                    Text("Diff")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(GitTreesUI.barBackground)

            Divider()

            diffContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(GitTreesUI.editorBackground)
    }

    @ViewBuilder
    private var diffContent: some View {
        if selectedFileID == nil {
            ContentUnavailableView(
                "No File Selected",
                systemImage: "doc.text",
                description: Text("Select a file to see the diff this commit introduced.")
            )
        } else if let diffError {
            ContentUnavailableView(
                "Could Not Load Diff",
                systemImage: "exclamationmark.triangle",
                description: Text(diffError)
            )
        } else if diffText.isEmpty && !isLoadingDiff {
            ContentUnavailableView(
                "No Textual Diff",
                systemImage: "doc",
                description: Text("Git produced no diff for this file. It may be binary, or the change may be a mode change only.")
            )
        } else {
            DiffTextView(diff: diffText)
        }
    }

    private var selectedFile: CommitFileChange? {
        guard let selectedFileID else { return nil }
        return detail?.files.first { $0.id == selectedFileID }
    }
}

struct CommitFileRow: View {
    let change: CommitFileChange

    var body: some View {
        HStack(spacing: 6) {
            Text(String(change.status.rawValue))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(tint)
                .frame(width: 12)
                .accessibilityLabel(change.status.label)

            VStack(alignment: .leading, spacing: 0) {
                Text(change.fileName)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if !change.directory.isEmpty || change.originalPath != nil {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .help(helpText)
    }

    private var subtitle: String {
        if let original = change.originalPath {
            return "\(original) → \(change.path)"
        }
        return change.directory
    }

    private var helpText: String {
        var lines = [change.path]
        if let original = change.originalPath { lines.append("renamed from \(original)") }
        lines.append(change.status.label)
        return lines.joined(separator: "\n")
    }

    private var tint: Color {
        switch change.status {
        case .added: .green
        case .deleted: .red
        case .renamed, .copied: .purple
        case .modified, .typeChanged: .orange
        case .unmodified, .unmerged: .secondary
        }
    }
}
