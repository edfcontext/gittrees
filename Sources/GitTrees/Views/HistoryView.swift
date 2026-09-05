import GitTreesCore
import SwiftUI

/// A flat commit list for the selected worktree.
///
/// Deliberately not a commit graph: this exists to answer "what is on this branch",
/// and the graph rendering a full client would add is out of scope.
struct HistoryView: View {
    @Environment(RepositoryService.self) private var service

    var body: some View {
        Group {
            if service.history.isEmpty {
                ContentUnavailableView(
                    "No Commits",
                    systemImage: "clock",
                    description: Text("This worktree has no commit history yet.")
                )
            } else {
                Table(service.history) {
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
                            // A commit every branch points at would otherwise fill the
                            // column with unreadable badges and hide the subject.
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
        }
        .contextMenu {
            Button("Refresh") { service.refreshSelectedWorktree() }
        }
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
