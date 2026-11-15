import Foundation
import Testing
@testable import GitTreesCore

@Suite("Selected branch graph")
struct CommitGraphTests {
    @Test("selected histories include real merge parents, exclude unrelated tips and hide unselected labels")
    func selectedMergeHistory() async throws {
        let fixture = try await GitClientIntegrationTests.Fixture()
        defer { fixture.cleanUp() }
        let root = try #require(try await fixture.client.headCommit(worktree: fixture.repository))
        try await fixture.git(["checkout", "-qb", "feature/日本語;literal"])
        try await fixture.git(["commit", "--allow-empty", "-qm", "feature | subject, with punctuation"])
        let feature = try #require(try await fixture.client.headCommit(worktree: fixture.repository))
        try await fixture.git(["checkout", "-q", "main"])
        try await fixture.git(["commit", "--allow-empty", "-qm", "main change"])
        try await fixture.git(["merge", "--no-ff", "-qm", "merge feature", "feature/日本語;literal"])
        let merge = try #require(try await fixture.client.headCommit(worktree: fixture.repository))
        try await fixture.git(["branch", "hidden-label", merge])
        try await fixture.git(["update-ref", "refs/remotes/origin/main", merge])
        try await fixture.git(["checkout", "-qb", "unselected", root])
        try await fixture.git(["commit", "--allow-empty", "-qm", "must not appear"])
        let unselected = try #require(try await fixture.client.headCommit(worktree: fixture.repository))
        let branches = try await fixture.client.branches(repository: fixture.repository)
        let selected = branches.filter { ["main", "feature/日本語;literal", "origin/main"].contains($0.name) }
        let graph = try await fixture.client.graph(repository: fixture.repository, branches: selected)

        #expect(graph.commits.count == 4)
        #expect(!graph.hasMore)
        #expect(!graph.commits.contains { $0.id == unselected })
        #expect(graph.commits.contains { $0.id == feature })
        let mergeCommit = try #require(graph.commits.first { $0.id == merge })
        #expect(mergeCommit.isMerge)
        #expect(mergeCommit.parentHashes.count == 2)
        #expect(mergeCommit.parentHashes.contains(feature))
        #expect(mergeCommit.branchNames == ["main", "origin/main"])
        #expect(graph.commits.allSatisfy { !$0.summary.refNames.contains("hidden-label") })
        #expect(graph.commits.first { $0.id == feature }?.summary.subject == "feature | subject, with punctuation")
        // Topological ordering is required by the renderer, even for skewed commit dates.
        let positions = Dictionary(uniqueKeysWithValues: graph.commits.enumerated().map { ($1.id, $0) })
        for (index, commit) in graph.commits.enumerated() {
            for parent in commit.parentHashes {
                #expect(try #require(positions[parent]) > index)
            }
        }
        try assertConnections(graph.commits)

        // One selected tip still retains the histories that actually merged into it.
        let onlyMain = try await fixture.client.graph(repository: fixture.repository,
                                                     branches: selected.filter { $0.name == "main" })
        #expect(onlyMain.commits.count == 4)
        #expect(onlyMain.commits.flatMap(\.branchNames) == ["main"])
    }

