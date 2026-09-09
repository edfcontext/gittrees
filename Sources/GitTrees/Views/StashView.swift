import AppKit
import GitTreesCore
import SwiftUI

/// The Stashes tab: the repository's stash stack on the left, the selected stash's diff
/// on the right, with apply and delete.
///
/// Stashes are shared across a repository's worktrees, so this is the same list whichever
/// worktree is selected; Apply targets the selected worktree.
struct StashView: View {
    @Environment(RepositoryService.self) private var service

    @State private var confirmingDrop: Stash?

    var body: some View {
        Group {
            if service.stashes.isEmpty {
                ContentUnavailableView(
                    "No Stashes",
                    systemImage: "tray",
                    description: Text("Use Stash in the toolbar to set aside your local changes for later.")
                )
            } else {
                HSplitView {
                    stashList
                        .frame(minWidth: 240, idealWidth: 320, maxWidth: 460)
                    StashDiffPane()
                        .frame(minWidth: 360, maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog(
            confirmingDrop.map { "Delete stash “\($0.message)”?" } ?? "",
            isPresented: Binding(
                get: { confirmingDrop != nil },
                set: { if !$0 { confirmingDrop = nil } }
            ),
            presenting: confirmingDrop
        ) { stash in
            Button("Delete Stash", role: .destructive) {
                Task { await service.dropStash(stash) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This permanently discards the stashed changes. It cannot be undone.")
        }
    }

    private var stashList: some View {
        @Bindable var service = service
        return List(selection: $service.selectedStashID) {
            Section {
                ForEach(service.stashes) { stash in
                    StashRow(stash: stash)
                        .tag(stash.id)
                        .contextMenu { rowMenu(stash) }
                }
            } header: {
                SectionHeaderLabel(title: "Stashes", count: service.stashes.count)
            }
        }
        .listStyle(.inset)
        .environment(\.defaultMinListRowHeight, 24)
    }

    @ViewBuilder
    private func rowMenu(_ stash: Stash) -> some View {
        Button("Apply to \(service.selectedWorktree?.displayName ?? "Worktree")") {
            Task { await service.applyStash(stash) }
        }
        .disabled(service.selectedWorktree == nil)
        Divider()
        Button("Copy Stash Ref") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(stash.selector, forType: .string)
        }
        Divider()
        Button("Delete Stash…", role: .destructive) { confirmingDrop = stash }
    }
}

/// One dense stash row: message, then branch, relative age and short sha.
private struct StashRow: View {
    let stash: Stash

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(stash.message)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 6) {
                if let branch = stash.branch {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                }
                if let date = stash.date {
                    Text(date, format: .relative(presentation: .named))
                        .lineLimit(1)
                }
                Text(stash.shortCommit)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }
}

/// The diff pane for the selected stash, with the apply/delete actions in a small bar so
/// they are reachable without the context menu.
private struct StashDiffPane: View {
    @Environment(RepositoryService.self) private var service

    @State private var diff = ""
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var confirmingDrop = false

    private var selected: Stash? {
        guard let id = service.selectedStashID else { return nil }
        return service.stashes.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GitTreesUI.editorBackground)
        .task(id: reloadKey) { await reload() }
        .confirmationDialog(
            selected.map { "Delete stash “\($0.message)”?" } ?? "",
            isPresented: $confirmingDrop,
            presenting: selected
        ) { stash in
            Button("Delete Stash", role: .destructive) {
                Task { await service.dropStash(stash) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This permanently discards the stashed changes. It cannot be undone.")
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            if let stash = selected {
                Text(stash.message)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isLoading {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                }
                Spacer(minLength: 0)
                Button("Apply") { Task { await service.applyStash(stash) } }
                    .help("git stash apply — restore these changes into \(service.selectedWorktree?.displayName ?? "the worktree"), keeping the stash.")
                    .disabled(service.selectedWorktree == nil || service.activeOperation != nil)
                Button("Delete", role: .destructive) { confirmingDrop = true }
                    .disabled(service.activeOperation != nil)
            } else {
                Text("Diff").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(GitTreesUI.barBackground)
    }

    @ViewBuilder
    private var content: some View {
        if selected == nil {
            ContentUnavailableView(
                "No Stash Selected",
                systemImage: "tray.full",
                description: Text("Select a stash to see what it would apply.")
            )
        } else if let loadError {
            ContentUnavailableView(
                "Could Not Load Stash",
                systemImage: "exclamationmark.triangle",
                description: Text(loadError)
            )
        } else if diff.isEmpty && !isLoading {
            ContentUnavailableView(
                "Empty Diff",
                systemImage: "doc",
                description: Text("Git produced no diff for this stash.")
            )
        } else {
            DiffTextView(diff: diff)
        }
    }

    private var reloadKey: String { service.selectedStashID ?? "none" }

    private func reload() async {
        guard let stash = selected else {
            diff = ""
            loadError = nil
            return
        }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            diff = try await service.stashDiff(stash)
        } catch is CancellationError {
            return
        } catch {
            diff = ""
            loadError = PresentableError(title: "", error: error).message
        }
    }
}
