import Foundation

/// A readable explanation and recovery steps, with the original diagnostics retained.
public struct PresentableError: Identifiable, Sendable {
    public let id = UUID()
    public var title: String
    /// The original message, including authored stash-recovery notices.
    public var message: String
    public var detail: String?
    public var recoverySteps: [String]
    private var commandSummary: String?

    public var summary: String { commandSummary ?? message }

    public init(title: String, message: String, detail: String? = nil, recoverySteps: [String]? = nil) {
        self.title = title
        self.message = message
        self.detail = detail
        self.recoverySteps = recoverySteps ?? Self.defaultRecoverySteps
    }

    public init(title: String, error: Error) {
        self.title = title
        if let failure = (error as? CommandExecutionError)?.failure {
            message = failure.message
            // Keep both streams even when stderr is the primary message.
            detail = [
                failure.commandLine,
                "exit code: \(failure.exitCode)",
                failure.workingDirectory.map { "directory: \($0)" },
                failure.stdout.isEmpty ? nil : "stdout:\n\(failure.stdout)",
                failure.stderr.isEmpty ? nil : "stderr:\n\(failure.stderr)"
            ].compactMap { $0 }.joined(separator: "\n\n")
            let guidance = ErrorRecovery.guidance(for: failure)
            commandSummary = guidance?.summary
                ?? "\(failure.program) could not complete this operation. Review the technical details below."
            recoverySteps = guidance?.steps ?? Self.defaultRecoverySteps
        } else {
            message = error.localizedDescription
            detail = (error as? LocalizedError)?.failureReason
            if let suggestion = (error as? LocalizedError)?.recoverySuggestion,
               !suggestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                recoverySteps = [suggestion]
            } else {
                recoverySteps = ErrorRecovery.steps(for: error) ?? Self.defaultRecoverySteps
            }
        }
    }

    /// Full output for recovery notices and copying. Command details already contain
    /// the original message in stdout/stderr, so do not repeat potentially huge output.
    public var diagnosticText: String {
        if commandSummary != nil, let detail { return detail }
        return [message, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    public var hasTechnicalDetails: Bool { commandSummary != nil || !(detail ?? "").isEmpty }

    public var recoveryText: String {
        recoverySteps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n\n")
    }

    /// The same explanation, guidance and complete diagnostics shown in the alert.
    public var reportText: String {
        var sections = [title, "What happened\n\(summary)", "How to resolve\n\(recoveryText)"]
        if hasTechnicalDetails { sections.append("Technical details\n\(diagnosticText)") }
        return sections.joined(separator: "\n\n")
    }

    private static let defaultRecoverySteps = [
        "Review the technical details for the failing command or file. If this followed a Git operation, refresh the worktree and check Changes and History to see what completed before trying again.",
        "If the cause is unclear or the problem persists, use Copy Details and share the report with someone who can help."
    ]
}