    @Test("empty selection never falls back to HEAD; missing objects report errors")
    func emptyAndMissing() async throws {
        let fixture = try await GitClientIntegrationTests.Fixture()
        defer { fixture.cleanUp() }
        let empty = try await fixture.client.graph(repository: fixture.repository, branches: [])
        #expect(empty.commits.isEmpty)
        let missing = Branch(refName: "refs/heads/missing", name: "missing", kind: .local,
                             objectName: String(repeating: "a", count: 40))
        await #expect(throws: GitError.self) {
            try await fixture.client.graph(repository: fixture.repository, branches: [missing])
        }
        let invalid = Branch(refName: "refs/heads/bad", name: "bad", kind: .local, objectName: "--all")
        await #expect(throws: GitError.self) {
            try await fixture.client.graph(repository: fixture.repository, branches: [invalid])
        }
    }

    @Test("legend recovers a deleted branch name from a real merge, even before its parent is loaded")
    func deletedMergeSource() async throws {
        let fixture = try await GitClientIntegrationTests.Fixture()
        defer { fixture.cleanUp() }
        let name = "feature/日本語'quoted"
        try await fixture.git(["checkout", "-qb", name])
        try await fixture.git(["commit", "--allow-empty", "-qm", "feature change"])
        let source = try #require(try await fixture.client.headCommit(worktree: fixture.repository))
        try await fixture.git(["checkout", "-q", "main"])
        try await fixture.git(["commit", "--allow-empty", "-qm", "main change"])
        try await fixture.git(["merge", "--no-ff", "--no-edit", name])
        try await fixture.git(["branch", "-D", name])
        let branches = try await fixture.client.branches(repository: fixture.repository)
        let graph = try await fixture.client.graph(repository: fixture.repository, branches: branches, limit: 1)
        let merge = try #require(graph.commits.first)
        #expect(graph.hasMore)
        #expect(merge.mergedParentNames[source] == [name])
        #expect(merge.branchNames == ["main"])
        #expect(CommitGraphLayout(commits: graph.commits).legend.contains { $0.label == name })
    }

    @Test("custom merge messages use matching refs without adding unrelated history or unselected tip badges")
    func mergeSourceFromRefs() async throws {
        let fixture = try await GitClientIntegrationTests.Fixture()
        defer { fixture.cleanUp() }
        try await fixture.git(["checkout", "-qb", "feature/existing"])
        try await fixture.git(["commit", "--allow-empty", "-qm", "feature change"])
        let source = try #require(try await fixture.client.headCommit(worktree: fixture.repository))
        try await fixture.git(["checkout", "-q", "main"])
        try await fixture.git(["merge", "--no-ff", "-m", "Integrate reviewed changes", "feature/existing"])
        try await fixture.git(["checkout", "-qb", "unrelated"])
        try await fixture.git(["commit", "--allow-empty", "-qm", "unrelated commit"])
        let unrelated = try #require(try await fixture.client.headCommit(worktree: fixture.repository))
        let branches = try await fixture.client.branches(repository: fixture.repository)
        let graph = try await fixture.client.graph(repository: fixture.repository,
                                                  branches: branches.filter { $0.name == "main" }, limit: 1)
        let merge = try #require(graph.commits.first)
        #expect(merge.mergedParentNames[source] == ["feature/existing"])
        #expect(graph.commits.flatMap(\.branchNames) == ["main"])
        #expect(!graph.commits.contains { $0.id == unrelated })
        #expect(CommitGraphLayout(commits: graph.commits).legend.contains { $0.label == "feature/existing" })
    }

    @Test("octopus merge names stay associated with their respective parents after branch deletion")
    func octopusSourceNames() async throws {
        let fixture = try await GitClientIntegrationTests.Fixture()
        defer { fixture.cleanUp() }
        var sources: [String: String] = [:]
        for name in ["feature/left", "feature/right"] {
            try await fixture.git(["checkout", "-qb", name, "main"])
            try await fixture.git(["commit", "--allow-empty", "-qm", name])
            sources[name] = try #require(try await fixture.client.headCommit(worktree: fixture.repository))
        }
        try await fixture.git(["checkout", "-q", "main"])
        try await fixture.git(["commit", "--allow-empty", "-qm", "main change"])
        try await fixture.git(["merge", "--no-ff", "--no-edit", "feature/right", "feature/left"])
        try await fixture.git(["branch", "-D", "feature/left", "feature/right"])
        let branches = try await fixture.client.branches(repository: fixture.repository)
        let graph = try await fixture.client.graph(repository: fixture.repository, branches: branches, limit: 1)
        let merge = try #require(graph.commits.first)
        #expect(merge.parentHashes.count == 3)
        for (name, hash) in sources { #expect(merge.mergedParentNames[hash] == [name]) }
        #expect(CommitGraphLayout(commits: graph.commits).legend.flatMap(\.branchNames).sorted()
                == ["feature/left", "feature/right", "main"])
    }

    @Test("merge subject names handle Git, pull requests and ambiguous custom messages conservatively")
    func mergeSubjects() {
        let examples: [(String, Int, [String]?)] = [
            ("Merge branch 'feature/a' into 'main'", 1, ["feature/a"]),
            ("Merge branch 'refs/heads/main' into cursor/topic", 1, ["main"]),
            ("Merge remote-tracking branch 'refs/remotes/origin/topic'", 1, ["origin/topic"]),
            ("Merge pull request #1 from edfcontext/cursor/commit-intent-coreml", 1, ["edfcontext/cursor/commit-intent-coreml"]),
            ("Merged in feature/topic (pull request #42)", 1, ["feature/topic"]),
            ("Merge branches 'a', 'b' and 'c' into main", 3, ["a", "b", "c"]),
            ("Merge branches 'a' and 'b'", 1, nil),
            ("Merge branch 'a'", 2, nil),
            ("Merge branch 'not a branch name'", 1, nil),
            ("Merge pull request #oops from owner/topic", 1, nil),
            ("Merge pull request #2 from owner/topic with custom notes", 1, nil),
            ("Integrate reviewed changes", 1, nil),
            ("Merge branch 'feature/a'", 0, nil)
        ]
        for (subject, count, expected) in examples {
            #expect(MergeSourceParser.names(subject: subject, sourceCount: count) == expected, Comment(rawValue: subject))
        }
    }

    @Test("unrecoverable names identify the merge instead of inventing an ancestry branch number")
    func unknownSourceName() {
        let layout = CommitGraphLayout(commits: [node("abc1234", ["a", "b"], branches: ["main"])])
        let unnamed = layout.legend.first { $0.branchNames.isEmpty }
        #expect(unnamed?.label == "Merge abc1234")
        #expect(unnamed?.mergeCommitHashes == ["abc1234"])
    }

    @Test("history limits retain parent connections and loading more reaches the root")
    func limits() async throws {
        let fixture = try await GitClientIntegrationTests.Fixture()
        defer { fixture.cleanUp() }
        for index in 0..<3 {
            try await fixture.git(["commit", "--allow-empty", "-qm", "commit \(index)"])
        }
        let branches = try await fixture.client.branches(repository: fixture.repository)
        let partial = try await fixture.client.graph(repository: fixture.repository, branches: branches, limit: 2)
        #expect(partial.hasMore)
        #expect(partial.commits.count == 2)
        #expect(CommitGraphLayout(commits: partial.commits).continuingLaneCount == 1)
        let complete = try await fixture.client.graph(repository: fixture.repository, branches: branches, limit: 4)
        #expect(!complete.hasMore)
        #expect(complete.commits.count == 4)
        #expect(CommitGraphLayout(commits: complete.commits).continuingLaneCount == 0)
        #expect(Array(complete.commits.prefix(2)) == partial.commits)
    }

    @Test("shallow boundaries are distinct from roots, including linked worktrees and bare clones",
          arguments: [1, 2])
    func shallowHistory(depth: Int) async throws {
        let fixture = try await GitClientIntegrationTests.Fixture()
        defer { fixture.cleanUp() }
        for index in 0..<2 {
            try await fixture.git(["commit", "--allow-empty", "-qm", "commit \(index)"])
        }
        let sourceBranches = try await fixture.client.branches(repository: fixture.repository)
        let source = try await fixture.client.graph(repository: fixture.repository, branches: sourceBranches)
        #expect(source.commits.count == 3)
        #expect(!source.hasShallowBoundary)
        #expect(source.commits.last?.parentHashes.isEmpty == true)

        let clone = fixture.worktreeRoot("shallow clone")
        // A file URL forces the transport path: a plain local clone ignores --depth.
        try await fixture.git(["clone", "--quiet", "--depth=\(depth)", fixture.repository.absoluteString, clone.path])
        let branches = try await fixture.client.branches(repository: clone)
        let graph = try await fixture.client.graph(repository: clone, branches: branches)
        #expect(graph.commits.count == depth)
        #expect(!graph.hasMore)
        #expect(graph.hasShallowBoundary)
        let boundary = try #require(graph.commits.last)
        #expect(boundary.isShallowBoundary)
        #expect(boundary.parentHashes.isEmpty)
        #expect(graph.commits.dropLast().allSatisfy { !$0.isShallowBoundary })
        // Git's walk omits these parents, but they exist in the actual commit object.
        let raw = try await fixture.git(["cat-file", "-p", boundary.id], in: clone).stdoutText
        #expect(raw.split(separator: "\n").contains { $0.hasPrefix("parent ") })

        if depth > 1 {
            let page = try await fixture.client.graph(repository: clone, branches: branches, limit: 1)
            #expect(page.hasMore)
            #expect(!page.hasShallowBoundary, "Only a boundary in the displayed commits should trigger the notice.")
        }

        let linked = fixture.worktreeRoot("linked checkout")
        try await fixture.git(["worktree", "add", "--quiet", "--detach", linked.path], in: clone)
        let linkedGraph = try await fixture.client.graph(repository: linked, branches: branches)
        #expect(linkedGraph.commits == graph.commits)

        let bare = fixture.worktreeRoot("shallow bare.git")
        try await fixture.git(["clone", "--quiet", "--bare", "--depth=\(depth)",
                               fixture.repository.absoluteString, bare.path])
        let bareBranches = try await fixture.client.branches(repository: bare)
        let bareGraph = try await fixture.client.graph(repository: bare, branches: bareBranches)
        #expect(bareGraph.hasShallowBoundary)
        #expect(bareGraph.commits.last?.id == boundary.id)

        try await fixture.git(["fetch", "--quiet", "--unshallow", "origin"], in: clone)
        let complete = try await fixture.client.graph(repository: clone, branches: branches)
        #expect(complete.commits.count == 3)
        #expect(!complete.hasShallowBoundary)
        #expect(!complete.hasMore)
        #expect(complete.commits.last?.parentHashes.isEmpty == true)
    }

    @Test("snapshot tips stay consistent when a branch moves after selection")
    func snapshot() async throws {
        let fixture = try await GitClientIntegrationTests.Fixture()
        defer { fixture.cleanUp() }
        let branches = try await fixture.client.branches(repository: fixture.repository)
        try await fixture.git(["commit", "--allow-empty", "-qm", "later commit"])
        let graph = try await fixture.client.graph(repository: fixture.repository, branches: branches)
        #expect(graph.commits.count == 1)
        #expect(graph.commits.first?.branchNames == ["main"])
        #expect(graph.commits.first?.id == branches.first?.objectName)
    }

    @Test("layout preserves each parent path through octopus merges, shared ancestors and disconnected roots")
    func complexLayout() throws {
        let commits = [node("m", ["a", "b", "c"]), node("a", ["r"]), node("b", ["r"]),
                       node("x", ["y"]), node("c", ["r"]), node("y", []), node("r", [])]
        try assertConnections(commits)
        #expect(CommitGraphLayout(commits: commits).continuingLaneCount == 0)
        #expect(CommitGraphLayout(commits: []).rows.isEmpty)
    }

    @Test("NUL metadata preserves empty parents and rejects truncated records")
    func parser() throws {
        let data = Data("root\u{0}roo\u{0}Author 日本語\u{0}2026-11-11T12:00:00Z\u{0}\u{0}Subject | text\u{0}".utf8)
        let commits = try CommitGraphParser.parse(data, branches: [])
        #expect(commits.count == 1)
        #expect(commits.first?.parentHashes == [])
        #expect(commits.first?.summary.authorName == "Author 日本語")
        #expect(try CommitGraphParser.parse(Data(), branches: []).isEmpty)
        #expect(throws: GitError.self) {
            try CommitGraphParser.parse(Data("hash\u{0}partial\u{0}".utf8), branches: [])
        }
    }

    @Test("graph dates preserve Git's UTC and signed timezone offsets", arguments: [
        ("Z", 0), ("+00:00", 0), ("+05:30", 19_800), ("-07:00", -25_200), ("+14:00", 50_400)
    ])
    func graphDateOffsets(_ sample: (String, Int)) throws {
        let data = Data("hash\u{0}has\u{0}Author\u{0}2026-11-11T12:00:00\(sample.0)\u{0}\u{0}Subject\u{0}".utf8)
        let commit = try #require(try CommitGraphParser.parse(data, branches: []).first)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let noonUTC = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 12)))
        #expect(commit.summary.authorDate == noonUTC.addingTimeInterval(-Double(sample.1)))
    }

    @Test("invalid graph dates still fail instead of displaying fabricated timestamps")
    func invalidGraphDate() {
        let data = Data("hash\u{0}has\u{0}Author\u{0}invalid-date\u{0}\u{0}Subject\u{0}".utf8)
        #expect(throws: GitError.self) { try CommitGraphParser.parse(data, branches: []) }
    }

    @Test("legend matches selected branch paths, groups shared colors and includes unnamed merge ancestry")
    func colorLegend() throws {
        let commits = [node("merge", ["main-parent", "feature", "unnamed"], branches: ["main", "origin/main"]),
                       node("main-parent", ["root"], branches: ["release"]),
                       node("feature", ["root"], branches: ["feature/topic"]),
                       node("unnamed", ["root"]), node("root", [])]
        let layout = CommitGraphLayout(commits: commits)
        let main = try #require(layout.rows.first)
        let feature = try #require(layout.rows.first { $0.id == "feature" })
        #expect(main.color != feature.color)
        #expect(layout.legend.first { $0.color == main.color }?.branchNames == ["main", "origin/main", "release"])
        #expect(layout.legend.first { $0.color == feature.color }?.branchNames == ["feature/topic"])
        #expect(layout.legend.contains { $0.branchNames.isEmpty })
        let used = Set(layout.rows.flatMap { [$0.color] + $0.lines.map(\.color) })
        #expect(Set(layout.legend.map(\.color)) == used)
        #expect(layout.legend.flatMap(\.branchNames).sorted() == ["feature/topic", "main", "origin/main", "release"])
        #expect(CommitGraphLayout(commits: []).legend.isEmpty)
        try assertConnections(commits)
    }

    @Test("legend includes merge paths before their branch tips enter the loaded history")
    func partialLegend() throws {
        let commits = [node("merge", ["a", "b"], branches: ["main"]),
                       node("a", ["root"]), node("b", ["root"], branches: ["feature"]), node("root", [])]
        let partial = CommitGraphLayout(commits: Array(commits.prefix(1)))
        let complete = CommitGraphLayout(commits: commits)
        #expect(partial.legend.count == 2)
        #expect(partial.legend.contains { $0.branchNames.isEmpty })
        for row in partial.rows {
            #expect(complete.rows.first { $0.id == row.id }?.color == row.color)
        }
        let feature = try #require(complete.legend.first { $0.branchNames == ["feature"] })
        #expect(partial.legend.first { $0.color == feature.color }?.branchNames == [])
    }

    @Test("wide histories retain every merge connection after frontier indexing")
    func wideHistory() throws {
        let tips = (0..<100).map { "tip-\($0)" }
        let commits = [node("merge", tips, branches: ["main"])]
            + tips.map { node($0, ["root"], branches: [$0]) } + [node("root", [])]
        try assertConnections(commits)
        #expect(CommitGraphLayout(commits: commits).legend.count == 100)
    }

    @Test("background preparation preserves topology and honors cancellation")
    @MainActor
    func backgroundPreparation() async throws {
        let commits = (0..<2_000).map {
            node("commit-\($0)", $0 == 1_999 ? [] : ["commit-\($0 + 1)"], branches: $0 == 0 ? ["main"] : [])
        }
        let prepared = try await CommitGraphLayout.prepare(commits: commits)
        #expect(prepared.rows.map(\.id) == commits.map(\.id))
        #expect(prepared.laneCount == 1)
        #expect(prepared.continuingLaneCount == 0)
        #expect(prepared.legend.first?.branchNames == ["main"])
        let cancelled = Task { try await CommitGraphLayout.prepare(commits: commits) }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }

    private func node(_ id: String, _ parents: [String], branches: [String] = []) -> GraphCommit {
        GraphCommit(summary: CommitSummary(hash: id, abbreviatedHash: id, subject: id,
                                          authorName: "Test", authorDate: .distantPast),
                    parentHashes: parents, branchNames: branches)
    }

    /// Trace every emitted parent edge through intervening rows and verify it reaches
    /// the correct parent node. This checks topology, not a particular lane arrangement.
    private func assertConnections(_ commits: [GraphCommit]) throws {
        let layout = CommitGraphLayout(commits: commits)
        for (index, row) in layout.rows.enumerated() {
            let outgoing = row.lines.filter { $0.fromPosition == .node && $0.toPosition == .bottom }
            #expect(outgoing.count == row.commit.parentHashes.count)
            for (parent, edge) in zip(row.commit.parentHashes, outgoing) {
                var lane = edge.toLane
                var found = false
                for later in layout.rows.dropFirst(index + 1) {
                    let line = try #require(later.lines.first { $0.fromPosition == .top && $0.fromLane == lane })
                    if line.toPosition == .node {
                        #expect(later.id == parent)
                        found = true
                        break
                    }
                    lane = line.toLane
                }
                #expect(found)
            }
        }
    }
}

