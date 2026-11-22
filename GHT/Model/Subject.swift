import Foundation

/// What the inbox row shows about an issue / PR / discussion beyond the notification itself.
nonisolated enum SubjectState: String, Codable, Sendable {
    case open, closed, notPlanned, duplicate, merged, draft, answered, unknown

    var label: String {
        switch self {
        case .open: "Open"
        case .closed: "Closed"
        case .notPlanned: "Not planned"
        case .duplicate: "Duplicate"
        case .merged: "Merged"
        case .draft: "Draft"
        case .answered: "Answered"
        case .unknown: ""
        }
    }

    /// Done-worthy without reading: nothing more will happen unless someone reopens it.
    var isFinished: Bool { self == .closed || self == .notPlanned || self == .duplicate || self == .merged }

    static func from(_ s: GQLSubject) -> SubjectState {
        switch s.__typename {
        case "PullRequest":
            if s.state == "MERGED" { return .merged }
            if s.state == "CLOSED" { return .closed }
            return s.isDraft == true ? .draft : .open
        case "Issue":
            guard s.state == "CLOSED" else { return .open }
            switch s.stateReason {
            case "NOT_PLANNED": return .notPlanned
            case "DUPLICATE": return .duplicate
            default: return .closed
            }
        case "Discussion":
            if s.isAnswered == true { return .answered }
            return s.closed == true ? .closed : .open
        default:
            return .unknown
        }
    }
}

nonisolated struct SubjectInfo: Sendable {
    var state: SubjectState
    var author: GQLActor?
    var commentCount: Int
    var labels: [GQLLabel]
    var htmlURL: String?
    var reviewDecision: String?

    init(_ s: GQLSubject) {
        state = SubjectState.from(s)
        author = s.author
        commentCount = s.comments?.totalCount ?? 0
        labels = s.labels?.items ?? []
        htmlURL = s.url
        reviewDecision = s.reviewDecision
    }

    init(release: GHRelease) {
        state = .unknown
        author = GQLActor(login: release.author?.login, avatarUrl: release.author?.avatarUrl)
        commentCount = 0
        labels = []
        htmlURL = release.htmlUrl
    }
}

nonisolated struct GHRelease: Decodable, Sendable {
    var name: String?
    var tagName: String
    var htmlUrl: String
    var bodyHtml: String?
    var prerelease: Bool
    var draft: Bool
    var publishedAt: Date?
    var author: GHNotification.Owner?

    enum CodingKeys: String, CodingKey {
        case name, prerelease, draft, author
        case tagName = "tag_name"
        case htmlUrl = "html_url"
        case bodyHtml = "body_html"
        case publishedAt = "published_at"
    }
}

/// Everything the detail pane shows for one thread.
nonisolated enum ThreadDetail: Sendable {
    case conversation(GQLSubject)  // Issue, PullRequest or Discussion
    case release(GHRelease)
    case unsupported

    var subject: GQLSubject? {
        if case .conversation(let s) = self { return s }
        return nil
    }
}
