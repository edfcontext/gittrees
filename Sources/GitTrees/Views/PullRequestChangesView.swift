import Foundation
import GitTreesCore
import SwiftUI

struct PullRequestChangesView: View {
    @Environment(RepositoryService.self) private var service
    @State private var changes: PullRequestChanges?
    @State private var selectedPath: String?
    @State private var failure: String?
    @State private var refreshCount = 0
    @State private var loadedRefresh: Int?

    let request: PullRequest
    let onLoad: (PullRequest) -> Void

    private struct Query: Equatable {
        let request: PullRequest
        let refresh: Int
    }

    var body: some View {
        let query = Query(request: request, refresh: refreshCount)
        VStack(spacing: 0) {
            changesBar
            Divider()
            Group {
                if let changes, changes.request.hasSameRevision(as: request) {
                    if changes.files.isEmpty {
                        message("No changed files.", icon: "doc")
                    } else {
                        filesAndDiff(changes)
                    }
                } else if let failure {
                    message(failure, icon: "exclamationmark.triangle")
                } else {
                    ProgressView("Loading changed files…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(GitTreesUI.editorBackground)
        .task(id: query) { await load(query) }
    }

    private var changesBar: some View {
        HStack {
            Text("Changed Files")
                .font(.caption.weight(.semibold))
            if let changes, changes.request.hasSameRevision(as: request) {
                let count = changes.files.count
                let total = changes.request.changedFiles ?? count
                Text(total > count ? "\(count) of \(total)" : "\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()
            if let url = URL(string: request.url)?.appendingPathComponent("files") {
                Link("View Files on GitHub", destination: url)
                    .font(.caption)
            }
            Button {
                refreshCount += 1
            } label: {
                Label("Refresh Changed Files", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .help("Refresh changed files")
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(GitTreesUI.barBackground)
    }

    private func filesAndDiff(_ changes: PullRequestChanges) -> some View {
        HStack(spacing: 0) {
            List(selection: $selectedPath) {
                ForEach(changes.files) { file in
                    fileRow(file)
                        .tag(file.id)
                }
            }
            .listStyle(.inset)
            .frame(width: 220)

            Divider()
            if let file = changes.files.first(where: { $0.id == selectedPath }) {
                diffPane(file)
            } else {
                message("Select a file to review its diff.", icon: "doc.text")
            }
        }
    }

    private func fileRow(_ file: PullRequestFile) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(file.filename)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.head)
            HStack(spacing: 7) {
                Text(file.status.capitalized)
                Text("+\(file.additions)").foregroundStyle(.green)
                Text("−\(file.deletions)").foregroundStyle(.red)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .help(file.filename)
        .padding(.vertical, 2)
    }

    private func diffPane(_ file: PullRequestFile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(file.filename)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                if let previous = file.previousFilename {
                    Text("Previously \(previous)")
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(.secondary)
                }
                if file.hasPartialPatch {
                    Text("GitHub returned a partial diff for this file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()

            if let patch = file.patch, !patch.isEmpty {
                DiffTextView(diff: patch)
            } else {
                message("GitHub has no text diff for this file.", icon: "doc")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func message(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load(_ query: Query) async {
        if loadedRefresh == query.refresh, changes?.request.hasSameRevision(as: query.request) == true { return }
        changes = nil
        failure = nil
        do {
            let loaded = try await service.pullRequestChanges(query.request)
            guard !Task.isCancelled else { return }
            changes = loaded
            loadedRefresh = query.refresh
            if !loaded.files.contains(where: { $0.id == selectedPath }) {
                selectedPath = loaded.files.first?.id
            }
            onLoad(loaded.request)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            failure = PresentableError(title: "Could Not Load Changed Files", error: error).summary
        }
    }
}
