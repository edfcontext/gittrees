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
    @Environment(AppCommands.self) private var commands

    /// The List drives its own `@State` rather than a binding computed from the service.
    /// A computed binding works for the modifier-click gestures but leaves a plain click
    /// unable to reduce the selection, so the two are kept in step explicitly instead.
    @State private var selection: Set<String> = []

    var body: some View {
        List(selection: $selection) {
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
        // Right-clicking inside the selection acts on all of it; right-clicking a row
        // outside acts on that row alone, without disturbing the selection. Getting that
        // from the List rather than from a per-row menu is what makes it behave the way
        // every other macOS list does.
        .contextMenu(forSelectionType: String.self) { keys in
            contextMenu(for: keys)
        }
        .onChange(of: selection) { _, keys in
            service.selectedFileKeys = keys
            service.focusSelectedFile(resettingSide: true)
        }
        // The service prunes the selection when status is reread and empties it when the
        // worktree changes; both have to reach the list.
        .onChange(of: service.selectedFileKeys) { _, keys in
            if keys != selection { selection = keys }
        }
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

    /// One row of the list: a change, plus which side of the index it is shown for.
    ///
    /// The pair is the identity. A partially staged file is the *same* `FileChange` in
    /// both the Staged and Changes sections, so identifying rows by the change alone
    /// gives the List two rows with one identity — and it then highlights whichever row
    /// it likes rather than the one that was clicked.
    private struct Row: Identifiable {
        let change: FileChange
        let staged: Bool

        var id: String { WorktreeStatus.selectionKey(path: change.path, staged: staged) }
    }

    @ViewBuilder
    private func section(title: String, changes: [FileChange], staged: Bool, action: RowAction?) -> some View {
        if !changes.isEmpty {
            Section {
                ForEach(changes.map { Row(change: $0, staged: staged) }) { row in
                    FileChangeRow(change: row.change, staged: row.staged)
                        .tag(row.id)
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

    // MARK: - Context menu

    /// One menu for however many rows the click covers, so a single selection reads
    /// exactly as it did before and a multiple selection says how many it will act on.
    @ViewBuilder
    private func contextMenu(for keys: Set<String>) -> some View {
        let rows = self.rows(for: keys)
        let toStage = rows.filter { !$0.staged }.map(\.change)
        let toUnstage = rows.filter(\.staged).map(\.change)
        let untracked = rows.map(\.change).filter { $0.kind == .untracked }

        if !toStage.isEmpty {
            Button(stageTitle(for: toStage)) { Task { await service.stage(toStage) } }
        }
        if !toUnstage.isEmpty {
            Button(count(toUnstage, one: "Unstage File", many: { "Unstage \($0) Files" })) {
                Task { await service.unstage(toUnstage) }
            }
        }

        // Ignoring only makes sense for paths Git is not already tracking, so the items
        // appear only when every selected row is untracked.
        if !untracked.isEmpty, untracked.count == rows.count {
            Divider()
            Button(count(untracked, one: "Add to .gitignore", many: { "Add \($0) Files to .gitignore" })) {
                Task { await service.ignore(untracked) }
            }
            if let only = untracked.first, untracked.count == 1 {
                if !only.directory.isEmpty {
                    Button("Ignore Folder “\(only.directory)”") {
                        Task { await service.ignoreDirectory(of: only) }
                    }
                }
                Button("Ignore…") { commands.ignore(path: only.path) }
            }
        }

        if !rows.isEmpty {
            Divider()
            Button(count(rows.map(\.change), one: "Copy Path", many: { "Copy \($0) Paths" })) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    rows.map(\.change.path).joined(separator: "\n"),
                    forType: .string
                )
            }
        }
    }

    /// A conflicted file is staged to mark it resolved, which is worth saying.
    private func stageTitle(for changes: [FileChange]) -> String {
        guard changes.allSatisfy(\.isConflicted) else {
            return count(changes, one: "Stage File", many: { "Stage \($0) Files" })
        }
        return count(changes, one: "Stage Resolved File", many: { "Stage \($0) Resolved Files" })
    }

    /// Singular label, or a plural label built from the count. `many` takes the count so
    /// it is interpolated directly — `String(format:)` with `%d` mismatches a Swift `Int`.
    private func count(_ changes: [FileChange], one: String, many: (Int) -> String) -> String {
        changes.count == 1 ? one : many(changes.count)
    }

    // MARK: - Selection

    /// The rows a set of selection keys names, in the order the list shows them, so the
    /// menu's counts and the pasteboard match what is on screen.
    private func rows(for keys: Set<String>) -> [Row] {
        let ordered =
            service.status.conflicts.map { Row(change: $0, staged: false) }
            + service.status.stagedChanges.map { Row(change: $0, staged: true) }
            + service.status.unstagedChanges.map { Row(change: $0, staged: false) }
        return ordered.filter { keys.contains($0.id) }
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
