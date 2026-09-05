import AppKit
import SwiftUI

/// Shared visual tokens.
///
/// Everything derives from system colours so the app follows the user's appearance,
/// accent colour and increased-contrast settings without a bespoke theme.
enum GitTreesUI {
    static var fieldBackground: Color { Color(nsColor: .textBackgroundColor).opacity(0.5) }
    static var editorBackground: Color { Color(nsColor: .textBackgroundColor) }
    static var barBackground: Color { Color(nsColor: .windowBackgroundColor) }
    static var hoverFill: Color { Color(nsColor: .separatorColor).opacity(0.22) }
    static var border: Color { Color(nsColor: .separatorColor).opacity(0.55) }

    /// Dense list metrics, tuned to sit between Finder's list view and Xcode's navigator.
    static let rowVerticalPadding: CGFloat = 3
    static let rowHorizontalPadding: CGFloat = 6
    static let sectionSpacing: CGFloat = 2
    static let cornerRadius: CGFloat = 5

    static let monospaced = Font.system(size: 11, design: .monospaced)
    static var monospacedNSFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    }
}

/// The uppercase caption used for sidebar section headers.
struct SectionHeaderLabel: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption2.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            if let count {
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The filled/hollow dot that distinguishes a branch with a live worktree from one
/// without, and a dirty worktree from a clean one.
struct WorktreeIndicator: View {
    enum State {
        /// Checked out in a worktree with uncommitted changes.
        case dirty
        /// Checked out in a clean worktree.
        case clean
        /// Checked out, dirtiness not yet known.
        case unknown
        /// No worktree.
        case inactive
        /// Git reports the worktree as prunable or its directory is gone.
        case stale
    }

    let state: State

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 7))
            .foregroundStyle(tint)
            .frame(width: 9)
            .accessibilityLabel(accessibilityLabel)
    }

    private var symbol: String {
        switch state {
        case .dirty, .clean, .unknown: "circle.fill"
        case .inactive: "circle"
        case .stale: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch state {
        case .dirty: .orange
        case .clean: .accentColor
        case .unknown: Color.secondary.opacity(0.6)
        case .inactive: Color.secondary.opacity(0.45)
        case .stale: .orange
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .dirty: "Has uncommitted changes"
        case .clean: "Clean worktree"
        case .unknown: "Checked out"
        case .inactive: "No worktree"
        case .stale: "Stale worktree"
        }
    }
}

/// A small monospaced count badge, e.g. `↑2 ↓1`.
struct TrackingBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

/// A labelled text-entry row for a grouped `Form`.
///
/// A plain `TextField` with a title lets the form hoist the label into its own column
/// and right-align the value, which reads badly for paths, branch names and email
/// addresses — and `multilineTextAlignment` does not override it. Putting the label
/// above a label-less field keeps the value left-justified and gives it the full width.
struct LabelledFieldRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.callout)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// Standard bordered container used for lists and the diff pane.
    func panelChrome(cornerRadius: CGFloat = 6) -> some View {
        self
            .background(GitTreesUI.fieldBackground, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius).stroke(GitTreesUI.border)
            }
    }
}
