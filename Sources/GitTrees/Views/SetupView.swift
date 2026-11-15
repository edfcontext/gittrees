import AppKit
import GitTreesCore
import SwiftUI

/// First-run guide. Checks use the same configured executables as the app.
struct SetupView: View {
    @Environment(PreferencesService.self) private var preferences
    @Environment(RepositoryService.self) private var service
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hasSeenSetup") private var hasSeenSetup = false
    @State private var gitStatus = "Not checked"
    @State private var gitReady = false
    @State private var checking = false
    @State private var choosingGit = false
    @State private var choosingGH = false

    var body: some View {
        @Bindable var preferences = preferences
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to GitTrees").font(.largeTitle.bold())
            Text("GitTrees uses tools installed on your Mac. Check them here before opening a repository. You can return to this guide from the Help menu.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("1. Git", systemImage: gitReady ? "checkmark.circle.fill" : "exclamationmark.circle")
                                .font(.headline).foregroundStyle(gitReady ? .green : .primary)
                            Text("Required for repositories, branches, and worktrees.")
                            Text(gitStatus).font(.caption).textSelection(.enabled)
                            HStack {
                                TextField("Git executable", text: $preferences.gitExecutablePath).textFieldStyle(.roundedBorder)
                                Button("Choose…") { choosingGit = true }
                                    .fileImporter(isPresented: $choosingGit, allowedContentTypes: [.item]) { result in
                                        if case .success(let url) = result { preferences.gitExecutablePath = url.path }
                                    }
                            }
                            Text("On a new Mac, install Apple Command Line Tools: open Terminal, run the command below, and complete Apple's installer. If you use another Git installation, choose its executable above.")
                            command("xcode-select --install")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("2. GitHub CLI", systemImage: service.gitHubAuth.isReady ? "checkmark.circle.fill" : "circle")
                                .font(.headline).foregroundStyle(service.gitHubAuth.isReady ? .green : .primary)
                            Text("Optional. Install and sign in to use GitHub pull request features. Local Git operations work without it.")
                            Text(service.gitHubAuth.summary).font(.caption)
                            HStack {
                                TextField("GitHub CLI executable", text: $preferences.gitHubExecutablePath).textFieldStyle(.roundedBorder)
                                Button("Choose…") { choosingGH = true }
                                    .fileImporter(isPresented: $choosingGH, allowedContentTypes: [.item]) { result in
                                        if case .success(let url) = result { preferences.gitHubExecutablePath = url.path }
                                    }
                            }
                            Text("Install GitHub CLI using its official instructions or, if you have Homebrew, run:")
                            command("brew install gh")
                            Link("GitHub CLI installation instructions", destination: URL(string: "https://github.com/cli/cli#installation")!)
                            Text("Then run the following in Terminal and follow the prompts to sign in. For HTTPS Git operations, choose to authenticate Git when prompted.")
                            command("gh auth login")
                            Text("After installing or signing in, return here and select Check Again. GitHub Enterprise users can sign in to their host with gh auth login --hostname HOST.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("3. Commit identity").font(.headline)
                            Text("Git needs a name and email to create commits. Configure them in your repository's Info tab, or use your existing Git configuration. GitTrees does not change your global identity during setup.")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.font(.callout)
            }
            HStack {
                Button(checking ? "Checking…" : "Check Again") { Task { await check() } }.disabled(checking)
                Spacer()
                Button("Continue") { hasSeenSetup = true; dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 680, height: 650)
        .task { await check() }
        .onChange(of: preferences.gitExecutablePath) { _, _ in service.rebuildClientIfNeeded() }
        .onChange(of: preferences.gitHubExecutablePath) { _, _ in service.rebuildClientIfNeeded() }
    }

    private func command(_ value: String) -> some View {
        HStack {
            Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Spacer()
            Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
        }.padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    @MainActor private func check() async {
        checking = true
        defer { checking = false }
        // A fresh install may have the system shim without the developer tools. Avoid
        // invoking it until xcode-select reports an active developer directory.
        let path = preferences.gitExecutablePath
        if path == "/usr/bin/git" && !developerToolsSelected() {
            gitReady = false
            gitStatus = "Apple Command Line Tools are not selected. Install them using the command below."
        } else {
            do {
                let result = try await GitProcessRunner(executablePath: path).run(GitCommand(["--version"]))
                gitReady = true
                gitStatus = result.trimmedStdout
            } catch {
                gitReady = false
                gitStatus = "Git could not be run at \(path). Check the path or install Git."
            }
        }
        // Pick up a standard gh installation made after the app was launched, without
        // overwriting a custom path the user selected.
        if !FileManager.default.isExecutableFile(atPath: preferences.gitHubExecutablePath),
           GitHubProcessRunner.knownExecutablePaths.contains(preferences.gitHubExecutablePath) {
            preferences.gitHubExecutablePath = GitHubProcessRunner.defaultExecutablePath
        }
        service.rebuildClientIfNeeded()
        service.refreshGitHub()
    }

    private func developerToolsSelected() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 }
        catch { return false }
    }
}
