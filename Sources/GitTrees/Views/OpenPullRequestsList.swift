import Foundation
import GitTreesCore
import SwiftUI

struct OpenPullRequestsList: View {
    @Environment(RepositoryService.self) private var service
    @State private var requests: [PullRequest] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var limit = 100
    @State private var refreshCount = 0

    let selectedURL: String?
    let revision: Int
    let selectRequest: (PullRequest) -> Void
    let updateRequests: ([PullRequest]) -> Void

    private struct Query: Equatable {
        let repository: Repository?
        let auth: GitHubAuth
        let limit: Int
        let refreshCount: Int
        let revision: Int
    }

    var body: some View {
        let query = Query(
            repository: service.repository, auth: service.gitHubAuth,
            limit: limit, refreshCount: refreshCount, revision: revision
        )
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Open Pull Requests")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.small)
                }
                Button {
                    refreshCount += 1
                } label: {
                    Label("Refresh Open Pull Requests", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .help("Refresh open pull requests")
                .disabled(isLoading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            if requests.isEmpty {
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                List(requests, id: \.url, selection: selection) { request in
                    requestRow(request)
                }
                .listStyle(.inset)

                if requests.count >= limit {
                    Button("Load More") { limit += 100 }
                        .disabled(isLoading)
                        .padding(8)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .task(id: query) { await load(query) }
    }

    private var emptyMessage: String {
        if isLoading { return "Loading open pull requests…" }
        return errorMessage == nil ? "No open pull requests." : "Use Refresh to try again."
    }

    private var selection: Binding<String?> {
        Binding(
            get: { selectedURL },
            set: { url in
                guard url != selectedURL,
                      let request = requests.first(where: { $0.url == url }) else { return }
                selectRequest(request)
            }
        )
    }

    private func requestRow(_ request: PullRequest) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(request.title)
                .lineLimit(2)
            HStack(spacing: 6) {
                Text("#\(request.number)")
                    .monospacedDigit()
                if let author = request.author?.login, !author.isEmpty {
                    Text(author).lineLimit(1)
                }
                if request.isDraft {
                    Text("Draft")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    private func load(_ query: Query) async {
        isLoading = true
        errorMessage = nil
        defer {
            if !Task.isCancelled { isLoading = false }
        }
        do {
            let loaded = try await service.openPullRequests(limit: query.limit)
            guard !Task.isCancelled else { return }
            requests = loaded
            updateRequests(loaded)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = PresentableError(title: "Could Not Load Open Pull Requests", error: error).summary
        }
    }
}
