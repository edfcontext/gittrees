import Foundation
import Testing
@testable import GitTreesCore

@Suite("Gitignore")
struct GitignoreTests {

    @Test("a path is anchored at the repository root")
    func pathIsAnchored() {
        #expect(Gitignore.pattern(forPath: "scratch.txt") == "/scratch.txt")
        #expect(Gitignore.pattern(forPath: "docs/new note.md") == "/docs/new note.md")
        #expect(Gitignore.pattern(forPath: "/docs/new note.md") == "/docs/new note.md")
    }

    @Test("glob metacharacters are escaped so the filename is literal")
    func globCharactersAreEscaped() {
        #expect(Gitignore.pattern(forPath: "file[1].txt") == "/file\\[1].txt")
        #expect(Gitignore.pattern(forPath: "star*.log") == "/star\\*.log")
        #expect(Gitignore.pattern(forPath: "why?.md") == "/why\\?.md")
    }

    @Test("a directory pattern has a trailing slash")
    func directoryHasTrailingSlash() {
        #expect(Gitignore.pattern(forDirectory: "docs") == "/docs/")
        #expect(Gitignore.pattern(forDirectory: "docs/") == "/docs/")
        #expect(Gitignore.pattern(forDirectory: "build/out") == "/build/out/")
    }

    @Test("append creates .gitignore and skips a duplicate pattern")
    func appendCreatesAndDeduplicates() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gittrees-ignore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pattern = Gitignore.pattern(forPath: "scratch.txt")
        #expect(try Gitignore.append(pattern: pattern, inWorktree: root))
        #expect(try Gitignore.append(pattern: pattern, inWorktree: root) == false)

        let contents = try String(
            contentsOf: root.appendingPathComponent(".gitignore"),
            encoding: .utf8
        )
        #expect(contents == "/scratch.txt\n")
    }

    @Test("append restores a missing trailing newline before adding a line")
    func appendRestoresTrailingNewline() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gittrees-ignore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "existing".write(
            to: root.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        #expect(try Gitignore.append(pattern: "/scratch.txt", inWorktree: root))

        let contents = try String(
            contentsOf: root.appendingPathComponent(".gitignore"),
            encoding: .utf8
        )
        #expect(contents == "existing\n/scratch.txt\n")
    }
}
