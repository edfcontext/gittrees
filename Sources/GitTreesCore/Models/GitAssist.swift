import Foundation

public enum GitAssistError: Error, LocalizedError, Sendable {
    case unavailable(String)
    case unsupported(String)
    case stale
    case invalidSuggestion

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): "Apple Intelligence is unavailable: \(reason)."
        case .unsupported(let reason): reason
        case .stale: "The branch, index, or file has changed. Analyze it again before applying."
        case .invalidSuggestion: "The suggestion could not be validated. Resolve this conflict manually or try again."
        }
    }
}

public struct BranchAssessment: Sendable, Equatable {
    public enum Relationship: String, Sendable {
        case identical, ahead, fastForward, diverged, unrelated
    }
    public let worktree: URL
    public let currentRef: String
    public let otherRef: String
    public let currentHead: String
    public let otherHead: String
    public let ahead: Int
    public let behind: Int
    public let relationship: Relationship
    public let clean: Bool
    public let operation: GitClient.InProgressOperation

    public var currentName: String { RefName.shortenLocal(currentRef) }
    public var otherName: String { RefName.shortenLocal(otherRef) }
    public var canFastForward: Bool { relationship == .fastForward && clean && operation == .none }
    public var summary: String {
        switch relationship {
        case .identical: "\(currentName) and \(otherName) point to the same commit. No update is needed."
        case .ahead: "\(currentName) already contains \(otherName) and has \(ahead) additional commit(s). No incoming commits to integrate."
        case .fastForward: "\(currentName) can advance to \(otherName) by \(behind) commit(s). No merge commit or rewritten commits are needed."
        case .diverged: "The branches have diverged: \(currentName) has \(ahead) unique commit(s), and \(otherName) has \(behind). Choose Merge to preserve existing commits, or Rebase to replay this branch’s commits."
        case .unrelated: "These branches have no common ancestor. Automatic integration is unavailable."
        }
    }
    public var blocker: String? {
        if operation != .none { return "Finish or abort the current merge or rebase in Changes first." }
        if !clean { return "Commit or stash local changes before using Fast-Forward or Rebase." }
        return nil
    }
}

/// Only conflict blocks are replaceable. Everything between them is copied verbatim.
public struct ConflictDocument: Sendable, Equatable {
    public struct Block: Sendable, Equatable {
        public let id: Int
        public let original: String
        let ours: String
        let theirs: String
    }
    public let blocks: [Block]
    let unchanged: [String]
    let lineEnding: String

    public init(_ text: String) throws {
        var blocks: [Block] = []
        var unchanged: [String] = []
        var plain = ""
        var block = ""
        var ours = ""
        var theirs = ""
        var phase = 0 // 0 = outside, 1 = ours, 2 = base, 3 = theirs
        // Keep line endings, including a final line without a newline.
        // Split Unicode scalars through Foundation: Swift treats CRLF as one Character.
        let lines = text.components(separatedBy: "\n")
        for (index, part) in lines.enumerated() {
            let line = String(part) + (index < lines.count - 1 ? "\n" : "")
            let marker = String(part).trimmingCharacters(in: .newlines)
            let start = marker == "<<<<<<<" || marker.hasPrefix("<<<<<<< ")
            let base = marker == "|||||||" || marker.hasPrefix("||||||| ")
            let middle = marker == "======="
            let end = marker == ">>>>>>>" || marker.hasPrefix(">>>>>>> ")
            if start {
                guard phase == 0 else { throw GitAssistError.invalidSuggestion }
                unchanged.append(plain); plain = ""; block = line; phase = 1
                ours = ""; theirs = ""
            } else if base {
                guard phase == 1 else { throw GitAssistError.invalidSuggestion }
                block += line; phase = 2
            } else if middle {
                guard phase == 1 || phase == 2 else { throw GitAssistError.invalidSuggestion }
                block += line; phase = 3
            } else if end {
                guard phase == 3 else { throw GitAssistError.invalidSuggestion }
                block += line
                blocks.append(Block(id: blocks.count, original: block, ours: ours, theirs: theirs))
                block = ""; phase = 0
            } else if phase == 0 { plain += line }
            else {
                block += line
                if phase == 1 { ours += line }
                if phase == 3 { theirs += line }
            }
        }
        guard phase == 0, !blocks.isEmpty, blocks.count <= 4 else {
            throw GitAssistError.unsupported("Suggestions support one to four standard text conflict blocks. Resolve this file manually.")
        }
        unchanged.append(plain)
        self.blocks = blocks
        self.unchanged = unchanged
        self.lineEnding = text.contains("\r\n") ? "\r\n" : "\n"
    }

    func copiesOneSide(_ replacements: [ConflictReplacement]) -> Bool {
        blocks.contains { block in
            guard let replacement = replacements.first(where: { $0.id == block.id }) else { return false }
            let text = replacement.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let ours = block.ours.trimmingCharacters(in: .whitespacesAndNewlines)
            let theirs = block.theirs.trimmingCharacters(in: .whitespacesAndNewlines)
            return ours != theirs && (text == ours || text == theirs)
        }
    }

    public func applying(_ replacements: [ConflictReplacement]) throws -> String {
        guard replacements.count == blocks.count,
              Set(replacements.map(\.id)) == Set(blocks.map(\.id)) else {
            throw GitAssistError.invalidSuggestion
        }
        var result = unchanged[0]
        for block in blocks {
            guard let replacement = replacements.first(where: { $0.id == block.id }),
                  replacement.text.utf8.count <= 8_000,
                  !replacement.text.contains("\0"), !replacement.text.contains("```"),
                  !["<<<<<<<", "=======", ">>>>>>>", "|||||||"].contains(where: replacement.text.contains) else {
                throw GitAssistError.invalidSuggestion
            }
            var text = replacement.text.replacingOccurrences(of: "\r\n", with: "\n")
            if !text.isEmpty, block.original.utf8.last == 10, text.utf8.last != 10 { text += "\n" }
            if lineEnding == "\r\n" { text = text.replacingOccurrences(of: "\n", with: "\r\n") }
            result += text + unchanged[block.id + 1]
        }
        return result
    }
}

public struct ConflictReplacement: Sendable {
    public let id: Int
    public let text: String
    public init(id: Int, text: String) { self.id = id; self.text = text }
}

public struct ConflictSnapshot: Sendable, Equatable {
    public let worktree: URL
    public let path: String
    public let head: String
    public let branchRef: String
    public let operation: GitClient.InProgressOperation
    let indexEntries: Data
    public let base: String
    public let ours: String
    public let theirs: String
    public let workingText: String
    public let document: ConflictDocument
    let permissions: Int
}

public struct ConflictProposal: Sendable {
    public let snapshot: ConflictSnapshot
    public let replacements: [ConflictReplacement]
    public let explanation: String
    public let resolvedText: String
    public let diff: String
}
