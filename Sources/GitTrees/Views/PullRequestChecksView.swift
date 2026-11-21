import GitTreesCore
import SwiftUI

struct PullRequestChecksView: View {
    @Environment(RepositoryService.self) private var service
    @State private var checks: [PullRequestCheck]?
    @State private var selection: Int?
    @State private var failure: String?
    @State private var refresh = 0

    let request: PullRequest

    private struct Query: Equatable {
        let head: String?
        let refresh: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let checks {
                if checks.isEmpty {
                    CheckPaneMessage(text: "GitHub has reported no checks for this PR.", icon: "checkmark.circle")
                } else {
                    results(checks)
                }
            } else if let failure {
                CheckPaneMessage(text: failure, icon: "exclamationmark.triangle")
            } else {
                ProgressView("Loading checks…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(GitTreesUI.editorBackground)
        .task(id: Query(head: request.headRefOid, refresh: refresh)) { await loadChecks() }
    }

    private var header: some View {
        HStack {
            Text("Checks")
                .font(.caption.weight(.semibold))
            if let checks, !checks.isEmpty {
                let failures = checks.filter(\.hasFailed).count
                Text("\(failures) failed · \(checks.count) total")
                    .font(.caption)
                    .foregroundStyle(failures == 0 ? Color.secondary : .red)
            }
            Spacer()
            Button {
                refresh += 1
            } label: {
                Label("Refresh Checks", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .help("Refresh checks")
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(GitTreesUI.barBackground)
    }

    private func results(_ checks: [PullRequestCheck]) -> some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(checks.indices, id: \.self) { index in
                    let check = checks[index]
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: statusIcon(check))
                            .foregroundStyle(statusColor(check))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(check.name).lineLimit(2)
                            Text(checkSubtitle(check))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(index)
                }
            }
            .listStyle(.inset)
            .frame(width: 220)
            Divider()
            if let selection, checks.indices.contains(selection) {
                PullRequestCheckDetailView(check: checks[selection], request: request)
                    .id(checks[selection])
            } else {
                CheckPaneMessage(text: "Select a check to see its details.", icon: "checkmark.circle")
            }
        }
    }