@MainActor
@Suite("Graph repository state")
struct GraphRepositoryTests {
    @Test("the default branch wins over a checked-out feature branch, including remote-only defaults")
    func defaultSelection() {
        let feature = Branch(refName: "refs/heads/feature", name: "feature", kind: .local,
                             objectName: "feature", isCurrentHEAD: true)
        let main = Branch(refName: "refs/heads/main", name: "main", kind: .local, objectName: "main")
        let release = Branch(refName: "refs/heads/release/stable", name: "release/stable", kind: .local,
                             objectName: "release")
        let remote = Branch(refName: "refs/remotes/origin/release/stable", name: "origin/release/stable",
                            kind: .remote, objectName: "release")
        let advertised = GitDefaultBranch(localRef: release.refName, remoteRef: remote.refName)
        #expect(GraphBranchSelection.defaultBranch(from: [feature, main], remoteDefault: nil)?.id == main.id)
        #expect(GraphBranchSelection.defaultBranch(from: [feature, main, release, remote], remoteDefault: advertised)?.id == release.id)
        #expect(GraphBranchSelection.defaultBranch(from: [feature, main, remote], remoteDefault: advertised)?.id == remote.id)
        #expect(GraphBranchSelection.defaultBranch(from: [feature], remoteDefault: nil)?.id == feature.id)
        #expect(GraphBranchSelection.defaultBranch(from: [], remoteDefault: nil) == nil)
    }

