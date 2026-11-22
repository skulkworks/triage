import Foundation

/// GraphQL documents. Issue and PR fields share names (`state`, `labels`…) on purpose: GitHub merges
/// them across the union's fragments.
nonisolated enum Queries {
    static let rowFields = """
    __typename
    ... on Issue { id number url state stateReason author { __typename login avatarUrl } comments { totalCount } labels(first: 8) { nodes { name color } } }
    ... on PullRequest { id number url state isDraft reviewDecision author { __typename login avatarUrl } comments { totalCount } labels(first: 8) { nodes { name color } } }
    """

    static let discussionRowFields = """
    __typename id number url closed isAnswered author { __typename login avatarUrl } comments { totalCount } labels(first: 8) { nodes { name color } }
    """

    /// One aliased lookup per thread, so a whole page of the inbox costs a single request.
    static func batch(_ items: [(alias: String, owner: String, name: String, number: Int, discussion: Bool)]) -> String {
        var q = "query {\n"
        for i in items {
            let owner = escape(i.owner), name = escape(i.name)
            if i.discussion {
                q += "  \(i.alias): repository(owner: \"\(owner)\", name: \"\(name)\") { discussion(number: \(i.number)) { \(discussionRowFields) } }\n"
            } else {
                q += "  \(i.alias): repository(owner: \"\(owner)\", name: \"\(name)\") { issueOrPullRequest(number: \(i.number)) { \(rowFields) } }\n"
            }
        }
        return q + "}"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static let reactions = "reactionGroups { content viewerHasReacted reactors { totalCount } }"

    static let timelineFragment = """
    __typename
    ... on IssueComment { id databaseId author { __typename login avatarUrl url } authorAssociation createdAt bodyHTML url isMinimized minimizedReason viewerCanUpdate \(reactions) }
    ... on ClosedEvent { id actor { login avatarUrl } createdAt stateReason closer { __typename ... on PullRequest { number title url } ... on Commit { abbreviatedOid url } } }
    ... on ReopenedEvent { id actor { login avatarUrl } createdAt }
    ... on LabeledEvent { id actor { login avatarUrl } createdAt label { name color } }
    ... on UnlabeledEvent { id actor { login avatarUrl } createdAt label { name color } }
    ... on AssignedEvent { id actor { login avatarUrl } createdAt assignee { ... on User { login } ... on Bot { login } } }
    ... on UnassignedEvent { id actor { login avatarUrl } createdAt assignee { ... on User { login } ... on Bot { login } } }
    ... on RenamedTitleEvent { id actor { login avatarUrl } createdAt previousTitle currentTitle }
    ... on CrossReferencedEvent { id actor { login avatarUrl } createdAt willCloseTarget source { __typename ... on Issue { number title url issueState: state repository { nameWithOwner } } ... on PullRequest { number title url prState: state repository { nameWithOwner } } } }
    ... on ReferencedEvent { id actor { login avatarUrl } createdAt isCrossRepository commit { __typename abbreviatedOid url } }
    ... on MilestonedEvent { id actor { login avatarUrl } createdAt milestoneTitle }
    """

    static let prTimelineFragment = timelineFragment + """

    ... on PullRequestReview { id author { __typename login avatarUrl url } authorAssociation createdAt bodyHTML url reviewState: state viewerCanUpdate \(reactions) comments(first: 30) { totalCount nodes { id path line diffHunk bodyHTML createdAt url author { login avatarUrl } } } }
    ... on MergedEvent { id actor { login avatarUrl } createdAt mergeRefName commit { __typename abbreviatedOid url } }
    ... on ReviewRequestedEvent { id actor { login avatarUrl } createdAt requestedReviewer { ... on User { login } ... on Team { name } ... on Bot { login } } }
    ... on HeadRefForcePushedEvent { id actor { login avatarUrl } createdAt }
    ... on ReadyForReviewEvent { id actor { login avatarUrl } createdAt }
    ... on ConvertToDraftEvent { id actor { login avatarUrl } createdAt }
    """

    static let issueTimelineTypes = "[ISSUE_COMMENT, CLOSED_EVENT, REOPENED_EVENT, LABELED_EVENT, UNLABELED_EVENT, ASSIGNED_EVENT, UNASSIGNED_EVENT, RENAMED_TITLE_EVENT, CROSS_REFERENCED_EVENT, REFERENCED_EVENT, MILESTONED_EVENT]"
    static let prTimelineTypes = "[ISSUE_COMMENT, CLOSED_EVENT, REOPENED_EVENT, LABELED_EVENT, UNLABELED_EVENT, ASSIGNED_EVENT, UNASSIGNED_EVENT, RENAMED_TITLE_EVENT, CROSS_REFERENCED_EVENT, REFERENCED_EVENT, PULL_REQUEST_REVIEW, MERGED_EVENT, REVIEW_REQUESTED_EVENT, HEAD_REF_FORCE_PUSHED_EVENT, READY_FOR_REVIEW_EVENT, CONVERT_TO_DRAFT_EVENT]"

    static let detail = """
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        issueOrPullRequest(number: $number) {
          __typename
          ... on Issue {
            id number title url state stateReason locked createdAt bodyHTML authorAssociation comments { totalCount }
            author { __typename login avatarUrl url }
            labels(first: 30) { nodes { id name color } }
            assignees(first: 10) { nodes { login avatarUrl } }
            milestone { title }
            viewerCanUpdate viewerCanClose viewerCanReopen viewerSubscription viewerCanReact
            \(reactions)
            timelineItems(last: 100, itemTypes: \(issueTimelineTypes)) { filteredCount nodes { \(timelineFragment) } }
          }
          ... on PullRequest {
            id number title url state isDraft locked createdAt bodyHTML authorAssociation comments { totalCount }
            author { __typename login avatarUrl url }
            labels(first: 30) { nodes { id name color } }
            assignees(first: 10) { nodes { login avatarUrl } }
            milestone { title }
            viewerCanUpdate viewerCanClose viewerCanReopen viewerSubscription viewerCanReact viewerCanMergeAsAdmin
            \(reactions)
            headRefName baseRefName additions deletions changedFiles mergeable mergedAt reviewDecision
            reviewRequests(first: 10) { nodes { requestedReviewer { ... on User { login } ... on Team { name } ... on Bot { login } } } }
            commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
            timelineItems(last: 100, itemTypes: \(prTimelineTypes)) { filteredCount nodes { \(prTimelineFragment) } }
          }
        }
      }
    }
    """

    static let discussionDetail = """
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        discussion(number: $number) {
          __typename id number title url closed isAnswered locked createdAt bodyHTML authorAssociation
          author { __typename login avatarUrl url }
          category { name emojiHTML }
          answer { id }
          labels(first: 30) { nodes { id name color } }
          viewerSubscription viewerCanReact
          \(reactions)
          comments(last: 50) {
            totalCount
            nodes {
              id author { __typename login avatarUrl url } authorAssociation createdAt bodyHTML url isAnswer \(reactions)
              replies(first: 30) { totalCount nodes { id author { __typename login avatarUrl url } authorAssociation createdAt bodyHTML url \(reactions) } }
            }
          }
        }
      }
    }
    """

    /// Discussion notifications arrive without a subject URL; find the number by title.
    static let findDiscussion = """
    query($q: String!) { search(query: $q, type: DISCUSSION, first: 5) { nodes { ... on Discussion { number title } } } }
    """

    static let repoLabels = """
    query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { labels(first: 100, orderBy: {field: NAME, direction: ASC}) { nodes { id name color description } } } }
    """

    static let addComment = """
    mutation($id: ID!, $body: String!) { addComment(input: {subjectId: $id, body: $body}) { clientMutationId } }
    """
    static let addDiscussionComment = """
    mutation($id: ID!, $body: String!, $replyTo: ID) { addDiscussionComment(input: {discussionId: $id, body: $body, replyToId: $replyTo}) { clientMutationId } }
    """
    static let closeIssue = """
    mutation($id: ID!, $reason: IssueClosedStateReason) { closeIssue(input: {issueId: $id, stateReason: $reason}) { clientMutationId } }
    """
    static let reopenIssue = """
    mutation($id: ID!) { reopenIssue(input: {issueId: $id}) { clientMutationId } }
    """
    static let closePR = """
    mutation($id: ID!) { closePullRequest(input: {pullRequestId: $id}) { clientMutationId } }
    """
    static let reopenPR = """
    mutation($id: ID!) { reopenPullRequest(input: {pullRequestId: $id}) { clientMutationId } }
    """
    static let mergePR = """
    mutation($id: ID!, $method: PullRequestMergeMethod) { mergePullRequest(input: {pullRequestId: $id, mergeMethod: $method}) { clientMutationId } }
    """
    static let reviewPR = """
    mutation($id: ID!, $event: PullRequestReviewEvent!, $body: String) { addPullRequestReview(input: {pullRequestId: $id, event: $event, body: $body}) { clientMutationId } }
    """
    static let closeDiscussion = """
    mutation($id: ID!) { closeDiscussion(input: {discussionId: $id}) { clientMutationId } }
    """
    static let reopenDiscussion = """
    mutation($id: ID!) { reopenDiscussion(input: {discussionId: $id}) { clientMutationId } }
    """
    static let addLabels = """
    mutation($id: ID!, $labels: [ID!]!) { addLabelsToLabelable(input: {labelableId: $id, labelIds: $labels}) { clientMutationId } }
    """
    static let removeLabels = """
    mutation($id: ID!, $labels: [ID!]!) { removeLabelsFromLabelable(input: {labelableId: $id, labelIds: $labels}) { clientMutationId } }
    """
    static let assignSelf = """
    mutation($id: ID!, $users: [ID!]!) { addAssigneesToAssignable(input: {assignableId: $id, assigneeIds: $users}) { clientMutationId } }
    """
    static let addReaction = """
    mutation($id: ID!, $content: ReactionContent!) { addReaction(input: {subjectId: $id, content: $content}) { clientMutationId } }
    """
    static let removeReaction = """
    mutation($id: ID!, $content: ReactionContent!) { removeReaction(input: {subjectId: $id, content: $content}) { clientMutationId } }
    """
    static let viewer = "query { viewer { id login avatarUrl name } }"
}
