import AppKit
import GitTreesCore
import SwiftUI

/// The diff pane for the selected file.
///
/// This is a readable unified diff, not a merge editor: hunk and line staging are
/// deliberately out of scope, so the view only has to render what Git prints.
struct DiffView: View {
    @Environment(RepositoryService.self) private var service

    @State private var text: String = ""
    @State private var isLoading = false
    @State private var loadError: String?

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
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            if let file = service.selectedFile {
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

                Picker("Side", selection: Binding(
                    get: { service.showingStagedDiff },
                    set: { service.showingStagedDiff = $0 }
                )) {
                    Text("Working Tree").tag(false)
                    Text("Staged").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                .disabled(!file.hasStagedChanges || !file.hasUnstagedChanges)

                if isLoading {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                }
            } else {
                Text(selectionCount > 1 ? "\(selectionCount) Files Selected" : "Diff")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(GitTreesUI.barBackground)
    }

    /// Rows selected in Changes. More than one means there is no single diff to show.
    private var selectionCount: Int { service.selectedFileKeys.count }

    @ViewBuilder
    private var content: some View {
        if selectionCount > 1 {
            // A diff of one arbitrary file out of several would be worse than none: the
            // header would name a file the user did not single out.
            ContentUnavailableView(
                "\(selectionCount) Files Selected",
                systemImage: "doc.on.doc",
                description: Text("Right-click to stage, unstage or ignore them together, or select one file to see its diff.")
            )
        } else if service.selectedFile == nil {
            ContentUnavailableView(
                "No File Selected",
                systemImage: "doc.text",
                description: Text("Select a changed file to see its diff.")
            )
        } else if let loadError {
            ContentUnavailableView(
                "Could Not Load Diff",
                systemImage: "exclamationmark.triangle",
                description: Text(loadError)
            )
        } else if text.isEmpty && !isLoading {
            ContentUnavailableView(
                "No Textual Diff",
                systemImage: "doc",
                description: Text("Git produced no diff for this file. It may be binary, or the change may be a mode change only.")
            )
        } else {
            DiffTextView(diff: text)
        }
    }

    // MARK: - Loading

    /// Re-runs the diff whenever the file, the side of the index, or the underlying
    /// status changes.
    private var reloadKey: String {
        guard let file = service.selectedFile else { return "none" }
        return [
            file.path,
            service.showingStagedDiff ? "staged" : "worktree",
            file.rawXY,
            service.selectedWorktreePath ?? ""
        ].joined(separator: "|")
    }

    private func reload() async {
        guard let file = service.selectedFile else {
            text = ""
            loadError = nil
            return
        }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            text = try await service.diff(for: file, staged: service.showingStagedDiff)
        } catch is CancellationError {
            return
        } catch {
            text = ""
            loadError = error.localizedDescription
        }
    }
}

/// Renders a unified diff in an `NSTextView`.
///
/// A SwiftUI `Text` re-lays out its whole string on every change, which a few thousand
/// diff lines make expensive; an `NSTextView` also brings native selection, find and
/// scrolling, which a diff viewer needs anyway.
struct DiffTextView: NSViewRepresentable {
    let diff: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // Diffs are meaningfully column-aligned, so lines scroll rather than wrap.
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        context.coordinator.textView = textView
        apply(to: textView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        apply(to: textView, coordinator: context.coordinator)
    }

    private func apply(to textView: NSTextView, coordinator: Coordinator) {
        guard coordinator.lastDiff != diff else { return }
        coordinator.lastDiff = diff
        textView.textStorage?.setAttributedString(Self.attributed(diff))
        textView.scroll(NSPoint(x: 0, y: 0))
    }

    /// Colours each line by its unified-diff prefix. Nothing is parsed beyond the first
    /// character, so unusual diffs degrade to plain monospaced text.
    static func attributed(_ diff: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = GitTreesUI.monospacedNSFont
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping

        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            var colour = NSColor.labelColor
            var background: NSColor?

            if text.hasPrefix("+++") || text.hasPrefix("---") {
                colour = .secondaryLabelColor
            } else if text.hasPrefix("@@") {
                colour = .systemPurple
            } else if text.hasPrefix("diff ") || text.hasPrefix("index ")
                        || text.hasPrefix("new file") || text.hasPrefix("deleted file")
                        || text.hasPrefix("similarity index") || text.hasPrefix("rename ")
                        || text.hasPrefix("old mode") || text.hasPrefix("new mode") {
                colour = .secondaryLabelColor
            } else if text.hasPrefix("+") {
                colour = .systemGreen
                background = NSColor.systemGreen.withAlphaComponent(0.08)
            } else if text.hasPrefix("-") {
                colour = .systemRed
                background = NSColor.systemRed.withAlphaComponent(0.08)
            } else if text.hasPrefix("\\") {
                colour = .tertiaryLabelColor
            }

            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: colour,
                .paragraphStyle: paragraph
            ]
            if let background { attributes[.backgroundColor] = background }
            result.append(NSAttributedString(string: text + "\n", attributes: attributes))
        }
        return result
    }

    final class Coordinator {
        weak var textView: NSTextView?
        var lastDiff: String?
    }
}
