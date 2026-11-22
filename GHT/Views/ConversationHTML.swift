import Foundation

/// Builds the conversation page from GitHub's own rendered HTML (bodyHTML), so markdown, code, task
/// lists, images and mentions look exactly like github.com.
enum ConversationHTML {
    static func render(_ detail: ThreadDetail, notification n: GHNotification, viewer: String?, lastRead: Date?) -> String {
        var html = ""
        switch detail {
        case .conversation(let s):
            html = s.__typename == "Discussion" ? discussion(s, viewer: viewer, lastRead: lastRead) : thread(s, n: n, viewer: viewer, lastRead: lastRead)
        case .release(let r):
            html = release(r)
        case .unsupported:
            html = ""
        }
        return page(html)
    }

    // MARK: Issue / PR

    private static func thread(_ s: GQLSubject, n: GHNotification, viewer: String?, lastRead: Date?) -> String {
        var out = ""
        var dividerPlaced = false
        func isNew(_ date: Date?, _ author: String?) -> Bool {
            guard let lastRead, let date else { return false }
            return date > lastRead && author != viewer
        }
        func divider(_ date: Date?, _ author: String?) {
            if !dividerPlaced, isNew(date, author) {
                out += #"<div class="new-divider" id="ght-new"><span>New since you last read</span></div>"#
                dividerPlaced = true
            }
        }

        out += comment(id: s.id, anchor: "ght-body", author: s.author, association: s.authorAssociation, date: s.createdAt,
                       verb: "opened", bodyHTML: s.bodyHTML, url: s.url, reactions: s.reactionGroups, isNew: false, isOpening: true)

        let items = s.timelineItems?.items ?? []
        let total = s.timelineItems?.filteredCount ?? items.count
        if total > items.count, let url = s.url {
            out += #"<div class="hidden-items"><a href="\#(esc(url))">\#(total - items.count) earlier item\#(total - items.count == 1 ? "" : "s") — open on GitHub</a></div>"#
        }
        for item in items {
            let who = item.author?.login ?? item.actor?.login
            switch item.__typename {
            case "IssueComment":
                divider(item.createdAt, who)
                if item.isMinimized == true {
                    out += minimized(item)
                } else {
                    out += comment(id: item.id, anchor: item.databaseId.map { "issuecomment-\($0)" }, author: item.author,
                                   association: item.authorAssociation, date: item.createdAt, verb: "commented", bodyHTML: item.bodyHTML,
                                   url: item.url, reactions: item.reactionGroups, isNew: isNew(item.createdAt, who), isOpening: false)
                }
            case "PullRequestReview":
                divider(item.createdAt, who)
                out += review(item, isNew: isNew(item.createdAt, who))
            default:
                if let line = eventLine(item) {
                    divider(item.createdAt, who)
                    out += line
                }
            }
        }
        return out
    }

