import XCTest
@testable import Triage

final class InboxQueryTests: XCTestCase {
    private func facts(title: String = "Form submit on Enter no longer works", repo: String = "getgrav/grav-plugin-admin2",
                       reason: String = "mention", kind: SubjectKind = .issue, unread: Bool = true, state: SubjectState? = .open,
                       author: String? = "simogeo", bot: Bool = false, labels: [String] = ["bug"]) -> InboxQuery.Facts {
        InboxQuery.Facts(title: title, repo: repo, owner: String(repo.split(separator: "/")[0]), reason: reason, kind: kind,
                         unread: unread, state: state, author: author, authorIsBot: bot, labels: labels, saved: false, snoozed: false)
    }

    func testEmptyMatchesEverything() {
        XCTAssertTrue(InboxQuery("").isEmpty)
        XCTAssertTrue(InboxQuery("").matches(facts()))
    }

    func testRepoFullAndShortName() {
        XCTAssertTrue(InboxQuery("repo:getgrav/grav-plugin-admin2").matches(facts()))
        XCTAssertTrue(InboxQuery("repo:grav-plugin-admin2").matches(facts()))
        XCTAssertFalse(InboxQuery("repo:getgrav/grav").matches(facts()))
        XCTAssertFalse(InboxQuery("repo:admin2").matches(facts()))
    }

    func testCommaIsOrSpaceIsAnd() {
        XCTAssertTrue(InboxQuery("reason:assign,mention").matches(facts()))
        XCTAssertFalse(InboxQuery("reason:mention is:pr").matches(facts()))
        XCTAssertTrue(InboxQuery("reason:mention is:issue,pr").matches(facts()))
    }

    func testNegation() {
        XCTAssertFalse(InboxQuery("-is:issue").matches(facts()))
        XCTAssertTrue(InboxQuery("-is:release").matches(facts()))
        XCTAssertTrue(InboxQuery("-label:wontfix").matches(facts()))
    }

    func testStates() {
        XCTAssertTrue(InboxQuery("is:open").matches(facts(state: .draft)))
        XCTAssertTrue(InboxQuery("is:finished").matches(facts(state: .merged)))
        XCTAssertTrue(InboxQuery("is:closed").matches(facts(state: .notPlanned)))
        XCTAssertFalse(InboxQuery("is:closed").matches(facts(state: nil)))
    }

    func testParticipatingAndAliases() {
        XCTAssertTrue(InboxQuery("reason:participating").matches(facts(reason: "comment")))
        XCTAssertFalse(InboxQuery("reason:participating").matches(facts(reason: "subscribed")))
        XCTAssertTrue(InboxQuery("reason:review").matches(facts(reason: "review_requested")))
        XCTAssertTrue(InboxQuery("reason:review-requested").matches(facts(reason: "review_requested")))
    }

    func testFreeTextAndQuotes() {
        XCTAssertTrue(InboxQuery("enter").matches(facts()))
        XCTAssertTrue(InboxQuery("admin2").matches(facts()))
        XCTAssertTrue(InboxQuery("\"no longer\"").matches(facts()))
        XCTAssertFalse(InboxQuery("\"longer no\"").matches(facts()))
        XCTAssertFalse(InboxQuery("crash").matches(facts()))
    }

    func testUnknownKeyIsText() {
        let q = InboxQuery("foo:bar")
        XCTAssertEqual(q.terms.count, 0)
        XCTAssertEqual(q.text, ["foo:bar"])
    }

    func testBotAndAuthor() {
        XCTAssertTrue(InboxQuery("is:bot").matches(facts(author: "dependabot", bot: true)))
        XCTAssertTrue(InboxQuery("author:SimoGeo").matches(facts()))
    }
}

final class NotificationURLTests: XCTestCase {
    private func make(type: String, url: String?, comment: String? = nil) throws -> GHNotification {
        let json = """
        {"id":"123","unread":true,"reason":"mention","updated_at":"2026-11-22T18:33:15Z","last_read_at":null,
         "subject":{"title":"T","url":\(url.map { "\"\($0)\"" } ?? "null"),"latest_comment_url":\(comment.map { "\"\($0)\"" } ?? "null"),"type":"\(type)"},
         "repository":{"full_name":"getgrav/grav","name":"grav","private":false,"html_url":"https://github.com/getgrav/grav",
           "owner":{"login":"getgrav","avatar_url":"https://avatars.githubusercontent.com/u/1"}}}
        """
        return try GitHubClient.decoder.decode(GHNotification.self, from: Data(json.utf8))
    }

    func testIssueURLWithCommentAnchor() throws {
        let n = try make(type: "Issue", url: "https://api.github.com/repos/getgrav/grav/issues/42",
                         comment: "https://api.github.com/repos/getgrav/grav/issues/comments/999")
        XCTAssertEqual(n.number, 42)
        XCTAssertEqual(n.webURL.absoluteString, "https://github.com/getgrav/grav/issues/42?notification_referrer_id=NT_123#issuecomment-999")
    }

    func testPullURL() throws {
        let n = try make(type: "PullRequest", url: "https://api.github.com/repos/getgrav/grav/pulls/7",
                         comment: "https://api.github.com/repos/getgrav/grav/pulls/7")
        XCTAssertEqual(n.webURL.absoluteString, "https://github.com/getgrav/grav/pull/7?notification_referrer_id=NT_123")
    }

    func testDiscussionWithoutURL() throws {
        let n = try make(type: "Discussion", url: nil)
        XCTAssertNil(n.number)
        XCTAssertTrue(n.webURL.absoluteString.hasPrefix("https://github.com/getgrav/grav/discussions"))
    }

    func testNextLink() {
        let header = #"<https://api.github.com/notifications?all=true&page=2>; rel="next", <https://api.github.com/notifications?all=true&page=5>; rel="last""#
        XCTAssertEqual(GitHubClient.nextLink(header)?.absoluteString, "https://api.github.com/notifications?all=true&page=2")
        XCTAssertNil(GitHubClient.nextLink(#"<https://x>; rel="prev""#))
    }

    func testBatchQueryEscapes() {
        let q = Queries.batch([(alias: "t0", owner: "a\"b", name: "c", number: 1, discussion: false)])
        XCTAssertTrue(q.contains(#"owner: "a\"b""#))
    }
}
