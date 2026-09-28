import GitTreesCore
import SwiftUI

/// A process-wide overview of the repositories whose windows are currently open.
///
/// The panel is shown as a trailing inspector in each repository window. Multiple
/// windows for the same repository collapse into one row, because this is a repository
/// overview rather than a window switcher.
struct OpenRepositoriesPanel: View {
    @Environment(AppSession.self) private var session
    @Environment(RepositoryService.self) private var currentService

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if repositories.isEmpty {
                ContentUnavailableView(
                    "No Open Repositories",
                    systemImage: "folder",
                    description: Text("Repositories appear here while their GitTrees windows are open.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(repositories) { repository in
                            OpenRepositoryRow(repository: repository)
                        }
                    }
                    .padding(10)
                }
            }
        }
        .background(GitTreesUI.barBackground)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Open Repositories")
                .font(.headline)
            Text("\(repositories.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Newest repositories appear first, matching the panel's purpose as a quick way
    /// to find the project most recently worked on.
    private var repositories: [OpenRepositorySummary] {
        var summaries: [String: OpenRepositorySummary] = [:]

        for service in session.openRepositoryServices {
            guard let repository = service.repository else { continue }
            let candidate = OpenRepositorySummary(
                id: repository.id,
                name: repository.name,
                path: repository.mainWorktreePath,
                isBare: repository.isBare,
                linkedWorktreeCount: service.linkedWorktreeCount,
                lastActivityAt: service.repositoryLastActivityDate,
                isCurrentWindow: service === currentService
            )

            if let existing = summaries[repository.id] {
                summaries[repository.id] = existing.merging(candidate)
            } else {
                summaries[repository.id] = candidate
            }
        }

        return summaries.values.sorted { left, right in
            switch (left.lastActivityAt, right.lastActivityAt) {
            case let (leftDate?, rightDate?) where leftDate != rightDate:
                return leftDate > rightDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
        }
    }
}

private struct OpenRepositorySummary: Identifiable {
    let id: String
    let name: String
    let path: URL
    let isBare: Bool
    let linkedWorktreeCount: Int
    let lastActivityAt: Date?
    let isCurrentWindow: Bool

    func merging(_ other: Self) -> Self {
        Self(
            id: id,
            name: name,
            path: path,
            isBare: isBare,
            linkedWorktreeCount: max(linkedWorktreeCount, other.linkedWorktreeCount),
            lastActivityAt: [lastActivityAt, other.lastActivityAt].compactMap { $0 }.max(),
            isCurrentWindow: isCurrentWindow || other.isCurrentWindow
        )
    }
}

private struct OpenRepositoryRow: View {
    let repository: OpenRepositorySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(repository.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                if repository.isCurrentWindow {
                    BadgeLabel(text: "this window", tint: .accentColor)
                }
            }

            Text(RepositorySidebar.abbreviate(repository.path))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)

            Label(worktreeLabel, systemImage: worktreeSymbol)
                .font(.caption)
                .foregroundStyle(repository.linkedWorktreeCount > 0 ? Color.green : Color.secondary)

            if let lastActivityAt = repository.lastActivityAt {
                Label {
                    Text(lastActivityAt.formatted(date: .abbreviated, time: .shortened))
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "clock")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Last activity: \(lastActivityAt.formatted(date: .long, time: .standard))")
            } else {
                Label("Activity unavailable", systemImage: "clock.badge.questionmark")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GitTreesUI.fieldBackground,
            in: RoundedRectangle(cornerRadius: GitTreesUI.cornerRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: GitTreesUI.cornerRadius)
                .stroke(GitTreesUI.border, lineWidth: repository.isCurrentWindow ? 1.5 : 0.5)
        }
        .help(repository.path.path)
    }

    private var worktreeLabel: String {
        if repository.linkedWorktreeCount == 1 { return "1 linked worktree" }
        if repository.linkedWorktreeCount > 1 {
            return "\(repository.linkedWorktreeCount) linked worktrees"
        }
        return repository.isBare ? "Bare repository" : "Main worktree only"
    }

    private var worktreeSymbol: String {
        repository.linkedWorktreeCount > 0 ? "square.stack.3d.up.fill" : "square"
    }
}
