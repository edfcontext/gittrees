import Foundation

/// A disk-backed patch. Releasing the preview removes the temporary copy.
public final class StashDiffPreview: Sendable {
    public struct Page: Sendable {
        public let text: String
        public let nextOffset: UInt64?
    }

    private static let byteLimit = 64 * 1_024
    private static let lineLimit = 1_500
    private let directory: URL
    let patchURL: URL

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitTrees-stash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        self.directory = directory
        patchURL = directory.appendingPathComponent("stash.patch")
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    public func page(startingAt offset: UInt64 = 0) async throws -> Page {
        try Task.checkCancellation()
        let file = try FileHandle(forReadingFrom: patchURL)
        defer { try? file.close() }
        try file.seek(toOffset: offset)
        let data = try file.read(upToCount: Self.byteLimit + 1) ?? Data()

        var end = min(data.count, Self.byteLimit)
        if data.count > end {
            // A single line can exceed the byte budget. Keep whole UTF-8 scalars
            // even when that line has to continue on the next page.
            while end > 0, data[end] & 0xC0 == 0x80 { end -= 1 }
            if end == 0 { end = Self.byteLimit }
        }

        var lines = 0
        var lastLineEnd = 0
        for (index, byte) in data.prefix(end).enumerated() where byte == 0x0A {
            lastLineEnd = index + 1
            lines += 1
            if lines == Self.lineLimit { break }
        }
        if lastLineEnd > 0, lines == Self.lineLimit || data.count > end {
            end = lastLineEnd
        }

        try Task.checkCancellation()
        return Page(
            text: String(decoding: data.prefix(end), as: UTF8.self),
            nextOffset: end < data.count ? offset + UInt64(end) : nil
        )
    }
}
