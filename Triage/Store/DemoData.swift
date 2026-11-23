import AppKit

/// `-triageDemo` fills the app with a made-up inbox for screenshots (the README, the website).
/// Nothing touches GitHub: no client is created, so every action stays local, and `LocalState`
/// neither loads nor saves, so the real state.json is left alone.
enum Demo {
    static let isOn = CommandLine.arguments.contains("-triageDemo")
}

/// The projects, people and conversations of the demo inbox. All invented.
enum DemoData {
    struct Inbox {
        var viewer: Viewer
        var inbox: [GHNotification]
        var done: [GHNotification]
        var subjects: [String: GQLSubject]
        var releases: [String: GHRelease]
    }

    /// One fixed "now", so the snooze in `localState()` and the notification it belongs to agree.
    static let now = Date()

    // MARK: People

    private struct Person {
        var login: String
        var initials: String
        var hue: CGFloat
        var bot = false
        var actor: GQLActor {
            GQLActor(__typename: bot ? "Bot" : "User", login: login, avatarUrl: DemoData.avatar(initials, hue))
        }
    }

    private static let you = Person(login: "alex-rivera", initials: "AR", hue: 0.58)
    private static let mira = Person(login: "mira-chen", initials: "MC", hue: 0.93)
    private static let tomasz = Person(login: "tkowalski", initials: "TK", hue: 0.08)
    private static let jo = Person(login: "jo-park", initials: "JP", hue: 0.75)
    private static let sam = Person(login: "sam-okafor", initials: "SO", hue: 0.36)
    private static let leah = Person(login: "leah-b", initials: "LB", hue: 0.13)
    private static let dependabot = Person(login: "dependabot", initials: "D", hue: 0.6, bot: true)