    @Test("remote HEAD selects a custom default and respects the preferred remote without a network lookup")
    func remoteDefault() async throws {
        let fixture = try await GitClientIntegrationTests.Fixture()
        defer { fixture.cleanUp() }
        try await fixture.git(["branch", "release/stable"])
        try await fixture.git(["update-ref", "refs/remotes/origin/release/stable", "HEAD"])
        try await fixture.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/release/stable"])
        try await fixture.git(["update-ref", "refs/remotes/upstream/main", "HEAD"])
        try await fixture.git(["symbolic-ref", "refs/remotes/upstream/HEAD", "refs/remotes/upstream/main"])
        try await fixture.git(["checkout", "-qb", "feature/working"])
        let origin = try #require(try await fixture.client.defaultBranch(repository: fixture.repository))
        #expect(origin.localRef == "refs/heads/release/stable")
        let upstream = try #require(try await fixture.client.defaultBranch(repository: fixture.repository,
                                                                         preferredRemote: "upstream"))
        #expect(upstream.localRef == "refs/heads/main")
        let (defaults, name) = PreferencesServiceTests.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = PreferencesService(defaults: defaults)
        preferences.autoFetchOnActivation = false
        let service = RepositoryService(preferences: preferences)
        await service.open(directory: fixture.repository)
        #expect(service.defaultBranch?.refName == "refs/heads/release/stable")
        #expect(service.selectedWorktree?.branchName == "feature/working")
        service.closeRepository()
        #expect(service.defaultBranch == nil)
    }

    @Test("branch choices persist per repository, including an explicitly empty choice")
    func savedSelections() {
        let (defaults, name) = PreferencesServiceTests.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let repo = PreferencesServiceTests.repository()
        let other = PreferencesServiceTests.repository(at: "/tmp/other")
        let prefs = PreferencesService(defaults: defaults)
        #expect(prefs.selectedGraphBranches(for: repo) == nil)
        prefs.setSelectedGraphBranches(["refs/heads/main", "refs/remotes/origin/topic"], for: repo)
        let reopened = PreferencesService(defaults: defaults)
        #expect(reopened.selectedGraphBranches(for: repo) == ["refs/heads/main", "refs/remotes/origin/topic"])
        #expect(reopened.selectedGraphBranches(for: other) == nil)
        reopened.setSelectedGraphBranches([], for: repo)
        #expect(PreferencesService(defaults: defaults).selectedGraphBranches(for: repo) == [])
    }

    @Test("graph and commit inspection work without a selected worktree")
    func repositoryInspection() async throws {
        let fixture = try await GitClientIntegrationTests.Fixture()
        defer { fixture.cleanUp() }
        let (defaults, name) = PreferencesServiceTests.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = PreferencesService(defaults: defaults)
        preferences.autoFetchOnActivation = false
        let service = RepositoryService(preferences: preferences)
        await service.open(directory: fixture.repository)
        defer { service.closeRepository() }
        service.selectedWorktreePath = nil
        let graph = try await service.graph(branches: service.branches)
        let commit = try #require(graph.commits.first)
        let detail = try await service.commitDetail(hash: commit.id)
        #expect(detail.hash == commit.id)
        #expect(!detail.files.isEmpty)
        let diff = try await service.commitDiff(hash: commit.id, path: "README.md")
        #expect(diff.contains("+hello"))
    }
}
