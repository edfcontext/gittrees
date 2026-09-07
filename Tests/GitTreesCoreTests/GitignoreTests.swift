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

    @Test("a folder can be ignored by name instead of by position")
    func directoryByName() {
        // The `node_modules/` shape: unanchored, so it catches the folder at any depth.
        #expect(Gitignore.pattern(forDirectoryNamed: "node_modules") == "node_modules/")
        #expect(Gitignore.pattern(forDirectoryNamed: "app/vendor/node_modules") == "node_modules/")
    }

    @Test("a name or extension pattern is unanchored so it matches at any depth")
    func nameAndExtensionPatterns() {
        #expect(Gitignore.pattern(forNameOf: "src/app/client.ts") == "client.ts")
        #expect(Gitignore.pattern(forExtensionOf: "src/app/client.ts") == "*.ts")
        #expect(Gitignore.pattern(forExtensionOf: "logs/run.tar.gz") == "*.gz")
        // A dotfile is a name, not an extension, so there is nothing to key on.
        #expect(Gitignore.pattern(forExtensionOf: ".env") == nil)
        #expect(Gitignore.pattern(forExtensionOf: "Makefile") == nil)
    }

    @Test("the folders offered for a path run from the innermost outwards")
    func ancestorFolders() {
        #expect(
            Gitignore.ancestorFolders(of: "src/generated/api/client.ts")
                == ["src/generated/api", "src/generated", "src"]
        )
        // A file at the top level has no folder to offer.
        #expect(Gitignore.ancestorFolders(of: "README.md").isEmpty)
        #expect(Gitignore.ancestorFolders(of: "/build/out/deep.o") == ["build/out", "build"])
    }

    @Test("a leading # or ! is escaped, since an unanchored pattern starts the line")
    func leadingSyntaxIsEscaped() {
        #expect(Gitignore.pattern(forNameOf: "#draft.md") == "\\#draft.md")
        #expect(Gitignore.pattern(forDirectoryNamed: "!temp") == "\\!temp/")
        // Anchored patterns start with a slash, so neither character is ever in front.
        #expect(Gitignore.pattern(forPath: "#draft.md") == "/#draft.md")
    }

    @Test("each destination resolves to the file Git actually reads")
    func destinationFiles() {
        let worktree = URL(fileURLWithPath: "/repos/app/feature")
        let commonGitDir = URL(fileURLWithPath: "/repos/app/.git")

        #expect(
            Gitignore.fileURL(for: .repository, worktree: worktree, commonGitDir: commonGitDir).path
                == "/repos/app/feature/.gitignore"
        )
        // Git reads `info/exclude` from the shared git directory — never from the linked
        // worktree's own one — so a local rule is repository-wide by nature.
        #expect(
            Gitignore.fileURL(for: .local, worktree: worktree, commonGitDir: commonGitDir).path
                == "/repos/app/.git/info/exclude"
        )
    }

    @Test("a rule is recognised as present only on a line of its own")
    func containsMatchesWholeLines() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gittrees-ignore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("exclude")
        // A file that is not there yet holds nothing, rather than being an error.
        #expect(Gitignore.contains(pattern: ".worktrees/", in: file) == false)

        try "# a comment\n  .worktrees/  \nbuild/out/\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(Gitignore.contains(pattern: ".worktrees/", in: file))
        // A longer line that merely contains the text is a different rule.
        #expect(Gitignore.contains(pattern: "out/", in: file) == false)
        #expect(Gitignore.contains(pattern: "", in: file) == false)
    }

    @Test("appending creates the directory an exclude file needs")
    func appendCreatesMissingDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gittrees-ignore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A repository that has never had a local exclude has no `info` directory.
        let exclude = root.appendingPathComponent("info/exclude")
        #expect(try Gitignore.append(pattern: "/build/", to: exclude))
        #expect(try String(contentsOf: exclude, encoding: .utf8) == "/build/\n")
        #expect(try Gitignore.append(pattern: "/build/", to: exclude) == false)
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