    /// A round-cornered initials tile as a PNG data URL, which both the SwiftUI rows and the web view load.
    private static var avatarCache: [String: String] = [:]
    static func avatar(_ initials: String, _ hue: CGFloat) -> String {
        if let cached = avatarCache[initials] { return cached }
        let size: CGFloat = 96
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor(hue: hue, saturation: 0.42, brightness: 0.72, alpha: 1).setFill()
            rect.fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: initials.count > 1 ? 38 : 46, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let text = initials as NSString
            let box = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: (size - box.width) / 2, y: (size - box.height) / 2), withAttributes: attrs)
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return "" }
        let url = "data:image/png;base64," + png.base64EncodedString()
        avatarCache[initials] = url
        return url
    }

    // MARK: Building blocks

    private static func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
    private static let hour = 60.0
    private static let day = 24 * 60.0

    private static func notification(
        _ id: String, _ repo: String, _ type: String, _ number: Int?, _ title: String,
        reason: String, unread: Bool = false, updated: Double, lastRead: Double? = nil
    ) -> GHNotification {
        let parts = repo.split(separator: "/").map(String.init)
        let path = switch type {
        case "PullRequest": "pulls/\(number ?? 0)"
        case "Discussion": "discussions/\(number ?? 0)"
        case "Release": "releases/\(id.filter(\.isNumber))"
        case "CheckSuite": "check-suites/\(id.filter(\.isNumber))"
        default: "issues/\(number ?? 0)"
        }
        let owner = GHNotification.Owner(login: parts[0], avatarUrl: avatar(String(parts[0].prefix(1)).uppercased(), 0.1))
        return GHNotification(
            id: id, unread: unread, reason: reason, updatedAt: ago(updated), lastReadAt: lastRead.map(ago),
            subject: .init(title: title, url: "https://api.github.com/repos/\(repo)/\(path)", latestCommentUrl: nil, type: type),
            repository: .init(fullName: repo, name: parts[1], private: false, htmlUrl: "https://github.com/\(repo)", owner: owner))
    }

    private static func label(_ name: String, _ color: String) -> GQLLabel { GQLLabel(name: name, color: color) }
    private static let bug = label("bug", "d73a4a")
    private static let performance = label("performance", "fbca04")
    private static let needsReview = label("needs review", "0e8a16")
    private static let docs = label("documentation", "0075ca")
    private static let dependencies = label("dependencies", "0366d6")
    private static let javascript = label("javascript", "f1e05a")
    private static let theme = label("theme", "c5def5")
    private static let devServer = label("dev server", "bfd4f2")

    private static func comment(_ who: Person, _ minutes: Double, _ html: String, association: String = "MEMBER") -> GQLTimelineNode {
        var c = GQLTimelineNode(__typename: "IssueComment")
        c.id = UUID().uuidString
        c.author = who.actor
        c.authorAssociation = association
        c.createdAt = ago(minutes)
        c.bodyHTML = html
        c.url = "https://github.com"
        return c
    }

    private static func event(_ type: String, _ who: Person, _ minutes: Double, _ edit: (inout GQLTimelineNode) -> Void = { _ in }) -> GQLTimelineNode {
        var e = GQLTimelineNode(__typename: type)
        e.actor = who.actor
        e.createdAt = ago(minutes)
        edit(&e)
        return e
    }

    private static func reactions(_ pairs: [(String, Int)]) -> [GQLReactionGroup] {
        pairs.map { GQLReactionGroup(content: $0.0, viewerHasReacted: false, reactors: GQLCount(totalCount: $0.1)) }
    }

    private static func subject(
        _ type: String, _ n: GHNotification, author: Person, state: String = "OPEN", created: Double,
        body: String, labels: [GQLLabel] = [], timeline: [GQLTimelineNode] = []
    ) -> GQLSubject {
        var s = GQLSubject(__typename: type)
        s.id = n.id
        s.number = n.number
        s.title = n.subject.title
        s.url = "\(n.repository.htmlUrl)/\(type == "PullRequest" ? "pull" : type == "Discussion" ? "discussions" : "issues")/\(n.number ?? 0)"
        s.state = state
        s.closed = state != "OPEN"
        s.createdAt = ago(created)
        s.updatedAt = n.updatedAt
        s.author = author.actor
        s.authorAssociation = "MEMBER"
        s.bodyHTML = body
        s.labels = GQLNodes(nodes: labels, totalCount: labels.count)
        let comments = timeline.filter { $0.__typename == "IssueComment" }.count
        s.comments = GQLNodes(nodes: [], totalCount: comments)
        s.timelineItems = GQLNodes(nodes: timeline, totalCount: timeline.count, filteredCount: timeline.count)
        s.viewerCanUpdate = true
        s.viewerCanClose = true
        s.viewerCanReopen = true
        s.viewerCanReact = true
        s.viewerSubscription = "SUBSCRIBED"
        return s
    }

    private static func pullRequest(
        _ n: GHNotification, author: Person, state: String = "OPEN", created: Double, body: String,
        labels: [GQLLabel] = [], timeline: [GQLTimelineNode] = [], head: String, files: Int, plus: Int, minus: Int
    ) -> GQLSubject {
        var s = subject("PullRequest", n, author: author, state: state, created: created, body: body, labels: labels, timeline: timeline)
        s.headRefName = head
        s.baseRefName = "main"
        s.changedFiles = files
        s.additions = plus
        s.deletions = minus
        s.mergeable = state == "OPEN" ? "MERGEABLE" : nil
        s.mergedAt = state == "MERGED" ? n.updatedAt : nil
        s.commits = GQLNodes(nodes: [GQLCommitNode(commit: .init(statusCheckRollup: GQLCheckRollup(state: "SUCCESS")))], totalCount: 1)
        return s
    }

    // MARK: The inbox

    static func make() -> Inbox {
        // Lumen: a static site generator. Northwind: an API client library.
        let incremental = notification("demo-1", "lumen-dev/lumen", "PullRequest", 482, "Incremental builds for content collections",
                                       reason: "review_requested", unread: true, updated: 12, lastRead: 22 * hour)
        let crash = notification("demo-2", "lumen-dev/lumen", "Issue", 479, "Dev server crashes when a slug ends with a slash",
                                 reason: "mention", unread: true, updated: 47)
        let rfc = notification("demo-3", "lumen-dev/lumen", "Discussion", 471, "RFC: plugin hooks for the asset pipeline",
                               reason: "comment", updated: 3 * hour)
        let darkMode = notification("demo-4", "lumen-dev/lumen-themes", "PullRequest", 88, "Dark mode for the Docs theme",
                                    reason: "comment", updated: 5 * hour)
        let release = notification("demo-5", "lumen-dev/lumen", "Release", nil, "v3.4.0", reason: "subscribed", updated: 7 * hour)
        let esbuild = notification("demo-6", "lumen-dev/lumen", "PullRequest", 485, "Bump esbuild from 0.24.0 to 0.25.1",
                                   reason: "subscribed", unread: true, updated: 9 * hour)
        let retry = notification("demo-7", "northwind/api-client", "Issue", 213, "Retry on 429 ignores the Retry-After header",
                                 reason: "assign", unread: true, updated: 1 * day + 2 * hour)
        let shortcodes = notification("demo-8", "lumen-dev/lumen-docs", "Issue", 156, "Document the new image shortcodes",
                                      reason: "author", updated: 1 * day + 5 * hour)
        let ci = notification("demo-9", "lumen-dev/lumen", "CheckSuite", nil, "CI workflow run failed for main branch",
                              reason: "ci_activity", updated: 2 * day)
        let typed = notification("demo-10", "northwind/api-client", "Issue", 208, "Typed errors for the pagination helpers",
                                 reason: "team_mention", updated: 2 * day + 3 * hour)
        let stream = notification("demo-11", "northwind/api-client", "PullRequest", 210, "Stream large responses instead of buffering them",
                                  reason: "review_requested", updated: 3 * day)

        let sitemap = notification("demo-21", "lumen-dev/lumen", "Issue", 466, "Sitemap includes draft pages", reason: "comment", updated: 1 * day)
        let parser = notification("demo-22", "lumen-dev/lumen", "PullRequest", 470, "Reuse one Markdown parser across pages",
                                  reason: "review_requested", updated: 2 * day)
        let deploy = notification("demo-23", "lumen-dev/lumen", "Discussion", 452, "How do you deploy Lumen sites to Cloudflare Pages?",
                                  reason: "comment", updated: 3 * day)
        let clientRelease = notification("demo-24", "northwind/api-client", "Release", nil, "v2.1.0", reason: "subscribed", updated: 4 * day)
        let overflow = notification("demo-25", "lumen-dev/lumen-themes", "Issue", 84, "Code blocks overflow on narrow screens",
                                    reason: "mention", updated: 5 * day)

        var subjects: [String: GQLSubject] = [:]

        var pr = pullRequest(
            incremental, author: mira, created: 2 * day,
            body: """
            <p>Builds now skip content collections whose sources haven't changed since the last run. On the docs site a one-page edit goes from a 41s full build to 6s.</p>
            <h3>How it works</h3>
            <ul>
            <li>Each collection keeps a hash of its inputs in <code>.lumen/cache/collections.json</code></li>
            <li>Templates and config are part of the hash, so editing a layout still rebuilds every page that uses it</li>
            <li><code>lumen build --full</code> ignores the cache</li>
            </ul>
            <p>Closes #455.</p>
            """,
            labels: [performance, needsReview],
            timeline: [
                event("LabeledEvent", mira, 2 * day - 2) { $0.label = performance },
                event("ReviewRequestedEvent", mira, 2 * day - 3) { $0.requestedReviewer = you.actor },
                comment(tomasz, 1 * day, "<p>Tried this on our 3,000-page site: a one-page edit went from 2m10s to 14s. 🎉</p><p>One thing I noticed: deleting a page leaves it in the output until the next full build.</p>", association: "CONTRIBUTOR"),
                comment(mira, 20 * hour, "<p>Good catch, thanks. Deleted sources now invalidate their collection, and there's a test for it in <code>collections.test.ts</code>.</p>"),
                event("PullRequestReview", jo, 3 * hour) {
                    $0.author = jo.actor
                    $0.reviewState = "APPROVED"
                    $0.authorAssociation = "MEMBER"
                    $0.bodyHTML = "<p>Looks good to me. The cache file format is worth a page in the docs before this ships.</p>"
                },
                comment(mira, 12, "<p>@alex-rivera could you look over the invalidation in <code>src/build/collections.ts</code>? It's the part I'm least sure of.</p>"),
            ],
            head: "incremental-collections", files: 14, plus: 412, minus: 87)
        pr.reviewDecision = "REVIEW_REQUIRED"
        pr.assignees = GQLNodes(nodes: [mira.actor], totalCount: 1)
        pr.reviewRequests = GQLNodes(nodes: [GQLSubject.ReviewRequest(requestedReviewer: you.actor)], totalCount: 1)
        pr.reactionGroups = reactions([("THUMBS_UP", 4), ("ROCKET", 2)])
        subjects[incremental.id] = pr

        subjects[crash.id] = subject(
            "Issue", crash, author: tomasz, created: 5 * hour,
            body: """
            <p>Running <code>lumen dev</code> and opening a page whose slug ends with a slash takes the whole server down.</p>
            <pre><code>TypeError: Cannot read properties of undefined (reading 'layout')
                at resolvePage (src/dev/router.ts:118:22)
                at Server.handle (src/dev/server.ts:64:18)</code></pre>
            <p><strong>Steps:</strong> add <code>slug: "guides/"</code> to any page, run <code>lumen dev</code>, open <code>/guides/</code>.</p>
            <p>Lumen 3.3.2, Node 22.</p>
            """,
            labels: [bug, devServer],
            timeline: [
                comment(sam, 2 * hour, "<p>Same here on 3.3.2. Looks like it came in with the router change in #461.</p>", association: "CONTRIBUTOR"),
                comment(mira, 47, "<p>@alex-rivera you know the router best, any idea? Happy to pair on it.</p>"),
            ])

        var discussion = subject("Discussion", rfc, author: leah, created: 4 * day,
            body: "<p>Plugins can add content sources and template helpers, but nothing can touch assets on their way through the pipeline. I'd like three hooks: <code>beforeAsset</code>, <code>transformAsset</code> and <code>afterBundle</code>.</p><p>That covers image optimisation, SRI hashes and bundle reports without patching core. Thoughts?</p>")
        discussion.category = GQLCategory(name: "Ideas", emojiHTML: "<div><g-emoji class=\"g-emoji\" alias=\"bulb\">💡</g-emoji></div>")
        discussion.comments = GQLNodes(nodes: [
            GQLDiscussionReply(id: "r1", author: mira.actor, authorAssociation: "MEMBER", createdAt: ago(3 * day), bodyHTML: "<p>I like it. Can <code>transformAsset</code> run in a worker? Image work blocks the build otherwise.</p>", reactionGroups: reactions([("THUMBS_UP", 3)])),
            GQLDiscussionReply(id: "r2", author: leah.actor, authorAssociation: "CONTRIBUTOR", createdAt: ago(3 * hour), bodyHTML: "<p>Yes, that's the plan: hooks get a serialisable asset, so they can run off the main thread.</p>"),
        ], totalCount: 2)
        subjects[rfc.id] = discussion

        subjects[darkMode.id] = pullRequest(
            darkMode, author: jo, state: "MERGED", created: 2 * day,
            body: "<p>Adds a dark palette to the Docs theme, following the reader's system setting, with a toggle in the header.</p>",
            labels: [theme],
            timeline: [
                comment(mira, 6 * hour, "<p>Lovely. Merging for 3.4.</p>"),
                event("MergedEvent", mira, 5 * hour) { $0.mergeRefName = "main" },
            ],
            head: "docs-dark-mode", files: 6, plus: 188, minus: 21)

        var bump = pullRequest(
            esbuild, author: dependabot, created: 9 * hour,
            body: "<p>Bumps <a href=\"https://github.com\">esbuild</a> from 0.24.0 to 0.25.1.</p>",
            labels: [dependencies, javascript], head: "dependabot/npm_and_yarn/esbuild-0.25.1", files: 2, plus: 23, minus: 23)
        bump.authorAssociation = "NONE"
        subjects[esbuild.id] = bump

        subjects[retry.id] = subject(
            "Issue", retry, author: sam, created: 2 * day,
            body: "<p>When the API answers 429, the client retries after its own backoff and ignores <code>Retry-After</code>, so it gets rate-limited again straight away.</p>",
            labels: [bug],
            timeline: [event("AssignedEvent", mira, 1 * day + 2 * hour) { $0.assignee = you.actor }])

        subjects[shortcodes.id] = subject(
            "Issue", shortcodes, author: you, state: "CLOSED", created: 6 * day,
            body: "<p>3.3 added <code>image</code> and <code>figure</code> shortcodes, but the docs don't mention them yet.</p>",
            labels: [docs],
            timeline: [
                comment(leah, 2 * day, "<p>Done in #160, with examples for both.</p>", association: "CONTRIBUTOR"),
                event("ClosedEvent", leah, 1 * day + 5 * hour) { $0.stateReason = "COMPLETED" },
            ])

        subjects[typed.id] = subject(
            "Issue", typed, author: sam, created: 3 * day,
            body: "<p>The pagination helpers throw plain <code>Error</code>s. A <code>PaginationError</code> with the page and cursor would make retries much easier to write.</p>")

        var draft = pullRequest(
            stream, author: sam, created: 4 * day,
            body: "<p>Responses over 1 MB are now streamed instead of read into memory first.</p>",
            head: "stream-responses", files: 5, plus: 140, minus: 32)
        draft.isDraft = true
        subjects[stream.id] = draft

        subjects[sitemap.id] = subject("Issue", sitemap, author: leah, state: "CLOSED", created: 3 * day,
            body: "<p>Pages with <code>draft: true</code> still end up in <code>sitemap.xml</code>.</p>", labels: [bug])
        subjects[parser.id] = pullRequest(parser, author: tomasz, state: "MERGED", created: 4 * day,
            body: "<p>Creating a parser per page was a third of the build time on large sites.</p>", labels: [performance],
            head: "shared-parser", files: 3, plus: 41, minus: 18)
        var answered = subject("Discussion", deploy, author: sam, created: 6 * day,
            body: "<p>What's your build command and output folder for Cloudflare Pages?</p>")
        answered.isAnswered = true
        answered.category = GQLCategory(name: "Q&A", emojiHTML: "<div>🙏</div>")
        subjects[deploy.id] = answered
        subjects[overflow.id] = subject("Issue", overflow, author: tomasz, state: "CLOSED", created: 8 * day,
            body: "<p>Long lines in code blocks push the page wider than the screen on phones.</p>", labels: [theme, bug])

        let releases: [String: GHRelease] = [
            release.id: GHRelease(
                name: "Lumen 3.4.0", tagName: "v3.4.0", htmlUrl: "https://github.com/lumen-dev/lumen/releases",
                bodyHtml: "<h3>New</h3><ul><li>Dark mode for the Docs theme</li><li><code>lumen check</code> finds broken internal links</li></ul><h3>Fixed</h3><ul><li>Sitemap no longer lists draft pages</li></ul>",
                prerelease: false, draft: false, publishedAt: release.updatedAt, author: .init(login: mira.login, avatarUrl: mira.actor.avatarUrl ?? "")),
            clientRelease.id: GHRelease(
                name: "v2.1.0", tagName: "v2.1.0", htmlUrl: "https://github.com/northwind/api-client/releases",
                bodyHtml: "<ul><li>Request timeouts per call</li><li>Smaller bundle</li></ul>",
                prerelease: false, draft: false, publishedAt: clientRelease.updatedAt, author: .init(login: sam.login, avatarUrl: sam.actor.avatarUrl ?? "")),
        ]

        _ = ci
        return Inbox(
            viewer: Viewer(id: "demo", login: you.login, avatarUrl: you.actor.avatarUrl),
            inbox: [incremental, crash, rfc, darkMode, release, esbuild, retry, shortcodes, ci, typed, stream],
            done: [sitemap, parser, deploy, clientRelease, overflow],
            subjects: subjects, releases: releases)
    }

    /// One saved thread and one snoozed until tomorrow morning, so those tabs have something in them.
    static func localState() -> LocalState {
        var state = LocalState()
        state.saved = ["demo-3"]
        let morning = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: now.addingTimeInterval(86_400)) ?? now
        state.snoozed = ["demo-10": .init(until: morning, updatedAt: ago(2 * day + 3 * hour))]
        return state
    }
}
