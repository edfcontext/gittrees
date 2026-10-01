public struct CommitSuggestion: Sendable, Hashable, Equatable {
    public enum Source: String, Sendable, Hashable {
        case appleIntelligence
        case heuristic
    }

    public var message: String
    public var source: Source
    /// One-line explanation of why this message was chosen, for the commit footer.
    public var diagnostic: String

    public init(message: String, source: Source, diagnostic: String = "") {
        self.message = message
        self.source = source
        self.diagnostic = diagnostic
    }
}
