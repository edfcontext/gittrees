import Foundation

public struct GraphCommit: Identifiable, Hashable, Sendable {
    public var summary: CommitSummary
    public var parentHashes: [String]
    /// Git suppresses parent hashes at these commits in a shallow checkout.
    public var isShallowBoundary: Bool
    /// Only selected branch tips are decorated, even if other refs share this commit.
    public var branchNames: [String]
    /// Names recorded for the non-first parents of a merge, keyed by parent hash.
    /// These identify merged paths without decorating unselected branch tips.
    public var mergedParentNames: [String: [String]]
    public var id: String { summary.hash }
    public var isMerge: Bool { parentHashes.count > 1 }

    public init(summary: CommitSummary, parentHashes: [String], branchNames: [String] = [],
                mergedParentNames: [String: [String]] = [:], isShallowBoundary: Bool = false) {
        self.summary = summary
        self.parentHashes = parentHashes
        self.isShallowBoundary = isShallowBoundary
        self.branchNames = branchNames
        self.mergedParentNames = mergedParentNames
    }
}

public struct CommitGraph: Sendable {
    public var commits: [GraphCommit]
    public var hasMore: Bool
    public var hasShallowBoundary: Bool { commits.contains(where: \.isShallowBoundary) }

    public init(commits: [GraphCommit] = [], hasMore: Bool = false) {
        self.commits = commits
        self.hasMore = hasMore
    }
}

/// A row's lines meet precisely at its top and bottom boundaries. Keeping layout out
/// of SwiftUI lets lazy rows draw continuous paths without measuring neighboring views.
public struct GraphLine: Hashable, Sendable {
    public enum Position: Double, Hashable, Sendable { case top = 0, node = 0.5, bottom = 1 }
    public var fromLane: Int
    public var fromPosition: Position
    public var toLane: Int
    public var toPosition: Position
    public var color: Int
}

public struct GraphRow: Identifiable, Sendable {
    public var commit: GraphCommit
    public var lane: Int
    public var color: Int
    public var lines: [GraphLine]
    public var id: String { commit.id }
}

public struct GraphLegendEntry: Identifiable, Hashable, Sendable {
    public var color: Int
    /// Selected branch tips, or source names recovered from merges on this path.
    public var branchNames: [String]
    public var mergeCommitHashes: [String]
    public var id: Int { color }

    public var label: String {
        if !branchNames.isEmpty { return branchNames.joined(separator: ", ") }
        if let merge = mergeCommitHashes.first { return "Merge \(merge)" }
        return "Shared history"
    }
}

public struct CommitGraphLayout: Sendable {
    public var rows: [GraphRow]
    public var laneCount: Int
    public var legend: [GraphLegendEntry]
    /// Parent paths still open at the history limit. Shallow boundaries are marked
    /// separately because Git omits their parent hashes entirely.
    public var continuingLaneCount: Int

    /// Layout can touch thousands of commits and paths. Keep it off the interface
    /// actor, and propagate cancellation when the branch selection is superseded.
    public static func prepare(commits: [GraphCommit]) async throws -> CommitGraphLayout {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let layout = CommitGraphLayout(commits: commits)
            try Task.checkCancellation()
            return layout
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    public init(commits: [GraphCommit]) {
        struct Lane {
            var hash: String
            var color: Int
        }
        var lanes: [Lane] = []
        var nextColor = 0
        var rows: [GraphRow] = []
        var mergeNamesByColor: [Int: Set<String>] = [:]
        var mergesByColor: [Int: Set<String>] = [:]
        var width = 1
        for commit in commits {
            let before = lanes
            let lane: Int
            let color: Int
            if let existing = lanes.firstIndex(where: { $0.hash == commit.id }) {
                lane = existing
                color = lanes[existing].color
                lanes.remove(at: existing)
            } else {
                lane = lanes.count
                color = nextColor
                nextColor += 1
            }

            var insertion = min(lane, lanes.count)
            for (index, parent) in commit.parentHashes.enumerated() {
                guard !lanes.contains(where: { $0.hash == parent }) else { continue }
                let parentColor: Int
                if index == 0 {
                    parentColor = color
                } else {
                    parentColor = nextColor
                    nextColor += 1
                }
                lanes.insert(Lane(hash: parent, color: parentColor), at: insertion)
                insertion += 1
            }

            // Index the frontier once. Looking up every crossing lane by scanning
            // the entire frontier made wide merge histories quadratic per row.
            let positions = Dictionary(uniqueKeysWithValues: lanes.enumerated().map { ($0.element.hash, $0.offset) })
            for parent in commit.parentHashes.dropFirst() {
                if let target = positions[parent] {
                    let pathColor = lanes[target].color
                    mergeNamesByColor[pathColor, default: []].formUnion(commit.mergedParentNames[parent] ?? [])
                    mergesByColor[pathColor, default: []].insert(commit.summary.abbreviatedHash)
                }
            }
            var lines: [GraphLine] = []
            for (index, prior) in before.enumerated() {
                if prior.hash == commit.id {
                    lines.append(GraphLine(fromLane: index, fromPosition: .top,
                                           toLane: lane, toPosition: .node, color: color))
                } else if let target = positions[prior.hash] {
                    lines.append(GraphLine(fromLane: index, fromPosition: .top,
                                           toLane: target, toPosition: .bottom, color: prior.color))
                }
            }
            for parent in commit.parentHashes {
                if let target = positions[parent] {
                    lines.append(GraphLine(fromLane: lane, fromPosition: .node,
                                           toLane: target, toPosition: .bottom, color: lanes[target].color))
                }
            }
            width = max(width, before.count, lanes.count, lane + 1)
            rows.append(GraphRow(commit: commit, lane: lane, color: color, lines: lines))
        }
        self.rows = rows
        self.laneCount = width
        self.continuingLaneCount = lanes.count

        var namesByColor: [Int: [String]] = [:]
        var usedColors: Set<Int> = []
        for row in rows {
            usedColors.insert(row.color)
            usedColors.formUnion(row.lines.map(\.color))
            namesByColor[row.color, default: []].append(contentsOf: row.commit.branchNames)
        }
        self.legend = usedColors.sorted().map {
            let selectedNames = Set(namesByColor[$0] ?? [])
            let names = selectedNames.isEmpty ? (mergeNamesByColor[$0] ?? []) : selectedNames
            return GraphLegendEntry(color: $0, branchNames: names.sorted(),
                                    mergeCommitHashes: (mergesByColor[$0] ?? []).sorted())
        }
    }
}
