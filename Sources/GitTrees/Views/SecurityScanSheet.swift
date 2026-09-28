import AppKit
import GitTreesCore
import SwiftUI

struct SecurityScanSheet: View {
    let worktree: Worktree
    @Environment(PreferencesService.self) private var preferences
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @State private var scanTask: Task<Void, Never>?
    @State private var isScanning = false
    @State private var isCancelling = false
    @State private var report: SecurityScanReport?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Security Scan").font(.title2.bold())
            Text(worktree.displayName).font(.headline)
            Text(worktree.path.path).font(.caption.monospaced()).textSelection(.enabled)
            Text("Semgrep scans local files with GitTrees’ bundled baseline rules. No fixes are applied. This is a limited code check, not a dependency audit or a guarantee of security.")
                .font(.callout)
            Text("Swift, Python, JavaScript/TypeScript, Java, private-key and plist checks. Ignored files, common build/dependency folders and files over 1 MB may be skipped. Swift support is experimental in Semgrep CE.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if isScanning {
                        HStack { ProgressView().controlSize(.small); Text(isCancelling ? "Cancelling…" : "Scanning local files…") }
                    }
                    if let failure {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).textSelection(.enabled)
                    }
                    if let report {
                        Text(report.isComplete ? "Scan finished" : "Scan incomplete")
                            .font(.headline)
                        Text("Findings: \(report.findings.count) · Files scanned: \(report.scannedFileCount) · \(report.finishedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(report.issues.enumerated()), id: \.offset) { _, issue in
                            Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                        if report.findings.isEmpty && report.isComplete {
                            Text("No findings in the files scanned by this baseline. Other security issues may still exist.")
                        }
                        ForEach(report.findings) { finding in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(finding.severity).font(.caption.bold()).foregroundStyle(.orange)
                                    Text("\(finding.path):\(finding.line)").font(.callout.monospaced())
                                    Spacer()
                                    Button("Reveal") { reveal(finding) }
                                        .help("Reveal this file in Finder; finding is on line \(finding.line)")
                                }
                                Text(finding.message).font(.callout)
                                Text(finding.rule).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                        }
                    } else if !isScanning && failure == nil {
                        Text("Ready to scan the selected worktree, including uncommitted files. Results describe a snapshot; scan again after editing.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            Divider()
            HStack {
                Button("Scanner Settings…") { openSettings() }
                Spacer()
                if isScanning {
                    Button("Cancel Scan") { isCancelling = true; scanTask?.cancel() }
                        .disabled(isCancelling)
                }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(report == nil ? "Scan" : "Scan Again", action: scan)
                    .keyboardShortcut(.defaultAction).disabled(isScanning)
            }
        }
        .padding(24).frame(width: 720, height: 570)
        .onDisappear { scanTask?.cancel() }
    }

    private func scan() {
        report = nil
        failure = nil
        isScanning = true
        isCancelling = false
        let scanner = SecurityScanner(executablePath: preferences.semgrepExecutablePath)
        scanTask = Task {
            defer { isScanning = false; isCancelling = false }
            do {
                let result = try await scanner.scan(worktree: worktree.path)
                try Task.checkCancellation()
                report = result
            } catch is CancellationError {
                failure = "Scan cancelled. No completed report is available."
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func reveal(_ finding: SecurityFinding) {
        guard let file = SecurityScanner.safeFile(finding.path, in: worktree.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }
}
