import AppKit
import GitTreesCore
import SwiftUI

/// Repository-scoped: choosing a branch here never checks it out.
struct GraphView: View {
    @Environment(RepositoryService.self) private var service
    @Environment(PreferencesService.self) private var preferences
    let repository: Repository
    let onCreateWorktreeAtCommit: (CommitSummary) -> Void
    let onCreateReferenceAtCommit: (CreateCommitReferenceSheet.Kind, CommitSummary) -> Void

    @State private var search = ""
    @State private var graph = CommitGraph()
    @State private var layout = CommitGraphLayout(commits: [])
    @State private var selectedCommitID: String?
    @State private var isLoading = false
    @State private var error: String?
    @State private var limit = 500
    @State private var loadedBranches: [Branch]?

    private struct Request: Equatable {
        var repositoryID: String
        var branches: [Branch]
        var limit: Int
        var revision: Int
    }

    private var selectedRefs: Set<String> {
        if let saved = preferences.selectedGraphBranches(for: repository) { return saved }
        let initial = service.defaultBranch
        return Set(initial.map { [$0.refName] } ?? [])
    }

    private var request: Request {
        // Resolve preferences once per pass, rather than rebuilding the selected set
        // (and originally scanning all branches for a default) for every branch.
        let refs = selectedRefs
        return Request(repositoryID: repository.id,
                branches: service.branches.filter { refs.contains($0.refName) }.map {
                    // Checkout and tracking changes do not change this graph's scope.
                    Branch(refName: $0.refName, name: $0.name, kind: $0.kind, objectName: $0.objectName)
                },
                limit: limit, revision: service.graphRevision)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Graph", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)
                Text(repository.name).foregroundStyle(.secondary)
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
                Button("Refresh") { service.refresh() }
            }
            .padding(12)
            Divider()
            HSplitView {
                branchPicker.frame(minWidth: 210, idealWidth: 245, maxWidth: 340)
                graphContent.frame(minWidth: 420)
            }
        }
        .background(GitTreesUI.barBackground)
        .task(id: request) { await loadGraph(request) }
    }

    private var branchPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Branches (\(request.branches.count))").font(.headline)
                Spacer()
                Button("Default") {
                    if let branch = service.defaultBranch { setSelection([branch.refName]) }
                }
                .disabled(service.defaultBranch == nil)
                .help("Select the repository's default branch")
                Button("Clear") { setSelection([]) }
                    .disabled(selectedRefs.isEmpty)
            }
            .padding(10)
            TextField("Find a branch", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            List {
                branchSection("Local", branches: service.localBranches)
                branchSection("Remotes", branches: service.remoteBranches)
            }
            .listStyle(.inset)
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Text("Selected branches include shared ancestors and merged commits.")
                Text("Remote history reflects the last fetch.")
                let missing = selectedRefs.subtracting(service.branches.map(\.refName))
                if !missing.isEmpty {
                    Text("\(missing.count) saved branch selection(s) are no longer available.")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(10)
        }
    }

    @ViewBuilder
    private func branchSection(_ title: String, branches: [Branch]) -> some View {
        let matches = branches.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        let refs = selectedRefs
        if !matches.isEmpty {
            Section(title) {
                ForEach(matches) { branch in
                    Toggle(isOn: Binding(
                        get: { refs.contains(branch.refName) },
                        set: { enabled in
                            var refs = selectedRefs
                            if enabled { refs.insert(branch.refName) } else { refs.remove(branch.refName) }
                            setSelection(refs)
                        }
                    )) {
                        Text(branch.name).lineLimit(1).truncationMode(.middle)
                    }
                    .toggleStyle(.checkbox)
                    .help(branch.refName)
                }
            }
        }
    }

    @ViewBuilder
    private var graphContent: some View {
        if request.branches.isEmpty {
            ContentUnavailableView("Select Branches", systemImage: "arrow.branch",
                                   description: Text("Choose local or remote branches to see their branch and merge history."))
        } else if let error {
            ContentUnavailableView {
                Label("Could Not Load Graph", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Retry") { service.refresh() }
            }
        } else if isLoading && graph.commits.isEmpty {
            ProgressView("Loading history…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if graph.commits.isEmpty {
            ContentUnavailableView("No Commits", systemImage: "clock",
                                   description: Text("The selected branches have no commit history."))
        } else {
            VSplitView {
                VStack(spacing: 0) {
                    colorLegend
                    Divider()
                    ScrollView([.horizontal, .vertical]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(layout.rows) { row in
                                graphRow(row)
                            }
                        }
                    }
                    Divider()
                    HStack {
                        Text("\(graph.commits.count) commits · \(request.branches.count) branches")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if graph.hasShallowBoundary {
                            Text("Shallow history: earlier parents are unavailable in this checkout.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if graph.hasMore {
                            Text("Older history continues below.").font(.caption).foregroundStyle(.secondary)
                            Button("Load More") { limit = min(limit + 500, 10_000) }
                                .disabled(isLoading || limit >= 10_000)
                        } else if !graph.hasShallowBoundary && layout.continuingLaneCount > 0 {
                            Text("Earlier parents are unavailable in this checkout.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                }
                .frame(minHeight: 150, idealHeight: 320)

                GraphCommitInspector(hash: selectedCommitID)
                    .frame(minHeight: 180)
            }
        }
    }

    private var colorLegend: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Text("Color legend").font(.caption.weight(.semibold))
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 14) {
                        ForEach(layout.legend) { entry in
                            let label = entry.label
                            HStack(spacing: 5) {
                                Circle().fill(GraphPalette.color(entry.color))
                                    .frame(width: 8, height: 8)
                                Text(label).font(.caption).lineLimit(1)
                            }
                            .help(entry.branchNames.isEmpty
                                  ? "\(label): the original branch name is unavailable."
                                  : "\(label)\nNames from selected branches, merge messages or matching branch refs.")
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                .frame(height: 18)
            }
            Text("Colors follow history paths. Merged branch names come from merge messages or matching branch refs; shared paths share a color.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func graphRow(_ row: GraphRow) -> some View {
        let commit = row.commit.summary
        return Button { selectedCommitID = row.id } label: {
            HStack(spacing: 10) {
                GraphPaths(row: row)
                    .frame(width: CGFloat(layout.laneCount) * GraphPaths.laneSpacing + 16, height: 34)
                    .accessibilityHidden(true)
                HStack(spacing: 5) {
                    ForEach(Array(row.commit.branchNames.prefix(2).enumerated()), id: \.offset) { _, name in
                        BadgeLabel(text: name, tint: GraphPalette.color(row.color))
                            .lineLimit(1).truncationMode(.middle).frame(maxWidth: 120)
                            .help(name)
                    }
                    if row.commit.branchNames.count > 2 {
                        Text("+\(row.commit.branchNames.count - 2)")
                            .font(.caption2).foregroundStyle(.secondary)
                            .help(row.commit.branchNames.joined(separator: ", "))
                    }
                    if row.commit.isMerge {
                        Image(systemName: "arrow.triangle.merge").foregroundStyle(.secondary)
                            .help("Merge commit · \(row.commit.parentHashes.count) parents")
                    }
                    Text(commit.subject).lineLimit(1).layoutPriority(1)
                    Spacer(minLength: 0)
                }
                .frame(width: 420, alignment: .leading)
                Text(commit.abbreviatedHash).font(GitTreesUI.monospaced)
                    .frame(width: 85, alignment: .leading)
                Text(commit.authorName).lineLimit(1).frame(width: 120, alignment: .leading)
                Text(commit.authorDate, format: .dateTime.year().month().day())
                    .frame(width: 110, alignment: .leading)
            }
            .font(.callout)
            .padding(.trailing, 12)
            .contentShape(Rectangle())
            .background(selectedCommitID == row.id ? Color.accentColor.opacity(0.16) : Color.clear)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(row.commit.isShallowBoundary ? "Shallow history boundary: " : row.commit.isMerge ? "Merge: " : "")\(commit.subject), \(commit.abbreviatedHash)")
        .help("\(commit.subject)\n\(commit.hash)\(row.commit.isShallowBoundary ? "\nShallow history boundary: earlier parents are unavailable in this checkout." : "")")
        .contextMenu {
            Button("Create Branch from This Commit…") { onCreateReferenceAtCommit(.branch, commit) }
                .disabled(service.activeOperation != nil)
            Button("Create Tag from This Commit…") { onCreateReferenceAtCommit(.tag, commit) }
                .disabled(service.activeOperation != nil)
            Button("Create Worktree at Commit…") { onCreateWorktreeAtCommit(commit) }
                .disabled(service.activeOperation != nil)
            Divider()
            Button("Copy Hash") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.hash, forType: .string)
            }
        }
    }

    private func setSelection(_ refs: Set<String>) {
        preferences.setSelectedGraphBranches(refs, for: repository)
        limit = 500
    }

    private func loadGraph(_ request: Request) async {
        // Retain rows during pagination and refresh, but clear them when branch scope
        // changes. An older query must never paint over a newer selection.
        if loadedBranches != request.branches {
            graph = CommitGraph()
            layout = CommitGraphLayout(commits: [])
            selectedCommitID = nil
        }
        loadedBranches = request.branches
        if preferences.selectedGraphBranches(for: repository) == nil, !request.branches.isEmpty {
            preferences.setSelectedGraphBranches(Set(request.branches.map(\.refName)), for: repository)
        }
        error = nil
        isLoading = true
        do {
            let loaded = try await service.graph(branches: request.branches, limit: request.limit)
            let prepared = try await CommitGraphLayout.prepare(commits: loaded.commits)
            guard !Task.isCancelled, self.request == request else { return }
            graph = loaded
            layout = prepared
            if !loaded.commits.contains(where: { $0.id == selectedCommitID }) { selectedCommitID = nil }
            isLoading = false
        } catch {
            guard !Task.isCancelled, self.request == request else { return }
            selectedCommitID = nil
            self.error = error.localizedDescription
            isLoading = false
        }
    }
}

/// Shared by graph paths, branch badges and the legend. Additional paths get new
/// hues instead of cycling through the same eight colors under different names.
private enum GraphPalette {
    private static let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .red, .indigo]

    static func color(_ index: Int) -> Color {
        if index < colors.count { return colors[index] }
        let hue = (Double(index) * 0.61803398875).truncatingRemainder(dividingBy: 1)
        return Color(hue: hue, saturation: 0.65, brightness: 0.8)
    }
}

private struct GraphPaths: View {
    static let laneSpacing: CGFloat = 18
    let row: GraphRow

    var body: some View {
        Canvas { context, size in
            for line in row.lines {
                let start = CGPoint(x: x(line.fromLane), y: size.height * line.fromPosition.rawValue)
                let end = CGPoint(x: x(line.toLane), y: size.height * line.toPosition.rawValue)
                var path = Path()
                path.move(to: start)
                let middle = (start.y + end.y) / 2
                path.addCurve(to: end, control1: CGPoint(x: start.x, y: middle),
                              control2: CGPoint(x: end.x, y: middle))
                context.stroke(path, with: .color(GraphPalette.color(line.color)), lineWidth: 2)
            }
            let radius: CGFloat = row.commit.isMerge ? 5 : 4
            let rect = CGRect(x: x(row.lane) - radius, y: size.height / 2 - radius,
                              width: radius * 2, height: radius * 2)
            // A square marks truncated ancestry instead of drawing a normal root.
            let circle = row.commit.isShallowBoundary ? Path(rect) : Path(ellipseIn: rect)
            context.fill(circle, with: .color(GraphPalette.color(row.color)))
            if row.commit.isMerge {
                context.fill(Path(ellipseIn: rect.insetBy(dx: 2, dy: 2)), with: .color(.primary))
            }
        }
    }

    private func x(_ lane: Int) -> CGFloat { 16 + CGFloat(lane) * Self.laneSpacing }
}

/// Uses the same commit/file/diff inspector as History, with repository-scoped reads.
private struct GraphCommitInspector: View {
    @Environment(RepositoryService.self) private var service
    let hash: String?
    @State private var detail: CommitDetail?
    @State private var selectedFileID: CommitFileChange.ID?
    @State private var diff = ""
    @State private var loadingDetail = false
    @State private var loadingDiff = false
    @State private var detailError: String?
    @State private var diffError: String?

    private struct DiffRequest: Equatable {
        var hash: String?
        var detailHash: String?
        var file: CommitFileChange?
    }

    private var diffRequest: DiffRequest {
        DiffRequest(hash: hash, detailHash: detail?.hash,
                    file: detail?.files.first { $0.id == selectedFileID })
    }

    var body: some View {
        CommitInspector(detail: detail, selectedFileID: $selectedFileID, diffText: diff,
                        isLoadingDetail: loadingDetail, isLoadingDiff: loadingDiff,
                        detailError: detailError, diffError: diffError)
            .task(id: hash) { await loadDetail() }
            .task(id: diffRequest) { await loadDiff(diffRequest) }
    }

    private func loadDetail() async {
        detail = nil
        selectedFileID = nil
        detailError = nil
        diff = ""
        loadingDetail = hash != nil
        guard let hash else { return }
        do {
            let loaded = try await service.commitDetail(hash: hash)
            guard !Task.isCancelled else { return }
            detail = loaded
            selectedFileID = loaded.files.first?.id
        } catch {
            guard !Task.isCancelled else { return }
            detailError = error.localizedDescription
        }
        loadingDetail = false
    }

    private func loadDiff(_ request: DiffRequest) async {
        diff = ""
        diffError = nil
        loadingDiff = false
        guard let hash = request.hash, request.detailHash == hash, let file = request.file else { return }
        loadingDiff = true
        do {
            let loaded = try await service.commitDiff(hash: hash, path: file.path)
            guard !Task.isCancelled else { return }
            diff = loaded
        } catch {
            guard !Task.isCancelled else { return }
            diffError = error.localizedDescription
        }
        loadingDiff = false
    }
}
