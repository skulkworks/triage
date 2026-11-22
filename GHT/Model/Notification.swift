import Foundation

/// One thread from `GET /notifications`. The REST payload, trimmed to what the inbox uses.
nonisolated struct GHNotification: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var unread: Bool
    var reason: String
    var updatedAt: Date
    var lastReadAt: Date?
    var subject: Subject
    var repository: Repository

    struct Subject: Codable, Hashable, Sendable {
        var title: String
        var url: String?
        var latestCommentUrl: String?
        var type: String
    }

    struct Repository: Codable, Hashable, Sendable {
        var fullName: String
        var name: String
        var `private`: Bool
        var htmlUrl: String
        var owner: Owner
    }

    struct Owner: Codable, Hashable, Sendable {
        var login: String
        var avatarUrl: String
    }

    enum CodingKeys: String, CodingKey {
        case id, unread, reason, subject, repository
        case updatedAt = "updated_at"
        case lastReadAt = "last_read_at"
    }
}

extension GHNotification.Subject {
    enum CodingKeys: String, CodingKey {
        case title, url, type
        case latestCommentUrl = "latest_comment_url"
    }
}

extension GHNotification.Repository {
    enum CodingKeys: String, CodingKey {
        case name, owner, `private`
        case fullName = "full_name"
        case htmlUrl = "html_url"
    }
}

extension GHNotification.Owner {
    enum CodingKeys: String, CodingKey {
        case login
        case avatarUrl = "avatar_url"
    }
}

nonisolated enum SubjectKind: String, Sendable {
    case issue = "Issue"
    case pullRequest = "PullRequest"
    case discussion = "Discussion"
    case release = "Release"
    case commit = "Commit"
    case checkSuite = "CheckSuite"
    case workflowRun = "WorkflowRun"
    case advisory = "RepositoryAdvisory"
    case vulnerability = "RepositoryVulnerabilityAlert"
    case dependabot = "RepositoryDependabotAlertsThread"
    case other

    init(_ raw: String) { self = SubjectKind(rawValue: raw) ?? .other }

    var label: String {
        switch self {
        case .issue: "Issue"
        case .pullRequest: "Pull request"
        case .discussion: "Discussion"
        case .release: "Release"
        case .commit: "Commit"
        case .checkSuite, .workflowRun: "CI"
        case .advisory: "Security advisory"
        case .vulnerability, .dependabot: "Dependabot"
        case .other: "Notification"
        }
    }

    /// Kinds whose conversation GHT can show and reply to in place.
    var hasConversation: Bool {
        switch self {
        case .issue, .pullRequest, .discussion, .release: true
        default: false
        }
    }
}

nonisolated extension GHNotification {
    var kind: SubjectKind { SubjectKind(subject.type) }

    var owner: String { repository.owner.login }
    var repoName: String { repository.name }

    /// The issue/PR/discussion number, from the subject's API URL.
    var number: Int? {
        guard let url = subject.url, kind == .issue || kind == .pullRequest || kind == .discussion,
              let last = url.split(separator: "/").last else { return nil }
        return Int(last)
    }

    /// The comment the notification points at, as `issuecomment-<id>` style anchor.
    var latestCommentAnchor: String? {
        guard let s = subject.latestCommentUrl, s != subject.url,
              s.contains("/comments/"), let id = s.split(separator: "/").last else { return nil }
        if s.contains("/pulls/comments/") { return "discussion_r\(id)" }
        return "issuecomment-\(id)"
    }

    /// The github.com page for the subject, with the notification referrer so GitHub marks it read too.
    var webURL: URL {
        let base = repository.htmlUrl
        var path: String
        switch kind {
        case .issue:
            path = number.map { "\(base)/issues/\($0)" } ?? "\(base)/issues"
        case .pullRequest:
            path = number.map { "\(base)/pull/\($0)" } ?? "\(base)/pulls"
        case .discussion:
            path = number.map { "\(base)/discussions/\($0)" } ?? "\(base)/discussions"
        case .release:
            path = "\(base)/releases"
        case .commit:
            if let sha = subject.url?.split(separator: "/").last { path = "\(base)/commit/\(sha)" } else { path = base }
        case .checkSuite, .workflowRun:
            path = "\(base)/actions"
        case .advisory:
            path = "\(base)/security/advisories"
        case .vulnerability, .dependabot:
            path = "\(base)/security/dependabot"
        case .other:
            path = base
        }
        var comps = URLComponents(string: path) ?? URLComponents()
        comps.queryItems = [URLQueryItem(name: "notification_referrer_id", value: "NT_\(id)")]
        if let anchor = latestCommentAnchor, kind == .issue || kind == .pullRequest { comps.fragment = anchor }
        return comps.url ?? URL(string: base)!
    }

    /// A stable key for enrichment caching: the thread plus its last activity.
    var revisionKey: String { "\(id)@\(updatedAt.timeIntervalSince1970)" }
}

/// Reasons GitHub gives for a notification.
nonisolated enum Reason {
    static let participating: Set<String> = [
        "author", "comment", "mention", "team_mention", "assign", "review_requested", "manual", "state_change", "approval_requested",
    ]

    static func label(_ reason: String) -> String {
        switch reason {
        case "assign": "Assigned"
        case "author": "Author"
        case "comment": "Commented"
        case "ci_activity": "CI activity"
        case "invitation": "Invited"
        case "manual": "Subscribed"
        case "mention": "Mentioned"
        case "review_requested": "Review requested"
        case "approval_requested": "Approval requested"
        case "security_alert": "Security alert"
        case "security_advisory_credit": "Advisory credit"
        case "state_change": "State change"
        case "subscribed": "Watching"
        case "team_mention": "Team mention"
        case "member_feature_requested": "Feature request"
        default: reason.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
