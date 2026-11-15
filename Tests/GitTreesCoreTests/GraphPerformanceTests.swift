import Foundation
import Testing
@testable import GitTreesCore

/// Opt-in release benchmark; timings are observations, not machine-dependent test gates.
/// GITTREES_BENCHMARK_GRAPH=1 swift test -c release --filter GraphPerformanceTests
@Suite("Graph performance", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["GITTREES_BENCHMARK_GRAPH"] == "1"))
struct GraphPerformanceTests {
    @Test("measure the real graph-loading path and its parser/layout stages")
    func graphPipeline() async throws {
        let fixture = try await GitClientIntegrationTests.Fixture()
        defer { fixture.cleanUp() }
        let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        try await benchmark("GitTrees", repository: checkout, client: fixture.client, limit: 500)
        for (name, width, length) in [("linear-10000", 1, 9_998), ("wide-9902", 100, 99)] {
            let directory = fixture.worktreeRoot(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await fixture.git(["init", "--quiet", "--initial-branch=main"], in: directory)
            try importHistory(width: width, length: length, into: directory, root: fixture.root)
            try await benchmark(name, repository: directory, client: fixture.client, limit: 10_000)
        }
    }

    private func benchmark(_ name: String, repository: URL, client: GitClient, limit: Int) async throws {
        let branches = try await client.branches(repository: repository)
        let metadata = try await GitProcessRunner().run(GitCommand(
            ["log", "--topo-order", "--no-decorate", "--no-show-signature", "--no-notes",
             "--max-count=\(limit + 1)", "-z", "--format=\(GitClient.graphFormat)", "--end-of-options"]
                + Set(branches.map(\.objectName)).sorted() + ["--"], workingDirectory: repository
        )).stdout
        var loadTimes: [Double] = []
        var parseTimes: [Double] = []
        var layoutTimes: [Double] = []
        var fingerprint: UInt64 = 0
        var rowCount = 0
        for sample in 0..<6 {
            let start = DispatchTime.now().uptimeNanoseconds
            let graph = try await client.graph(repository: repository, branches: branches, limit: limit,
                                               knownBranches: branches)
            let loaded = DispatchTime.now().uptimeNanoseconds
            let layout = try await CommitGraphLayout.prepare(commits: graph.commits)
            let laidOut = DispatchTime.now().uptimeNanoseconds
            let parsed = try CommitGraphParser.parse(metadata, branches: branches, knownBranches: branches)
            let finished = DispatchTime.now().uptimeNanoseconds
            #expect(Array(parsed.prefix(limit)) == graph.commits)
            #expect(layout.rows.count == graph.commits.count)
            if sample > 0 { // Exclude the first warm-up run.
                loadTimes.append(Double(loaded - start) / 1_000_000)
                layoutTimes.append(Double(laidOut - loaded) / 1_000_000)
                parseTimes.append(Double(finished - laidOut) / 1_000_000)
            }
            rowCount = layout.rows.count
            fingerprint = checksum(layout)
        }
        func median(_ values: [Double]) -> String { String(format: "%.2f", values.sorted()[values.count / 2]) }
        print("GRAPH BENCHMARK \(name): rows=\(rowCount) load=\(median(loadTimes))ms parse=\(median(parseTimes))ms layout=\(median(layoutTimes))ms checksum=\(fingerprint)")
    }

    private func importHistory(width: Int, length: Int, into repository: URL, root: URL) throws {
        var stream = ""
        var mark = 0
        func commit(ref: String, parent: Int?, merges: [Int] = []) {
            mark += 1
            let message = "benchmark commit \(mark)"
            stream += "commit refs/heads/\(ref)\nmark :\(mark)\ncommitter Benchmark <benchmark@example.invalid> \(1_700_000_000 + mark) +0000\ndata \(message.utf8.count)\n\(message)\n"
            if let parent { stream += "from :\(parent)\n" }
            for merge in merges { stream += "merge :\(merge)\n" }
            stream += "\n"
        }
        commit(ref: "main", parent: nil)
        var tips: [Int] = []
        for branch in 0..<width {
            var parent = 1
            for _ in 0..<length {
                commit(ref: "topic-\(branch)", parent: parent)
                parent = mark
            }
            tips.append(parent)
        }
        commit(ref: "main", parent: 1, merges: tips)
        let input = root.appendingPathComponent("history-import")
        try stream.write(to: input, atomically: true, encoding: .utf8)
        let handle = try FileHandle(forReadingFrom: input)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: GitProcessRunner.defaultExecutablePath)
        process.arguments = ["fast-import", "--quiet"]
        process.currentDirectoryURL = repository
        process.standardInput = handle
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func checksum(_ layout: CommitGraphLayout) -> UInt64 {
        var value: UInt64 = 14_695_981_039_346_656_037
        func add(_ text: String) {
            for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 1_099_511_628_211 }
        }
        for row in layout.rows {
            add("\(row.id):\(row.lane):\(row.color):\(row.commit.isShallowBoundary);")
            for line in row.lines {
                add("\(line.fromLane):\(line.fromPosition.rawValue):\(line.toLane):\(line.toPosition.rawValue):\(line.color);")
            }
        }
        for entry in layout.legend { add("\(entry.color):\(entry.label);") }
        return value
    }
}
