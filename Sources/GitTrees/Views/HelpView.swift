import SwiftUI

struct HelpView: View {
    @Environment(\.openWindow) private var openWindow

    private var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return version.map { "Version \($0)" + (build.map { " (\($0))" } ?? "") } ?? "Development build"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("GitTrees Help").font(.title.bold())
                    Text(version).font(.caption).foregroundStyle(.secondary)
                    Text("Work with branches and worktrees in one place.")
                }
                topic("Get started", "Open a repository with ⌘O. Select a worktree in the sidebar to see its Changes, History, Stashes and Repository details. Use New Worktree (⌘N) to work on another branch in a separate folder.")
                topic("Sidebar indicators", "Orange dot: uncommitted changes. Accent-colored dot (usually blue): clean worktree. Gray dot: status is loading. Hollow circle: no worktree. Orange triangle: a missing or stale worktree. Branches and worktrees use the same status; hover over a symbol for its meaning.")
                topic("Commit and sync", "Select a file to review its diff. Right-click files to stage or unstage them, enter a commit message, then Commit (⌘Return). Fetch reads remote updates; Pull brings them into your branch; Push publishes your commits. Refresh with ⌘R.")
                topic("Merge, rebase and Git Assist", "Open Merge / Rebase, choose another branch, and review the direction. Merge brings that branch into the current branch. Rebase replays the current branch onto the chosen branch. Git Assist explains the relationship and offers Fast-Forward when possible. Remote comparisons use the last fetched history.")
                topic("Resolve conflicts", "Select a conflicted file in Changes. Use Mine or Use Theirs chooses a whole side; you can also edit the file in your editor and stage it. Suggest Resolution offers an experimental on-device proposal for small text conflicts. Review the diff before Apply & Stage. Commit a resolved merge, or use Continue for a rebase; Abort returns to the pre-operation state.")
                topic("Apple Intelligence", "On supported Macs with macOS 26 or later, enable Apple Intelligence in System Settings. Commit drafts, explanations and conflict suggestions run on-device. Review suggestions before using them. Commit drafting falls back to the bundled local model when Apple Intelligence is unavailable; ordinary Git actions still work.")
                topic("Security scan", "Select a worktree, then choose Repository → Security Scan. Install Semgrep separately and set its path in Settings → Security Scan. Scan runs a small bundled ruleset locally, including Swift, Python, JavaScript/TypeScript, Java and key/configuration checks. Review findings by file and line. It does not apply fixes, audit dependencies or prove a repository safe. Ignored, oversized and unsupported files may be skipped.")
                topic("Useful shortcuts", "⌘O Open repository · ⌘N New worktree · ⇧⌘N New window\n⇧⌘F Fetch · ⇧⌘P Pull · ⇧⌘U Push\n⌥⌘S Stash · ⇧⌘D Open in editor · ⌘R Refresh")
                Button("Acknowledgements…") { openWindow(id: "acknowledgements") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .textSelection(.enabled)
        .frame(minWidth: 480, minHeight: 400)
    }

    private func topic(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AcknowledgementsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Acknowledgements").font(.title.bold())
                Text(resource("THIRD_PARTY_NOTICES")).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .textSelection(.enabled)
        .frame(minWidth: 480, minHeight: 400)
    }

    private func resource(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Acknowledgements"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "The bundled notice could not be loaded. Please rebuild GitTrees with its resource bundles."
        }
        return text
    }
}
