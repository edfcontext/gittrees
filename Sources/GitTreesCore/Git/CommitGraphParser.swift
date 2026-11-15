import Foundation

enum CommitGraphParser {
    // Field order matches GitClient.graphFormat. Both fields and records use NUL.
    static func parse(_ data: Data, branches: [Branch], knownBranches: [Branch] = [],
                      shallowBoundaryHashes: Set<String> = []) throws -> [GraphCommit] {
        var fields = data.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        if fields.last == "" { fields.removeLast() }
        guard fields.count.isMultiple(of: 6) else {
            throw GitError.unexpectedOutput(reason: "incomplete graph commit record", arguments: ["log"])
        }
        // Git's %aI uses the ISO 8601 internet date/time format. FormatStyle parses
        // it directly without the per-record ICU work in ISO8601DateFormatter.
        let dateStyle = Date.ISO8601FormatStyle()
        let tips = Dictionary(grouping: branches, by: \.objectName)
        let knownTips = Dictionary(grouping: knownBranches + branches, by: \.objectName)
        return try stride(from: 0, to: fields.count, by: 6).map { index in
            let hash = fields[index]
            guard !hash.isEmpty, let date = try? dateStyle.parse(fields[index + 3]) else {
                throw GitError.unexpectedOutput(reason: "invalid graph commit metadata", arguments: ["log"])
            }
            let names = (tips[hash] ?? []).map(\.name).sorted()
            let parents = fields[index + 4].split(separator: " ").map(String.init)
            let subject = fields[index + 5]
            let sourceNames = MergeSourceParser.names(subject: subject, sourceCount: parents.count - 1)
            var mergedNames: [String: [String]] = [:]
            for (index, parent) in parents.dropFirst().enumerated() {
                if let sourceNames {
                    mergedNames[parent] = [sourceNames[index]]
                } else {
                    mergedNames[parent] = Array(Set((knownTips[parent] ?? []).map(\.name))).sorted()
                }
            }
            return GraphCommit(
                summary: CommitSummary(hash: hash, abbreviatedHash: fields[index + 1],
                                       subject: subject, authorName: fields[index + 2],
                                       authorDate: date, refNames: names.joined(separator: ", ")),
                parentHashes: parents,
                branchNames: names,
                mergedParentNames: mergedNames,
                isShallowBoundary: shallowBoundaryHashes.contains(hash)
            )
        }
    }
}
