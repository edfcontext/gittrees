import Foundation

public struct PullRequestCheck: Decodable, Hashable, Sendable {
    public let name: String
    public let workflow: String
    public let state: String
    public let bucket: String
    public let event: String?
    public let description: String?
    public let link: String?

    public var hasFailed: Bool { bucket == "fail" }
    public var isPending: Bool { bucket == "pending" }

    public var detailsURL: URL? {
        guard let link, let url = URL(string: link), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    public func hasJobLogs(for request: PullRequest) -> Bool {
        actionsJob(for: request) != nil
    }

    func actionsJob(for request: PullRequest) -> GitHubActionsJob? {
        guard let link, let repository = GitHubRepositoryURL(link),
              repository.host.caseInsensitiveCompare(URL(string: request.url)?.host ?? "") == .orderedSame
        else { return nil }
        let path = repository.path
        let runID: Substring
        let jobID: Substring
        if path.count == 5, path[0] == "actions", path[1] == "runs", path[3] == "job" {
            runID = path[2]
            jobID = path[4]
        } else if path.count == 4, path[0] == "runs", path[2] == "jobs" {
            runID = path[1]
            jobID = path[3]
        } else {
            return nil
        }
        guard let run = UInt64(runID), run > 0, let job = UInt64(jobID), job > 0 else { return nil }
        return GitHubActionsJob(repository: repository, id: job)
    }
}

public struct PullRequestCheckDetails: Sendable {
    public let failedSteps: [String]
    public let annotations: [PullRequestCheckAnnotation]
}

public struct PullRequestCheckAnnotation: Decodable, Sendable {
    public let title: String?
    public let message: String
    public let path: String
    public let startLine: Int
    let level: String

    private enum CodingKeys: String, CodingKey {
        case title, message, path
        case startLine = "start_line"
        case level = "annotation_level"
    }
}

struct GitHubActionsJob: Sendable {
    let repository: GitHubRepositoryURL
    let id: UInt64

    var apiPath: String { "repos/\(repository.name)/actions/jobs/\(id)" }
}

struct GitHubRepositoryURL: Sendable {
    let host: String
    let name: String
    let path: [Substring]

    init?(_ link: String) {
        guard let url = URL(string: link), url.scheme == "https", let host = url.host,
              url.user == nil, url.password == nil, url.port == nil else { return nil }
        let parts = url.path.split(separator: "/")
        let slugCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard parts.count >= 2, parts.prefix(2).allSatisfy({ part in
            part != "." && part != ".." && part.unicodeScalars.allSatisfy(slugCharacters.contains)
        }) else { return nil }
        self.host = host
        name = "\(parts[0])/\(parts[1])"
        path = Array(parts.dropFirst(2))
    }
}