    private static func comment(id: String?, anchor: String?, author: GQLActor?, association: String?, date: Date?, verb: String,
                                bodyHTML: String?, url: String?, reactions: [GQLReactionGroup]?, isNew: Bool, isOpening: Bool,
                                extraClass: String = "", badge: String = "") -> String {
        let login = author?.display ?? "ghost"
        let body = (bodyHTML?.isEmpty ?? true) ? #"<p class="empty">No description provided.</p>"# : bodyHTML!
        let assoc = associationLabel(association).map { #"<span class="badge">\#($0)</span>"# } ?? ""
        let anchorAttr = anchor.map { #" id="\#(esc($0))""# } ?? ""
        let time = date.map { #"<a class="time" href="\#(esc(url ?? ""))" title="\#(esc(full($0)))">\#(relative($0))</a>"# } ?? ""
        return """
        <div class="item comment\(isNew ? " is-new" : "")\(isOpening ? " opening" : "") \(extraClass)"\(anchorAttr)>
          <img class="avatar" src="\(esc(avatar(author?.avatarUrl, 80)))" alt="">
          <div class="card">
            <div class="card-header">
              <a class="author" href="https://github.com/\(esc(login))">\(esc(login))</a>
              <span class="verb">\(verb)</span> \(time) \(assoc)\(badge)
              <span class="actions">
                <button class="act" data-action="mention" data-login="\(esc(login))" title="Mention @\(esc(login))">@</button>
                <button class="act" data-action="quote" title="Quote reply (uses your selection if there is one)">❝</button>
              </span>
            </div>
            <div class="markdown-body">\(body)</div>
            \(reactionsRow(id, reactions))
          </div>
        </div>
        """
    }

    private static func minimized(_ item: GQLTimelineNode) -> String {
        let reason = (item.minimizedReason ?? "hidden").lowercased().replacingOccurrences(of: "_", with: " ")
        return """
        <details class="item minimized">
          <summary>\(esc(item.author?.display ?? "Someone"))'s comment was marked as \(esc(reason))</summary>
          <div class="markdown-body">\(item.bodyHTML ?? "")</div>
        </details>
        """
    }

    private static func review(_ item: GQLTimelineNode, isNew: Bool) -> String {
        let login = item.author?.display ?? "ghost"
        let (icon, cls, verb): (String, String, String) = switch item.reviewState {
        case "APPROVED": ("✓", "approved", "approved these changes")
        case "CHANGES_REQUESTED": ("±", "changes", "requested changes")
        case "DISMISSED": ("×", "dismissed", "left a review (dismissed)")
        default: ("◎", "reviewed", "reviewed")
        }
        let hasBody = !(item.bodyHTML?.isEmpty ?? true)
        let comments = item.comments?.items ?? []
        var out = """
        <div class="event review \(cls)\(isNew ? " is-new" : "")">
          <span class="event-icon \(cls)">\(icon)</span>
          <img class="mini-avatar" src="\(esc(avatar(item.author?.avatarUrl, 40)))" alt="">
          <a class="author" href="https://github.com/\(esc(login))">\(esc(login))</a> \(verb)
          \(item.createdAt.map { #"<a class="time" href="\#(esc(item.url ?? ""))" title="\#(esc(full($0)))">\#(relative($0))</a>"# } ?? "")
        </div>
        """
        if hasBody || !comments.isEmpty {
            out += #"<div class="review-body\#(isNew ? " is-new" : "")">"#
            if hasBody { out += #"<div class="card"><div class="markdown-body">\#(item.bodyHTML!)</div>\#(reactionsRow(item.id, item.reactionGroups))</div>"# }
            for c in comments {
                let hunk = c.diffHunk.map { h in
                    let lines = h.split(separator: "\n", omittingEmptySubsequences: false).suffix(6)
                    let rows = lines.map { line -> String in
                        let cls = line.hasPrefix("+") ? "add" : line.hasPrefix("-") ? "del" : line.hasPrefix("@@") ? "hunk" : ""
                        return #"<div class="\#(cls)">\#(esc(String(line)))</div>"#
                    }.joined()
                    return #"<div class="diff">\#(rows)</div>"#
                } ?? ""
                out += """
                <div class="card review-comment">
                  <div class="path"><a href="\(esc(c.url ?? ""))">\(esc(c.path ?? ""))\(c.line.map { ":\($0)" } ?? "")</a></div>
                  \(hunk)
                  <div class="card-header small"><img class="mini-avatar" src="\(esc(avatar(c.author?.avatarUrl, 40)))" alt="">
                    <span class="author">\(esc(c.author?.display ?? "ghost"))</span> <span class="time">\(relative(c.createdAt))</span>
                    <span class="actions"><button class="act" data-action="quote" title="Quote reply">❝</button></span></div>
                  <div class="markdown-body">\(c.bodyHTML)</div>
                </div>
                """
            }
            out += "</div>"
        }
        return out
    }

    private static func eventLine(_ item: GQLTimelineNode) -> String? {
        let actor = item.actor?.display ?? "Someone"
        let text: String
        var icon = "•"
        var cls = ""
        switch item.__typename {
        case "ClosedEvent":
            let reason = switch item.stateReason {
            case "NOT_PLANNED": " as not planned"
            case "DUPLICATE": " as duplicate"
            case "COMPLETED": " as completed"
            default: ""
            }
            var via = ""
            if let c = item.closer {
                if let num = c.number { via = #" in <a href="\#(esc(c.url ?? ""))">#\#(num)</a>"# }
                else if let oid = c.abbreviatedOid { via = #" in <a href="\#(esc(c.url ?? ""))"><code>\#(esc(oid))</code></a>"# }
            }
            text = "closed this\(reason)\(via)"
            icon = item.stateReason == "NOT_PLANNED" ? "⊘" : "✓"
            cls = item.stateReason == "NOT_PLANNED" ? "muted" : "done"
        case "ReopenedEvent":
            text = "reopened this"; icon = "↺"; cls = "open"
        case "LabeledEvent", "UnlabeledEvent":
            guard let l = item.label else { return nil }
            text = "\(item.__typename == "LabeledEvent" ? "added" : "removed") \(labelHTML(l)) label"
            icon = "⌗"
        case "AssignedEvent":
            let who = item.assignee?.display ?? "someone"
            text = who == item.actor?.login ? "self-assigned this" : "assigned <b>\(esc(who))</b>"
            icon = "☺"
        case "UnassignedEvent":
            text = "unassigned <b>\(esc(item.assignee?.display ?? "someone"))</b>"; icon = "☺"
        case "RenamedTitleEvent":
            text = "changed the title <del>\(esc(item.previousTitle ?? ""))</del> <ins>\(esc(item.currentTitle ?? ""))</ins>"; icon = "✎"
        case "CrossReferencedEvent":
            guard let src = item.source else { return nil }
            let repo = src.repository?.nameWithOwner ?? ""
            let verb = item.willCloseTarget == true ? "linked a pull request that will close this" : "mentioned this in"
            text = #"\#(verb) <a href="\#(esc(src.url ?? ""))">\#(esc(src.title ?? "")) <span class="dim">\#(esc(repo))#\#(src.number ?? 0)</span></a>"#
            icon = "↗"
        case "ReferencedEvent":
            guard let c = item.commit else { return nil }
            text = #"added a commit that referenced this <a href="\#(esc(c.url ?? ""))"><code>\#(esc(c.abbreviatedOid ?? ""))</code></a>"#
            icon = "⎇"
        case "MilestonedEvent":
            text = "added this to the <b>\(esc(item.milestoneTitle ?? ""))</b> milestone"; icon = "⚑"
        case "MergedEvent":
            text = #"merged commit <a href="\#(esc(item.commit?.url ?? ""))"><code>\#(esc(item.commit?.abbreviatedOid ?? ""))</code></a> into <code>\#(esc(item.mergeRefName ?? ""))</code>"#
            icon = "⑂"; cls = "done"
        case "ReviewRequestedEvent":
            text = "requested a review from <b>\(esc(item.requestedReviewer?.display ?? "someone"))</b>"; icon = "◉"
        case "HeadRefForcePushedEvent":
            text = "force-pushed the branch"; icon = "⤴"
        case "ReadyForReviewEvent":
            text = "marked this pull request as ready for review"; icon = "◉"; cls = "open"
        case "ConvertToDraftEvent":
            text = "marked this pull request as draft"; icon = "◌"; cls = "muted"
        default:
            return nil
        }
        let time = item.createdAt.map { #"<span class="time" title="\#(esc(full($0)))">\#(relative($0))</span>"# } ?? ""
        return """
        <div class="event"><span class="event-icon \(cls)">\(icon)</span><img class="mini-avatar" src="\(esc(avatar(item.actor?.avatarUrl, 40)))" alt="">
        <a class="author" href="https://github.com/\(esc(actor))">\(esc(actor))</a> \(text) \(time)</div>
        """
    }

    // MARK: Discussion

    private static func discussion(_ s: GQLSubject, viewer: String?, lastRead: Date?) -> String {
        var out = ""
        var dividerPlaced = false
        let category = s.category.map { #"<div class="category">\#($0.emojiHTML ?? "") \#(esc($0.name))</div>"# } ?? ""
        out += category
        out += comment(id: s.id, anchor: "ght-body", author: s.author, association: s.authorAssociation, date: s.createdAt, verb: "started",
                       bodyHTML: s.bodyHTML, url: s.url, reactions: s.reactionGroups, isNew: false, isOpening: true)
        let comments = s.comments?.items ?? []
        if let total = s.comments?.totalCount, total > comments.count, let url = s.url {
            out += #"<div class="hidden-items"><a href="\#(esc(url))">\#(total - comments.count) earlier comments — open on GitHub</a></div>"#
        }
        for c in comments {
            let new = lastRead.map { c.createdAt > $0 && c.author?.login != viewer } ?? false
            if new && !dividerPlaced {
                out += #"<div class="new-divider" id="ght-new"><span>New since you last read</span></div>"#
                dividerPlaced = true
            }
            let answer = c.isAnswer == true ? #"<span class="badge answer">✓ Answer</span>"# : ""
            out += comment(id: c.id, anchor: nil, author: c.author, association: c.authorAssociation, date: c.createdAt, verb: "commented",
                           bodyHTML: c.bodyHTML, url: c.url, reactions: c.reactionGroups, isNew: new, isOpening: false,
                           extraClass: c.isAnswer == true ? "answer" : "", badge: answer)
            let replies = c.replies?.items ?? []
            if !replies.isEmpty {
                out += #"<div class="replies">"#
                for r in replies {
                    let rnew = lastRead.map { r.createdAt > $0 && r.author?.login != viewer } ?? false
                    out += comment(id: r.id, anchor: nil, author: r.author, association: r.authorAssociation, date: r.createdAt, verb: "replied",
                                   bodyHTML: r.bodyHTML, url: r.url, reactions: r.reactionGroups, isNew: rnew, isOpening: false)
                }
                out += "</div>"
            }
        }
        return out
    }

    // MARK: Release

    private static func release(_ r: GHRelease) -> String {
        let author = r.author.map { GQLActor(login: $0.login, avatarUrl: $0.avatarUrl) }
        let title = esc(r.name?.isEmpty == false ? r.name! : r.tagName)
        let badge = r.prerelease ? #" <span class="badge pre">Pre-release</span>"# : ""
        return """
        <h2 class="release-title">\(title)\(badge)</h2>
        \(comment(id: nil, anchor: "ght-body", author: author, association: nil, date: r.publishedAt, verb: "released \(esc(r.tagName))",
                  bodyHTML: r.bodyHtml, url: r.htmlUrl, reactions: nil, isNew: false, isOpening: true))
        """
    }

    // MARK: Helpers

    private static func reactionsRow(_ subjectID: String?, _ groups: [GQLReactionGroup]?) -> String {
        guard let subjectID else { return "" }
        let present = (groups ?? []).filter { $0.reactors.totalCount > 0 }
        let buttons = present.map { g in
            #"<button class="reaction\#(g.viewerHasReacted ? " mine" : "")" data-subject="\#(esc(subjectID))" data-content="\#(g.content)" data-mine="\#(g.viewerHasReacted)">\#(g.emoji) <span>\#(g.reactors.totalCount)</span></button>"#
        }.joined()
        let all = ["THUMBS_UP", "THUMBS_DOWN", "LAUGH", "HOORAY", "CONFUSED", "HEART", "ROCKET", "EYES"]
        let mine = Set((groups ?? []).filter(\.viewerHasReacted).map(\.content))
        let picker = all.map { c in
            let emoji = GQLReactionGroup(content: c, viewerHasReacted: false, reactors: GQLCount(totalCount: 0)).emoji
            return #"<button class="reaction pick" data-subject="\#(esc(subjectID))" data-content="\#(c)" data-mine="\#(mine.contains(c))">\#(emoji)</button>"#
        }.joined()
        return #"<div class="reactions">\#(buttons)<span class="add-reaction"><button class="reaction add" title="Add reaction">☺︎+</button><span class="picker">\#(picker)</span></span></div>"#
    }

    private static func labelHTML(_ l: GQLLabel) -> String {
        #"<span class="label" style="--label: #\#(esc(l.color))">\#(esc(l.name))</span>"#
    }

    private static func associationLabel(_ a: String?) -> String? {
        switch a {
        case "OWNER": "Owner"
        case "MEMBER": "Member"
        case "COLLABORATOR": "Collaborator"
        case "CONTRIBUTOR": "Contributor"
        case "FIRST_TIME_CONTRIBUTOR", "FIRST_TIMER": "First-time contributor"
        default: nil
        }
    }

    private static func avatar(_ url: String?, _ size: Int) -> String {
        guard let url, !url.isEmpty else { return "" }
        return url + (url.contains("?") ? "&" : "?") + "s=\(size)"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    static func relative(_ d: Date) -> String {
        if -d.timeIntervalSinceNow > 86400 * 30 {
            return "on " + d.formatted(.dateTime.month(.abbreviated).day().year())
        }
        return relativeFormatter.localizedString(for: d, relativeTo: Date())
    }

    static func full(_ d: Date) -> String { d.formatted(date: .complete, time: .shortened) }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: Page

    private static func page(_ body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data:; media-src https:; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
        <style>\(css)</style></head>
        <body><main>\(body)</main><script>\(script)</script></body></html>
        """
    }

    static let script = """
    document.addEventListener('click', function (e) {
      const btn = e.target.closest('button');
      if (!btn) return;
      e.preventDefault();
      const post = (m) => window.webkit.messageHandlers.ght.postMessage(m);
      if (btn.classList.contains('add')) { btn.parentElement.classList.toggle('open'); return; }
      if (btn.dataset.subject) {
        post({type: 'react', subject: btn.dataset.subject, content: btn.dataset.content, remove: btn.dataset.mine === 'true'});
        return;
      }
      if (btn.dataset.action === 'mention') { post({type: 'mention', login: btn.dataset.login}); return; }
      if (btn.dataset.action === 'quote') {
        const card = btn.closest('.card');
        const body = card.querySelector('.markdown-body');
        const sel = window.getSelection();
        let text = '';
        if (sel && !sel.isCollapsed && body.contains(sel.anchorNode)) text = sel.toString();
        else text = body.innerText;
        post({type: 'quote', text: text.trim()});
      }
    });
    window.ghtScrollTo = function (ids) {
      for (const id of ids) {
        const el = document.getElementById(id);
        if (el) { el.scrollIntoView({block: 'start'}); window.scrollBy(0, -12); return true; }
      }
      return false;
    };
    """

    static let css = """
    :root {
      color-scheme: light dark;
      --fg: #1f2328; --muted: #59636e; --border: #d1d9e0; --card: #ffffff; --header: #f6f8fa; --bg: transparent;
      --accent: #0969da; --open: #1a7f37; --done: #8250df; --closed: #cf222e; --code: rgba(129,139,152,0.12);
      --new: #0969da; --hl: rgba(84,174,255,0.08); --mark: #fff8c5;
    }
    @media (prefers-color-scheme: dark) {
      :root { --fg: #f0f6fc; --muted: #9198a1; --border: #3d444d; --card: #0d1117; --header: #151b23;
        --accent: #4493f8; --open: #3fb950; --done: #a371f7; --closed: #f85149; --code: rgba(101,108,118,0.2);
        --new: #4493f8; --hl: rgba(56,139,253,0.08); --mark: rgba(187,128,9,0.4); }
    }
    * { box-sizing: border-box; }
    html, body { margin: 0; background: var(--bg); color: var(--fg); }
    body { font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans", Helvetica, Arial, sans-serif; -webkit-font-smoothing: antialiased; }
    main { padding: 16px 18px 40px; max-width: 900px; }
    a { color: var(--accent); text-decoration: none; }
    a:hover { text-decoration: underline; }
    .item { display: flex; gap: 10px; margin: 0 0 14px; }
    .avatar { width: 32px; height: 32px; border-radius: 50%; flex: none; margin-top: 2px; background: var(--code); }
    .card { flex: 1; min-width: 0; border: 1px solid var(--border); border-radius: 8px; background: var(--card); overflow: hidden; }
    .card-header { display: flex; align-items: baseline; gap: 6px; flex-wrap: wrap; padding: 7px 12px; background: var(--header);
      border-bottom: 1px solid var(--border); color: var(--muted); font-size: 13px; }
    .card-header.small { border-top: 1px solid var(--border); padding: 5px 12px; }
    .opening .card-header { background: color-mix(in srgb, var(--accent) 7%, var(--header)); }
    .is-new .card { border-color: color-mix(in srgb, var(--new) 60%, var(--border)); box-shadow: 0 0 0 1px color-mix(in srgb, var(--new) 30%, transparent); }
    .author { color: var(--fg); font-weight: 600; }
    .time { color: var(--muted); }
    .badge { border: 1px solid var(--border); border-radius: 999px; padding: 0 7px; font-size: 11px; font-weight: 500; color: var(--muted); }
    .badge.answer { color: var(--open); border-color: var(--open); }
    .badge.pre { color: #9a6700; border-color: #d4a72c; vertical-align: middle; }
    .answer .card { border-color: var(--open); }
    .actions { margin-left: auto; display: flex; gap: 2px; opacity: 0; transition: opacity .12s; }
    .card:hover .actions { opacity: 1; }
    .act { border: 0; background: transparent; color: var(--muted); font-size: 14px; cursor: pointer; padding: 0 6px; border-radius: 4px; }
    .act:hover { background: var(--code); color: var(--fg); }
    .markdown-body { padding: 10px 14px; overflow-wrap: anywhere; }
    .markdown-body > :first-child { margin-top: 0 !important; }
    .markdown-body > :last-child { margin-bottom: 0 !important; }
    .markdown-body p, .markdown-body ul, .markdown-body ol, .markdown-body blockquote, .markdown-body pre, .markdown-body table, .markdown-body details { margin: 0 0 12px; }
    .markdown-body h1, .markdown-body h2, .markdown-body h3, .markdown-body h4 { margin: 18px 0 10px; line-height: 1.25; font-weight: 600; }
    .markdown-body h1 { font-size: 1.6em; } .markdown-body h2 { font-size: 1.35em; border-bottom: 1px solid var(--border); padding-bottom: .2em; } .markdown-body h3 { font-size: 1.15em; }
    .markdown-body ul, .markdown-body ol { padding-left: 2em; }
    .markdown-body li + li { margin-top: .2em; }
    .markdown-body blockquote { padding: 0 1em; color: var(--muted); border-left: .25em solid var(--border); }
    .markdown-body code, .markdown-body tt { font: 12px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--code); padding: .2em .4em; border-radius: 6px; }
    .markdown-body pre { background: var(--code); padding: 12px 14px; border-radius: 6px; overflow: auto; font: 12px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace; }
    .markdown-body pre code { background: transparent; padding: 0; font-size: 100%; white-space: pre; }
    .markdown-body .highlight { margin-bottom: 12px; } .markdown-body .highlight pre { margin: 0; }
    .markdown-body img { max-width: 100%; height: auto; border-radius: 4px; }
    .markdown-body table { border-collapse: collapse; display: block; overflow: auto; }
    .markdown-body th, .markdown-body td { border: 1px solid var(--border); padding: 5px 12px; }
    .markdown-body tr:nth-child(2n) { background: var(--code); }
    .markdown-body hr { border: 0; border-top: 1px solid var(--border); margin: 16px 0; }
    .markdown-body .task-list-item { list-style: none; } .markdown-body .task-list-item input { margin: 0 .3em 0 -1.4em; }
    .markdown-body .contains-task-list { padding-left: 1.6em; }
    .markdown-body details summary { cursor: pointer; }
    .markdown-body .user-mention, .markdown-body .team-mention { font-weight: 600; color: var(--fg); }
    .markdown-body .email-hidden-toggle, .markdown-body .email-hidden-reply { display: none; }
    .markdown-body .markdown-alert { padding: 4px 14px; border-left: .25em solid var(--border); margin-bottom: 12px; }
    .markdown-body .markdown-alert-note { border-color: var(--accent); } .markdown-body .markdown-alert-warning { border-color: #9a6700; }
    .markdown-body .markdown-alert-important { border-color: var(--done); } .markdown-body .markdown-alert-caution { border-color: var(--closed); }
    .markdown-body .markdown-alert-tip { border-color: var(--open); }
    .markdown-body .markdown-alert-title { font-weight: 600; display: flex; gap: 6px; align-items: center; }
    .markdown-body .markdown-alert-title svg { fill: currentColor; }
    .markdown-body svg.octicon { fill: currentColor; vertical-align: text-bottom; }
    .markdown-body .anchor { display: none; }
    .markdown-body mark { background: var(--mark); }
    .empty { color: var(--muted); font-style: italic; }
    .event { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; margin: 0 0 12px 18px; padding-left: 26px; position: relative;
      color: var(--muted); font-size: 13px; }
    .event::before { content: ''; position: absolute; left: -2px; top: -12px; bottom: -12px; border-left: 2px solid var(--border); z-index: -1; }
    .event-icon { position: absolute; left: -13px; width: 24px; height: 24px; border-radius: 50%; background: var(--header);
      border: 1px solid var(--border); display: grid; place-items: center; font-size: 12px; color: var(--muted); }
    .event-icon.done { background: var(--done); color: #fff; border-color: var(--done); }
    .event-icon.open, .event-icon.approved { background: var(--open); color: #fff; border-color: var(--open); }
    .event-icon.changes { background: var(--closed); color: #fff; border-color: var(--closed); }
    .event .author { font-weight: 600; }
    .event del { color: var(--muted); } .event ins { text-decoration: none; font-weight: 600; color: var(--fg); }
    .event code { font: 12px ui-monospace, Menlo, monospace; background: var(--code); padding: 1px 4px; border-radius: 4px; }
    .event.is-new .author::after { content: ' •'; color: var(--new); }
    .mini-avatar { width: 20px; height: 20px; border-radius: 50%; vertical-align: middle; }
    .dim { color: var(--muted); font-weight: normal; }
    .label { --label: #888; display: inline-block; padding: 0 7px; border-radius: 999px; font-size: 12px; font-weight: 500; color: var(--fg);
      background: color-mix(in srgb, var(--label) 22%, transparent); border: 1px solid color-mix(in srgb, var(--label) 55%, transparent); }
    .review-body { margin: -4px 0 14px 42px; display: flex; flex-direction: column; gap: 8px; }
    .review-comment .path { padding: 6px 12px; font: 12px ui-monospace, Menlo, monospace; background: var(--header); border-bottom: 1px solid var(--border); }
    .diff { font: 12px/1.5 ui-monospace, Menlo, monospace; white-space: pre; overflow-x: auto; border-bottom: 1px solid var(--border); }
    .diff div { padding: 0 12px; } .diff .add { background: rgba(46,160,67,.15); } .diff .del { background: rgba(248,81,73,.15); }
    .diff .hunk { color: var(--muted); background: var(--code); }
    .minimized { margin: 0 0 14px 42px; border: 1px solid var(--border); border-radius: 8px; padding: 8px 12px; color: var(--muted); }
    .minimized summary { cursor: pointer; }
    .hidden-items { text-align: center; margin: 0 0 14px 42px; padding: 6px; border: 1px dashed var(--border); border-radius: 8px; font-size: 13px; }
    .new-divider { display: flex; align-items: center; gap: 10px; margin: 6px 0 16px; color: var(--new); font-size: 12px; font-weight: 600; }
    .new-divider::before, .new-divider::after { content: ''; flex: 1; border-top: 1px solid var(--new); opacity: .6; }
    .reactions { display: flex; flex-wrap: wrap; gap: 6px; padding: 0 14px 10px; align-items: center; }
    .reaction { border: 1px solid var(--border); background: transparent; color: var(--fg); border-radius: 999px; padding: 1px 8px; font-size: 12px; cursor: pointer; }
    .reaction span { color: var(--muted); }
    .reaction.mine { background: color-mix(in srgb, var(--accent) 14%, transparent); border-color: var(--accent); }
    .reaction.mine span { color: var(--accent); }
    .reaction:hover { background: var(--code); }
    .add-reaction { position: relative; display: inline-flex; gap: 2px; }
    .reaction.add { opacity: 0; color: var(--muted); }
    .card:hover .reaction.add, .add-reaction.open .reaction.add { opacity: 1; }
    .picker { display: none; gap: 2px; margin-left: 4px; }
    .add-reaction.open .picker { display: inline-flex; }
    .reaction.pick { border-color: transparent; font-size: 15px; padding: 0 4px; }
    .replies { margin: -6px 0 14px 42px; padding-left: 12px; border-left: 2px solid var(--border); }
    .replies .avatar { width: 24px; height: 24px; }
    .category { color: var(--muted); font-size: 13px; margin-bottom: 10px; }
    .category .emoji, .category g-emoji { font-style: normal; }
    .release-title { margin: 0 0 12px; font-size: 20px; }
    """
}
