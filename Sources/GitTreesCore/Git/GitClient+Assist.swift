import Foundation

extension GitClient {
    /// Uses object IDs for graph queries so an auto-fetch cannot mix two graph states.
    public func assessBranches(worktree: URL, otherRef: String) async throws -> BranchAssessment {
        guard otherRef.hasPrefix("refs/heads/") || otherRef.hasPrefix("refs/remotes/") else {
            throw GitAssistError.unsupported("Choose a local or remote-tracking branch.")
        }
        let currentRef = try await run(["symbolic-ref", "--quiet", "HEAD"], in: worktree).trimmedStdout
        let head = try await run(["rev-parse", "--verify", "HEAD^{commit}"], in: worktree).trimmedStdout
        let other = try await run(["rev-parse", "--verify", "\(otherRef)^{commit}"], in: worktree).trimmedStdout
        let common = try await run(["merge-base", head, other], in: worktree, acceptableExitCodes: [0, 1])
        let counts = try await run(["rev-list", "--left-right", "--count", "\(head)...\(other)"], in: worktree)
            .trimmedStdout.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard counts.count == 2 else { throw GitAssistError.stale }
        let status = try await statusSummary(worktree: worktree)
        let operation = try await inProgressOperation(worktree: worktree)
        let relationship: BranchAssessment.Relationship
        if common.exitCode == 1 { relationship = .unrelated }
        else if head == other { relationship = .identical }
        else if counts[0] == 0 { relationship = .fastForward }
        else if counts[1] == 0 { relationship = .ahead }
        else { relationship = .diverged }
        return BranchAssessment(worktree: worktree, currentRef: currentRef, otherRef: otherRef,
                                currentHead: head, otherHead: other, ahead: counts[0], behind: counts[1],
                                relationship: relationship, clean: status.isClean, operation: operation)
    }

    /// Reject a stale preview and let Git enforce fast-forward-only at execution time.
    public func fastForward(_ assessment: BranchAssessment) async throws -> String {
        let fresh = try await assessBranches(worktree: assessment.worktree, otherRef: assessment.otherRef)
        guard fresh == assessment else { throw GitAssistError.stale }
        guard fresh.canFastForward else {
            throw GitAssistError.unsupported(fresh.blocker ?? "These branches cannot be fast-forwarded.")
        }
        let result = try await run(["merge", "--ff-only", "--no-autostash", fresh.otherHead], in: fresh.worktree)
        return result.stdoutText + result.stderrText
    }

    /// Read-only evidence. Unsupported file kinds and oversized inputs never reach the model.
    public func conflictSnapshot(worktree: URL, path: String) async throws -> ConflictSnapshot {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        let lockNames = ["package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml",
                         "package.resolved", "cargo.lock", "poetry.lock", "uv.lock", "gemfile.lock", "composer.lock"]
        guard !lockNames.contains(name), !name.hasSuffix(".lock"),
              !name.contains(".min."), !name.hasSuffix(".map") else {
            throw GitAssistError.unsupported("Resolve generated files and lockfiles with their owning tool.")
        }
        let file = try assistFile(worktree: worktree, path: path)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 12_000 else {
            throw GitAssistError.unsupported("Suggestions support small regular text files only.")
        }
        let head = try await run(["rev-parse", "--verify", "HEAD"], in: worktree).trimmedStdout
        let branch = try await run(["symbolic-ref", "--quiet", "HEAD"], in: worktree, acceptableExitCodes: [0, 1]).trimmedStdout
        let operation = try await inProgressOperation(worktree: worktree)
        let status = try await statusSummary(worktree: worktree)
        guard status.conflicts.contains(where: { $0.path == path && $0.rawXY == "UU" && !$0.isSubmodule }) else {
            throw GitAssistError.unsupported("Suggestions currently support text files modified on both sides. Resolve deletions, renames and additions manually.")
        }
        let entries = try await run(["ls-files", "--unmerged", "-z", "--", ":(literal)\(path)"], in: worktree).stdout
        var blobs: [Int: String] = [:]
        var modes = Set<String>()
        for record in String(decoding: entries, as: UTF8.self).split(separator: "\0") {
            let fields = record.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2, fields[1] == path else { throw GitAssistError.stale }
            let info = fields[0].split(separator: " ")
            guard info.count == 3, ["100644", "100755"].contains(String(info[0])), let stage = Int(info[2]) else {
                throw GitAssistError.unsupported("Suggestions do not support symlinks, submodules or file type conflicts.")
            }
            modes.insert(String(info[0]))
            let oid = String(info[1])
            let length = try await run(["cat-file", "-s", oid], in: worktree).trimmedStdout
            guard let count = Int(length), count <= 12_000 else {
                throw GitAssistError.unsupported("This conflict is too large for an on-device suggestion. Use manual resolution.")
            }
            let data = try await run(["cat-file", "blob", oid], in: worktree).stdout
            blobs[stage] = try assistText(data)
        }
        guard modes.count == 1, blobs.count == 3, let base = blobs[1], let ours = blobs[2], let theirs = blobs[3] else {
            throw GitAssistError.unsupported("A common ancestor and both text versions with matching file modes are required.")
        }
        let working = try assistText(Data(contentsOf: file))
        guard [base, ours, theirs, working].reduce(0, { $0 + $1.utf8.count }) <= 10_000 else {
            throw GitAssistError.unsupported("This conflict needs more context than the on-device suggestion supports. Use manual resolution.")
        }
        return ConflictSnapshot(worktree: worktree, path: path, head: head, branchRef: branch,
                                operation: operation, indexEntries: entries, base: base, ours: ours, theirs: theirs,
                                workingText: working, document: try ConflictDocument(working),
                                permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644)
    }

