import Foundation

// Loose Decodable mirrors of the GraphQL objects GHT asks for. Every field is optional because one struct
// covers several __typename variants (an IssueOrPullRequest, or any timeline item).

nonisolated struct GQLNodes<T: Decodable & Sendable>: Decodable, Sendable {
    var nodes: [T?]?
    var totalCount: Int?
    /// Timeline connections: the count after the itemTypes filter (totalCount ignores it).
    var filteredCount: Int?
    var items: [T] { (nodes ?? []).compactMap { $0 } }
}

nonisolated struct GQLCount: Decodable, Hashable, Sendable { var totalCount: Int }

nonisolated struct GQLActor: Decodable, Hashable, Sendable {
    var __typename: String?
    var login: String?
    var avatarUrl: String?
    var url: String?
    var name: String?
    var display: String { login ?? name ?? "ghost" }
    var isBot: Bool { __typename == "Bot" || (login ?? "").hasSuffix("[bot]") }
}

nonisolated struct GQLLabel: Decodable, Hashable, Sendable, Identifiable {
    var id: String?
    var name: String
    var color: String
    var description: String?
    var stableID: String { id ?? name }
}

nonisolated struct GQLRepoRef: Decodable, Hashable, Sendable { var nameWithOwner: String }

nonisolated struct GQLRef: Decodable, Hashable, Sendable {
    var __typename: String
    var number: Int?
    var title: String?
    var url: String?
    var issueState: String?
    var prState: String?
    var abbreviatedOid: String?
    var repository: GQLRepoRef?
}

nonisolated struct GQLReactionGroup: Decodable, Hashable, Sendable {
    var content: String
    var viewerHasReacted: Bool
    var reactors: GQLCount

    var emoji: String {
        switch content {
        case "THUMBS_UP": "👍"
        case "THUMBS_DOWN": "👎"
        case "LAUGH": "😄"
        case "HOORAY": "🎉"
        case "CONFUSED": "😕"
        case "HEART": "❤️"
        case "ROCKET": "🚀"
        case "EYES": "👀"
        default: "?"
        }
    }
}

nonisolated struct GQLReviewComment: Decodable, Sendable {
    var id: String
    var path: String?
    var line: Int?
    var diffHunk: String?
    var bodyHTML: String
    var createdAt: Date
    var url: String?
    var author: GQLActor?
}

nonisolated struct GQLCheckRollup: Decodable, Sendable { var state: String }
nonisolated struct GQLCommitNode: Decodable, Sendable {
    struct Commit: Decodable, Sendable { var statusCheckRollup: GQLCheckRollup? }
    var commit: Commit
}

nonisolated struct GQLDiscussionReply: Decodable, Sendable {
    var id: String
    var author: GQLActor?
    var authorAssociation: String?
    var createdAt: Date
    var bodyHTML: String
    var url: String?
    var isAnswer: Bool?
    var reactionGroups: [GQLReactionGroup]?
    var replies: GQLNodes<GQLDiscussionReplyLeaf>?
}

nonisolated struct GQLDiscussionReplyLeaf: Decodable, Sendable {
    var id: String
    var author: GQLActor?
    var authorAssociation: String?
    var createdAt: Date
    var bodyHTML: String
    var url: String?
    var reactionGroups: [GQLReactionGroup]?
}

nonisolated struct GQLCategory: Decodable, Sendable { var name: String; var emojiHTML: String? }

/// An Issue, PullRequest or Discussion (enrichment and detail both decode into this).
nonisolated struct GQLSubject: Decodable, Sendable {
    var __typename: String
    var id: String?
    var number: Int?
    var title: String?
    var url: String?
    var state: String?
    var stateReason: String?
    var isDraft: Bool?
    var closed: Bool?
    var isAnswered: Bool?
    var locked: Bool?
    var createdAt: Date?
    var updatedAt: Date?
    var author: GQLActor?
    var authorAssociation: String?
    var bodyHTML: String?
    var comments: GQLNodes<GQLDiscussionReply>?
    var labels: GQLNodes<GQLLabel>?
    var assignees: GQLNodes<GQLActor>?
    var milestone: Milestone?
    var reviewDecision: String?
    var viewerCanUpdate: Bool?
    var viewerCanClose: Bool?
    var viewerCanReopen: Bool?
    var viewerSubscription: String?
    var viewerCanReact: Bool?
    var reactionGroups: [GQLReactionGroup]?
    var timelineItems: GQLNodes<GQLTimelineNode>?
    // Pull requests
    var headRefName: String?
    var baseRefName: String?
    var additions: Int?
    var deletions: Int?
    var changedFiles: Int?
    var mergeable: String?
    var mergedAt: Date?
    var viewerCanMergeAsAdmin: Bool?
    var commits: GQLNodes<GQLCommitNode>?
    var reviewRequests: GQLNodes<ReviewRequest>?
    // Discussions
    var category: GQLCategory?
    var answer: Answer?

    struct Milestone: Decodable, Sendable { var title: String }
    struct Answer: Decodable, Sendable { var id: String }
    struct ReviewRequest: Decodable, Sendable { var requestedReviewer: GQLActor? }
}

/// One item of an issue or PR timeline.
nonisolated struct GQLTimelineNode: Decodable, Sendable {
    var __typename: String
    var id: String?
    var databaseId: Int?
    var author: GQLActor?
    var actor: GQLActor?
    var authorAssociation: String?
    var createdAt: Date?
    var bodyHTML: String?
    var url: String?
    var reviewState: String?
    var stateReason: String?
    var label: GQLLabel?
    var assignee: GQLActor?
    var requestedReviewer: GQLActor?
    var source: GQLRef?
    var closer: GQLRef?
    var previousTitle: String?
    var currentTitle: String?
    var commit: GQLRef?
    var mergeRefName: String?
    var isMinimized: Bool?
    var minimizedReason: String?
    var viewerCanUpdate: Bool?
    var reactionGroups: [GQLReactionGroup]?
    var comments: GQLNodes<GQLReviewComment>?
    var milestoneTitle: String?
    var isCrossRepository: Bool?
    var willCloseTarget: Bool?
}

nonisolated struct GQLResponse<T: Decodable & Sendable>: Decodable, Sendable {
    var data: T?
    var errors: [GQLError]?
}

nonisolated struct GQLError: Decodable, Sendable, Error, LocalizedError {
    var message: String
    var type: String?
    var errorDescription: String? { message }
}