    private func statusLabel(_ check: PullRequestCheck) -> String {
        switch check.state {
        case "SUCCESS": "Passed"
        case "FAILURE": "Failed"
        default: check.state.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func checkSubtitle(_ check: PullRequestCheck) -> String {
        let event = check.event?.replacingOccurrences(of: "_", with: " ").capitalized ?? ""
        return [check.workflow, event, statusLabel(check)].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func statusIcon(_ check: PullRequestCheck) -> String {
        switch check.bucket {
        case "pass": "checkmark.circle.fill"
        case "fail": "xmark.circle.fill"
        case "pending": "clock"
        default: "minus.circle"
        }
    }

    private func statusColor(_ check: PullRequestCheck) -> Color {
        switch check.bucket {
        case "pass": .green
        case "fail": .red
        case "pending": .orange
        default: .secondary
        }
    }

    private func loadChecks() async {
        let previous = checks.flatMap { values in
            selection.flatMap { values.indices.contains($0) ? values[$0] : nil }
        }
        checks = nil
        failure = nil
        do {
            let loaded = try await service.pullRequestChecks(request)
            guard !Task.isCancelled else { return }
            let sorted = loaded.filter(\.hasFailed) + loaded.filter { !$0.hasFailed }
            selection = sorted.firstIndex { check in
                guard let previous else { return false }
                return check.link == previous.link && check.name == previous.name && check.workflow == previous.workflow
            } ?? sorted.indices.first
            checks = sorted
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            failure = PresentableError(title: "Could Not Load Checks", error: error).summary
        }
    }
}

private struct PullRequestCheckDetailView: View {
    @Environment(RepositoryService.self) private var service
    @State private var mode: Mode = .summary
    @State private var details: PullRequestCheckDetails?
    @State private var detailsError: String?
    @State private var logs: [Mode: String] = [:]
    @State private var logErrors: [Mode: String] = [:]
    @State private var logRetry = 0

    let check: PullRequestCheck
    let request: PullRequest

    private enum Mode {
        case summary, failedLog, fullLog
    }

    private struct LogQuery: Equatable {
        let mode: Mode
        let retry: Int
    }

    private var hasInAppLog: Bool {
        check.hasJobLogs(for: request)
    }

    var body: some View {
        let query = LogQuery(mode: mode, retry: logRetry)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(check.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if hasInAppLog && !check.isPending {
                    Picker("Check details", selection: $mode) {
                        Text("Summary").tag(Mode.summary)
                        if check.hasFailed {
                            Text("Failed-step Log").tag(Mode.failedLog)
                        }
                        Text("Full Log").tag(Mode.fullLog)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .controlSize(.small)
                }
            }
            .padding(8)
            Divider()
            if mode == .summary {
                summary
            } else {
                log(mode)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await loadDetails() }
        .task(id: query) { await loadLog(query.mode) }
    }

    private var summary: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let description = check.description, !description.isEmpty {
                    Text(description)
                }
                if hasInAppLog {
                    if check.isPending {
                        Text("Logs are available when the job finishes.")
                            .foregroundStyle(.secondary)
                    } else if check.hasFailed {
                        failureSummary
                    } else {
                        Text("Select Full Log to view the job output.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("See the check provider for logs.")
                        .foregroundStyle(.secondary)
                    if let url = check.detailsURL {
                        Link("Open Check Details", destination: url)
                    }
                }
            }
            .font(.callout)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(12)
        }
    }

    @ViewBuilder
    private var failureSummary: some View {
        if let details {
            if !details.failedSteps.isEmpty {
                Text("Failed Steps").fontWeight(.semibold)
                ForEach(details.failedSteps.indices, id: \.self) { index in
                    Label(details.failedSteps[index], systemImage: "xmark.circle")
                }
            }
            if !details.annotations.isEmpty {
                Text("Failure Annotations").fontWeight(.semibold)
                ForEach(details.annotations.indices, id: \.self) { index in
                    let annotation = details.annotations[index]
                    VStack(alignment: .leading, spacing: 4) {
                        if let title = annotation.title, !title.isEmpty {
                            Text(title).fontWeight(.medium)
                        }
                        Text(annotation.message)
                        if !annotation.path.isEmpty {
                            Text("\(annotation.path):\(annotation.startLine)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if details.failedSteps.isEmpty && details.annotations.isEmpty {
                Text("Select Failed-step Log or Full Log to inspect the failure.")
                    .foregroundStyle(.secondary)
            }
        } else if let detailsError {
            Text(detailsError).foregroundStyle(.secondary)
        } else {
            ProgressView("Loading failed steps…").controlSize(.small)
        }
    }

    @ViewBuilder
    private func log(_ mode: Mode) -> some View {
        if let log = logs[mode], !log.isEmpty {
            MonospacedTextView(text: log)
        } else if logs[mode] != nil {
            CheckPaneMessage(text: "GitHub returned no log for this view.", icon: "doc.text")
        } else if let message = logErrors[mode] {
            VStack(spacing: 8) {
                Text(message).textSelection(.enabled)
                if let url = check.detailsURL {
                    Link("Open Check Details", destination: url)
                }
                Button("Retry") { logRetry += 1 }
            }
            .font(.callout)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView("Loading job log…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadDetails() async {
        guard check.hasFailed, hasInAppLog else { return }
        do {
            let loaded = try await service.pullRequestCheckDetails(check, request: request)
            guard !Task.isCancelled else { return }
            details = loaded
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            detailsError = PresentableError(title: "Could Not Load Failed Steps", error: error).summary
        }
    }

    private func loadLog(_ mode: Mode) async {
        guard mode != .summary, logs[mode] == nil else { return }
        logErrors[mode] = nil
        do {
            let loaded = try await service.pullRequestCheckLog(check, request: request, failedOnly: mode == .failedLog)
            guard !Task.isCancelled else { return }
            logs[mode] = loaded
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            logErrors[mode] = PresentableError(title: "Could Not Load Job Log", error: error).summary
        }
    }
}

private struct CheckPaneMessage: View {
    let text: String
    let icon: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