    public func conflictProposal(snapshot: ConflictSnapshot, replacements: [ConflictReplacement], explanation: String) async throws -> ConflictProposal {
        let resolved = try snapshot.document.applying(replacements)
        // A whole-side copy is a common small-model failure. When both sides changed,
        // leave that choice to the existing explicit Use Mine / Use Theirs actions.
        if snapshot.ours != snapshot.base, snapshot.theirs != snapshot.base,
           snapshot.ours != snapshot.theirs, snapshot.document.copiesOneSide(replacements) {
            throw GitAssistError.unsupported("The suggestion kept only one side’s version. Review the conflict manually or use Use Mine / Use Theirs explicitly.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = directory.appendingPathComponent("current")
        let after = directory.appendingPathComponent("suggested")
        try Data(snapshot.workingText.utf8).write(to: before)
        try Data(resolved.utf8).write(to: after)
        let raw = try await run(["diff", "--no-index", "--no-ext-diff", "--no-textconv", "--", before.path, after.path],
                                in: directory, acceptableExitCodes: [0, 1]).stdoutText
        let hunks = raw.range(of: "@@").map { String(raw[$0.lowerBound...]) } ?? ""
        return ConflictProposal(snapshot: snapshot, replacements: replacements, explanation: explanation,
                                resolvedText: resolved, diff: "--- Current: \(snapshot.path)\n+++ Suggested: \(snapshot.path)\n" + hunks)
    }

    /// Only an explicit Apply & Stage reaches this method. No commit or rebase continuation.
    public func applyConflictProposal(_ proposal: ConflictProposal) async throws {
        let snapshot = proposal.snapshot
        let fresh = try await conflictSnapshot(worktree: snapshot.worktree, path: snapshot.path)
        guard fresh == snapshot else { throw GitAssistError.stale }
        let resolved = try fresh.document.applying(proposal.replacements)
        guard resolved == proposal.resolvedText else { throw GitAssistError.invalidSuggestion }
        let file = try assistFile(worktree: snapshot.worktree, path: snapshot.path)
        // Check again immediately before writing; an editor may have saved during Git reads.
        guard try Data(contentsOf: file) == Data(snapshot.workingText.utf8) else { throw GitAssistError.stale }
        try Data(resolved.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: snapshot.permissions], ofItemAtPath: file.path)
        do {
            _ = try await run(["add", "--", ":(literal)\(snapshot.path)"], in: snapshot.worktree)
        } catch {
            throw GitAssistError.unsupported("The suggested text was written, but staging failed. Your edited file is still on disk. Review Changes and stage it manually. \(error.localizedDescription)")
        }
    }

    private func assistFile(worktree: URL, path: String) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"),
              !path.split(separator: "/").contains(where: { $0 == ".." || $0 == ".git" }) else {
            throw GitAssistError.unsupported("The conflict path is not a regular worktree file.")
        }
        let root = worktree.resolvingSymlinksInPath().standardizedFileURL
        let file = root.appendingPathComponent(path).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), file.resolvingSymlinksInPath().path == file.path else {
            throw GitAssistError.unsupported("Suggestions do not support symbolic links in file paths.")
        }
        return file
    }

    private func assistText(_ data: Data) throws -> String {
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw GitAssistError.unsupported("Suggestions support UTF-8 text only. Resolve binary files manually.")
        }
        return text
    }
}
