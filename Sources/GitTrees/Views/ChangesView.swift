import AppKit
import GitTreesCore
import SwiftUI

/// The Changes tab: staged and unstaged file lists on the left, diff on the right, and
/// the commit editor beneath the file lists.
struct ChangesView: View {
    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                // The file list takes the slack so the commit editor keeps its
                // natural height at the bottom of the column.
                FileChangeList()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                CommitView()
            }
            .frame(minWidth: 260, idealWidth: 340, maxWidth: 520, maxHeight: .infinity)

            DiffView()
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Dense file list, split into conflicts, staged and unstaged sections.
struct FileChangeList: View {
    @Environment(RepositoryService.self) private var service

    var body: some View {
        @Bindable var service = service

        List(selection: Binding(
            get: { selectionKey },
            set: { applySelection($0) }
        )) {
            if !service.status.conflicts.isEmpty {
                section(
                    title: "Conflicts",
                    changes: service.status.conflicts,
                    staged: false,
                    action: nil
                )
            }

            section(
                title: "Staged",
                changes: service.status.stagedChanges,
                staged: true,
                action: .unstage
            )

            section(
                title: "Changes",
                changes: service.status.unstagedChanges,
                staged: false,
                action: .stage
            )
        }
        .listStyle(.inset)
        .environment(\.defaultMinListRowHeight, 20)
        .overlay {
            if service.status.isClean {
                Text("No local changes")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private enum RowAction {
        case stage
        case unstage
    }

    @ViewBuilder
    private func section(title: String, changes: [FileChange], staged: Bool, action: RowAction?) -> some View {
        if !changes.isEmpty {
            Section {
                ForEach(changes) { change in
                    FileChangeRow(change: change, staged: staged)
                        .tag(key(for: change, staged: staged))
                        .contextMenu { contextMenu(for: change, action: action) }
                }
            } header: {
                HStack(spacing: 4) {
                    SectionHeaderLabel(title: title, count: changes.count)
                    if let action {
                        Button(action == .stage ? "Stage All" : "Unstage All") {
                            Task {
                                if action == .stage {
                                    await service.stage(changes)
                                } else {
                                    await service.unstage(changes)
                                }
                            }
                        }
                        .buttonStyle(.link)
                        .font(.caption2)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for change: FileChange, action: RowAction?) -> some View {
        switch action {
        case .stage:
            Button("Stage File") { Task { await service.stage([change]) } }
            if change.kind == .untracked {
                Divider()
                Button("Add to .gitignore") { Task { await service.ignore(change) } }
                if !change.directory.isEmpty {
                    Button("Ignore Folder “\(change.directory)”") {
                        Task { await service.ignoreDirectory(of: change) }
                    }
                }
            }
        case .unstage:
            Button("Unstage File") { Task { await service.unstage([change]) } }
        case nil:
            Button("Stage Resolved File") { Task { await service.stage([change]) } }
        }
        Divider()
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(change.path, forType: .string)
        }
    }

    // MARK: - Selection

    /// The list selects a (path, side-of-index) pair, because the same file can appear
    /// in both the staged and unstaged sections with different diffs.
    private func key(for change: FileChange, staged: Bool) -> String {
        "\(staged ? "staged" : "worktree"):\(change.path)"
    }

    private var selectionKey: String? {
        guard let file = service.selectedFile else { return nil }
        return key(for: file, staged: service.showingStagedDiff)
    }

    private func applySelection(_ newValue: String?) {
        guard let newValue, let separator = newValue.firstIndex(of: ":") else {
            service.selectedFile = nil
            return
        }
        let staged = newValue[newValue.startIndex..<separator] == "staged"
        let path = String(newValue[newValue.index(after: separator)...])
        service.showingStagedDiff = staged
        service.selectedFile = service.status.changes.first { $0.path == path }
    }
}

/// One file row: status letter, name, directory, and a hover-revealed stage button.
struct FileChangeRow: View {
    @Environment(RepositoryService.self) private var service

    let change: FileChange
    let staged: Bool

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            StatusGlyph(change: change, staged: staged)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(change.fileName)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let conflict = change.conflictDescription {
                        BadgeLabel(text: conflict, tint: .red)
                    }
                }

                if !change.directory.isEmpty {
                    Text(displayDirectory)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer(minLength: 0)

            if isHovered && !change.isConflicted {
                Button {
                    Task {
                        if staged {
                            await service.unstage([change])
                        } else {
                            await service.stage([change])
                        }
                    }
                } label: {
                    Image(systemName: staged ? "minus.circle" : "plus.circle")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help(staged ? "Unstage this file" : "Stage this file")
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(helpText)
    }

    /// A rename shows both paths, since that is the change.
    private var displayDirectory: String {
        if let original = change.originalPath {
            return "\(original) → \(change.path)"
        }
        return change.directory
    }

    private var helpText: String {
        var lines = [change.path]
        if let original = change.originalPath { lines.append("renamed from \(original)") }
        lines.append(staged ? change.indexStatus.label : change.worktreeStatus.label)
        return lines.joined(separator: "\n")
    }
}

/// The single-letter status indicator, coloured by kind.
struct StatusGlyph: View {
    let change: FileChange
    let staged: Bool

    var body: some View {
        Text(String(letter))
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(tint)
            .frame(width: 12)
            .accessibilityLabel(status.label)
    }

    private var status: FileChange.Status {
        if change.kind == .untracked { return .added }
        return staged ? change.indexStatus : change.worktreeStatus
    }

    private var letter: Character {
        change.kind == .untracked ? "?" : status.rawValue
    }

    private var tint: Color {
        switch change.kind {
        case .untracked: return .secondary
        case .ignored: return .secondary
        case .unmerged: return .red
        case .tracked:
            switch status {
            case .added: return .green
            case .deleted: return .red
            case .renamed, .copied: return .purple
            case .modified, .typeChanged: return .orange
            case .unmodified, .unmerged: return .secondary
            }
        }
    }
}
