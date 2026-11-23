import AppKit
import Foundation
import Observation

struct Viewer: Sendable {
    var id: String
    var login: String
    var avatarUrl: String?
}

/// A done/unsubscribe waiting out its undo window.
struct PendingAction: Identifiable {
    enum Kind { case done, unsubscribe }
    let id = UUID()
    var kind: Kind
    var threadIDs: [String]
    var title: String
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var undoable: UUID?
    var isError = false
}

enum CloseReason: String, CaseIterable, Identifiable {
    case completed = "COMPLETED", notPlanned = "NOT_PLANNED", duplicate = "DUPLICATE"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .completed: "Close as completed"
        case .notPlanned: "Close as not planned"
        case .duplicate: "Close as duplicate"
        }
    }
}

enum TidyKind: CaseIterable, Identifiable {
    case finished, read, releases, bots, ci
    var id: Self { self }
    var label: String {
        switch self {
        case .finished: "Closed & merged"
        case .read: "Everything read"
        case .releases: "Releases"
        case .bots: "Bot activity"
        case .ci: "CI & checks"
        }
    }
    var symbol: String {
        switch self {
        case .finished: "checkmark.seal"
        case .read: "envelope.open"
        case .releases: "tag"
        case .bots: "cpu"
        case .ci: "gearshape.2"
        }
    }
}

@Observable
final class InboxStore {
    enum Auth: Equatable { case checking, signedOut(String?), signedIn }

    enum Scope: String, CaseIterable, Identifiable {
        case inbox, unread, saved, snoozed, done
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .inbox: "tray"
            case .unread: "circle.fill"
            case .saved: "bookmark"
            case .snoozed: "moon.zzz"
            case .done: "checkmark.circle"
            }
        }
    }

    enum QuickFilter: Hashable, Identifiable {
        case all, participating, mentioned, assigned, reviewRequested, teamMentioned, custom(UUID)
        var id: Self { self }
        static let builtIn: [QuickFilter] = [.all, .participating, .mentioned, .assigned, .reviewRequested, .teamMentioned]
        var label: String {
            switch self {
            case .all: "All"
            case .participating: "Participating"
            case .mentioned: "Mentioned"
            case .assigned: "Assigned"
            case .reviewRequested: "Review requested"
            case .teamMentioned: "Team mentioned"
            case .custom: "Custom"
            }
        }
        var query: String? {
            switch self {
            case .all: nil
            case .participating: "reason:participating"
            case .mentioned: "reason:mention"
            case .assigned: "reason:assign"
            case .reviewRequested: "reason:review_requested"
            case .teamMentioned: "reason:team_mention"
            case .custom: nil
            }
        }
    }

    let prefs = Preferences.shared

    var auth: Auth = .checking
    var viewer: Viewer?
    var tokenSource: TokenSource?
    var notifications: [GHNotification] = []
    /// Threads marked done, newest activity first. Fetched while the Done tab is open, or while a thread
    /// moved back to the inbox needs it. Threads in `local.restored` show in the inbox instead.
    var done: [GHNotification] = []
    var info: [String: SubjectInfo] = [:]
    var local = LocalState.load() { didSet { local.save() } }
    var hidden: Set<String> = []
    var pending: [PendingAction] = []
    var toast: Toast?
    var isRefreshing = false
    var lastRefreshed: Date?
    var lastError: String?
    var now = Date()

    var scope: Scope = .inbox {
        didSet {
            guard scope != oldValue else { return }
            // Done lists different threads from the other tabs, so the open thread and the selection
            // don't carry across: e must never act on a thread that isn't in the list on screen.
            if (scope == .done) != (oldValue == .done) {
                let wantDone = scope == .done
                if let f = focused, isDone(f) != wantDone { focused = nil }
                selection = selection.filter { isDone($0) == wantDone }
            }
            if scope == .done { Task { await refreshDone() } }
        }
    }
    var quickFilter: QuickFilter = .all
    var search = ""
    var selection: Set<String> = []
    var focused: String?

    var details: [String: ThreadDetail] = [:]
    var detailLoading: Set<String> = []
    var detailErrors: [String: String] = [:]
    var repoLabels: [String: [GQLLabel]] = [:]
    var busy: Set<String> = []  // thread ids with a mutation in flight

    var drafts: [String: String] = [:]
    /// Each thread's `last_read_at` as it was when it was opened, for the "New since you last read" divider.
    var readMarkers: [String: Date?] = [:]

    /// Bumped to ask the UI to put the cursor in the reply box.
    var replyFocusRequest = 0

    private(set) var client: GitHubClient?
    private var infoRevision: [String: String] = [:]
    /// The notification revision each cached detail was loaded at.
    private var detailRevision: [String: String] = [:]
    /// Bumped on sign-in and sign-out, so replies to requests made for another account are dropped.
    private var session = 0
    /// The thread ids GitHub listed in the inbox on the last full fetch (without restored threads),
    /// and whether that list was complete.
    private var inboxIDs: Set<String> = []
    private var inboxComplete = false
    /// Done/unsubscribe requests on the wire right now (quit waits for them).
    private(set) var committing = 0
    private var lastModified: String?
    private var doneLastModified: String?
    private var pollInterval = 60
    private var pollTask: Task<Void, Never>?
    private var pendingTasks: [UUID: Task<Void, Never>] = [:]
    private var announced: [String: Date] = [:]
    private var seeded = false

    // MARK: Lifecycle

    func start() {
        Task { await signIn() }
    }

    func signIn(token explicit: String? = nil) async {
        auth = .checking
        if let explicit {
            TokenProvider.save(explicit)
        }
        guard let resolved = await TokenProvider.resolve() else {
            auth = .signedOut(nil)
            return
        }
        let client = GitHubClient(token: resolved.token)
        do {
            nonisolated struct V: Decodable, Sendable { nonisolated struct U: Decodable, Sendable { var id: String; var login: String; var avatarUrl: String? }; var viewer: U }
            let v = try await client.graphQL(Queries.viewer, as: V.self)
            viewer = Viewer(id: v.viewer.id, login: v.viewer.login, avatarUrl: v.viewer.avatarUrl)
            self.client = client
            session += 1
            tokenSource = resolved.source
            auth = .signedIn
            startPolling()
        } catch {
            if explicit != nil { TokenProvider.delete() }
            auth = .signedOut(error.localizedDescription)
        }
    }

    func signOut() {
        pollTask?.cancel()
        session += 1
        // Anything still waiting out its undo window belongs to this account: drop it, don't send it later.
        for task in pendingTasks.values { task.cancel() }
        pendingTasks = [:]
        pending = []
        hidden = []
        toast = nil
        focused = nil
        selection = []
        drafts = [:]
        readMarkers = [:]
        detailRevision = [:]
        TokenProvider.delete()
        client = nil
        viewer = nil
        notifications = []
        done = []
        doneLastModified = nil
        inboxIDs = []
        inboxComplete = false
        detailLoading = []
        info = [:]
        infoRevision = [:]
        details = [:]
        lastModified = nil
        seeded = false
        auth = .signedOut(tokenSource == .githubCLI ? "Signed out. Triage will use the GitHub CLI's login again on next launch unless you paste a token." : nil)
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let wait = max(self.pollInterval, 60)
                try? await Task.sleep(for: .seconds(wait))
                self.now = Date()
            }
        }
    }

    /// Polls GitHub. Unchanged polls (304) don't count against the rate limit.
    func refresh(force: Bool = false) async {
        guard let client, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        now = Date()
        let session = self.session
        do {
            let result = try await client.notifications(ifModifiedSince: force ? nil : lastModified)
            guard session == self.session else { return }
            switch result {
            case .notModified(let interval):
                pollInterval = interval
            case .updated(let list, let lastModified, let interval, let complete):
                pollInterval = interval
                self.lastModified = lastModified
                apply(list, complete: complete)
                await enrich()
                prefetch(notifications.lazy.filter { !self.isSnoozed($0) }.prefix(Self.prefetchCount).map(\.id))
            }
            guard session == self.session else { return }
            if scope == .done || !local.restored.isEmpty { await refreshDone() }
            lastRefreshed = Date()
            lastError = nil
        } catch {
            guard session == self.session else { return }
            lastError = error.localizedDescription
        }
    }

    /// Fetches the done threads (the most recent 200). An unchanged list (304) is free.
    func refreshDone() async {
        guard let client else { return }
        let session = self.session
        do {
            let result = try await client.notifications(done: true, ifModifiedSince: doneLastModified, maxPages: 4)
            guard session == self.session, case .updated(let list, let lastModified, _, let complete) = result else { return }
            doneLastModified = lastModified
            done = list.filter { !inboxIDs.contains($0.id) }.sorted { $0.updatedAt > $1.updatedAt }
            // A thread restored by an older build has no stored record yet: take it from here.
            var missing: [GHNotification] = []
            for n in done where local.restored.contains(n.id) {
                if local.restoredThreads[n.id] == nil { local.restoredThreads[n.id] = n }
                if !notifications.contains(where: { $0.id == n.id }) { missing.append(n) }
            }
            if !missing.isEmpty { notifications = (notifications + missing).sorted { $0.updatedAt > $1.updatedAt } }
            // A restored thread GitHub lists nowhere any more (deleted, or the repo is gone) is finished.
            if complete, inboxComplete {
                let known = Set(list.map(\.id))
                let gone = local.restored.filter { !known.contains($0) && !inboxIDs.contains($0) }
                if !gone.isEmpty {
                    local.restored.subtract(gone)
                    notifications.removeAll { gone.contains($0.id) }
                }
            }
            await enrich()
        } catch {
            guard session == self.session else { return }
            lastError = error.localizedDescription
        }
    }

    private func apply(_ list: [GHNotification], complete: Bool) {
        // New activity puts a thread back in GitHub's own inbox, so it no longer needs restoring.
        let inbox = Set(list.map(\.id))
        inboxIDs = inbox
        inboxComplete = complete
        if !local.restored.isDisjoint(with: inbox) { local.restored.subtract(inbox) }
        // The same goes for the Done tab: a thread can't be in both.
        if done.contains(where: { inbox.contains($0.id) }) { done.removeAll { inbox.contains($0.id) } }
        // Restored threads come from the stored record, so they survive a relaunch and dropping out of
        // the done list; the copy already in the list wins, since it carries reads made here.
        let restored = local.restored.compactMap { id in
            notifications.first { $0.id == id } ?? done.first { $0.id == id } ?? local.restoredThreads[id]
        }
        let merged = list + restored
        let ids = Set(merged.map(\.id))
        var fresh = merged.sorted { $0.updatedAt > $1.updatedAt }
        // GitHub reports these as read; the app keeps them unread until they're opened or read here.
        for i in fresh.indices where local.markedUnread.contains(fresh[i].id) { fresh[i].unread = true }
        if complete, !local.markedUnread.isSubset(of: ids) { local.markedUnread.formIntersection(ids) }
        notifications = fresh
        selection = selection.intersection(ids.union(done.map(\.id)))
        // A detail cached for an older revision is stale; the open one reloads in place.
        for n in fresh where details[n.id] != nil && detailRevision[n.id] != n.revisionKey {
            if n.id == focused {
                Task { await loadDetail(n.id, force: true) }
            } else {
                details[n.id] = nil
            }
        }
        // Snoozes for threads that left the inbox, or woke up on new activity, are finished.
        // A capped (incomplete) list can't tell us a thread left, so only wake-ups count then.
        let stale = local.snoozed.filter { id, s in
            guard let n = fresh.first(where: { $0.id == id }) else { return complete }
            return n.updatedAt > s.updatedAt
        }
        if !stale.isEmpty { for id in stale.keys { local.snoozed[id] = nil } }
        announce(fresh)
    }

    /// Fetches state, author and labels for every issue, PR and discussion that changed, in one request per 40.
    private func enrich() async {
        guard let client else { return }
        let session = self.session
        let todo = (notifications + done).filter { n in
            n.number != nil && infoRevision[n.id] != n.revisionKey && (n.kind == .issue || n.kind == .pullRequest || n.kind == .discussion)
        }
        guard !todo.isEmpty else { return }
        nonisolated struct AliasRepo: Decodable, Sendable { var issueOrPullRequest: GQLSubject?; var discussion: GQLSubject? }
        for chunk in stride(from: 0, to: todo.count, by: 40).map({ Array(todo[$0..<min($0 + 40, todo.count)]) }) {
            let items = chunk.enumerated().map { i, n in
                (alias: "t\(i)", owner: n.owner, name: n.repoName, number: n.number!, discussion: n.kind == .discussion)
            }
            do {
                let data = try await client.graphQL(Queries.batch(items), as: [String: AliasRepo?].self, allowPartial: true)
                guard session == self.session else { return }
                for (i, n) in chunk.enumerated() {
                    guard let repo = data["t\(i)"] ?? nil, let s = repo.issueOrPullRequest ?? repo.discussion else { continue }
                    info[n.id] = SubjectInfo(s)
                    infoRevision[n.id] = n.revisionKey
                }
            } catch {
                NSLog("Enrichment failed: \(error)")
            }
        }
    }

    // MARK: Desktop notifications

    private func announce(_ list: [GHNotification]) {
        defer { seeded = true }
        var fresh: [GHNotification] = []
        for n in list where n.unread {
            if let seen = announced[n.id], seen >= n.updatedAt { continue }
            announced[n.id] = n.updatedAt
            if seeded { fresh.append(n) }
        }
        guard prefs.desktopNotifications, !fresh.isEmpty else { return }
        let wanted = fresh.filter { prefs.notifyReasons.contains($0.reason) && !isSnoozed($0) }
        Notifier.shared.post(wanted)
    }

    // MARK: Filtering

    func isSnoozed(_ n: GHNotification) -> Bool {
        guard let s = local.snoozed[n.id] else { return false }
        return s.until > now && n.updatedAt <= s.updatedAt
    }

    func facts(_ n: GHNotification) -> InboxQuery.Facts {
        let i = info[n.id]
        return InboxQuery.Facts(
            title: n.subject.title, repo: n.repository.fullName, owner: n.owner, reason: n.reason, kind: n.kind,
            unread: n.unread, state: i?.state, author: i?.author?.login, authorIsBot: i?.author?.isBot ?? false,
            labels: i?.labels.map(\.name) ?? [], saved: local.saved.contains(n.id), snoozed: isSnoozed(n))
    }

    var activeQuery: InboxQuery {
        var parts: [String] = []
        if case .custom(let id) = quickFilter, let f = local.filters.first(where: { $0.id == id }) { parts.append(f.query) }
        if let q = quickFilter.query { parts.append(q) }
        parts.append(search)
        return InboxQuery(parts.joined(separator: " "))
    }

    private func inScope(_ n: GHNotification, _ scope: Scope) -> Bool {
        if hidden.contains(n.id) { return false }
        switch scope {
        case .inbox: return !isSnoozed(n)
        case .unread: return n.unread && !isSnoozed(n)
        case .saved: return local.saved.contains(n.id)
        case .snoozed: return isSnoozed(n)
        case .done: return !local.restored.contains(n.id)
        }
    }

    /// The list a scope draws from: the done threads for Done, the inbox for the rest.
    private func source(_ scope: Scope) -> [GHNotification] { scope == .done ? done : notifications }

    /// True for a thread that's done (not in the inbox), so the UI offers Move to Inbox instead of Done.
    func isDone(_ id: String) -> Bool {
        !notifications.contains { $0.id == id } && done.contains { $0.id == id }
    }

    var visible: [GHNotification] {
        let q = activeQuery
        // The open thread stays put even if it stops matching (Unread, once it's read), so j/k and Done keep their place.
        return source(scope).filter { n in
            (n.id == focused && !hidden.contains(n.id)) || (inScope(n, scope) && (q.isEmpty || q.matches(facts(n))))
        }
    }

    func count(_ scope: Scope) -> Int { source(scope).count { inScope($0, scope) } }

    func count(_ filter: QuickFilter) -> Int {
        var parts: [String] = []
        if case .custom(let id) = filter, let f = local.filters.first(where: { $0.id == id }) { parts.append(f.query) }
        if let q = filter.query { parts.append(q) }
        let q = InboxQuery(parts.joined(separator: " "))
        return source(scope).count { inScope($0, scope) && (q.isEmpty || q.matches(facts($0))) }
    }

    var badgeCount: Int {
        notifications.count { !hidden.contains($0.id) && !isSnoozed($0) && (!prefs.badgeUnreadOnly || $0.unread) }
    }

    var repositories: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for n in source(scope) where inScope(n, scope) { counts[n.repository.fullName, default: 0] += 1 }
        return counts.map { ($0.key, $0.value) }.sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
    }

    struct Group: Identifiable {
        var id: String
        var title: String
        var items: [GHNotification]
    }

    var groups: [Group] {
        let items = visible
        switch prefs.groupBy {
        case .none:
            return [Group(id: "all", title: "", items: items)]
        case .repository:
            var order: [String] = []
            var map: [String: [GHNotification]] = [:]
            for n in items {
                let key = n.repository.fullName
                if map[key] == nil { order.append(key) }
                map[key, default: []].append(n)
            }
            return order.map { Group(id: $0, title: $0, items: map[$0]!) }
        case .date:
            let cal = Calendar.current
            var order: [String] = []
            var map: [String: [GHNotification]] = [:]
            for n in items {
                let key: String
                if cal.isDateInToday(n.updatedAt) { key = "Today" }
                else if cal.isDateInYesterday(n.updatedAt) { key = "Yesterday" }
                else if let days = cal.dateComponents([.day], from: n.updatedAt, to: now).day, days < 7 { key = "This week" }
                else if let days = cal.dateComponents([.day], from: n.updatedAt, to: now).day, days < 31 { key = "This month" }
                else { key = "Older" }
                if map[key] == nil { order.append(key) }
                map[key, default: []].append(n)
            }
            return order.map { Group(id: $0, title: $0, items: map[$0]!) }
        }
    }

    /// The flat order the list shows, for keyboard navigation.
    var orderedIDs: [String] { groups.flatMap { $0.items.map(\.id) } }

    func notification(_ id: String?) -> GHNotification? {
        guard let id else { return nil }
        return notifications.first { $0.id == id } ?? done.first { $0.id == id }
    }

    func webURL(_ n: GHNotification) -> URL {
        if let html = info[n.id]?.htmlURL, var comps = URLComponents(string: html) {
            comps.queryItems = [URLQueryItem(name: "notification_referrer_id", value: "NT_\(n.id)")]
            if let anchor = n.latestCommentAnchor, n.kind == .issue || n.kind == .pullRequest { comps.fragment = anchor }
            if let url = comps.url { return url }
        }
        return n.webURL
    }

    func tidyCandidates(_ kind: TidyKind) -> [String] {
        notifications.filter { n in
            guard inScope(n, .inbox) || inScope(n, .snoozed) else { return false }
            switch kind {
            case .finished: return info[n.id]?.state.isFinished == true
            case .read: return !n.unread
            case .releases: return n.kind == .release
            case .bots: return info[n.id]?.author?.isBot == true || n.reason == "ci_activity"
            case .ci: return n.kind == .checkSuite || n.kind == .workflowRun || n.reason == "ci_activity"
            }
        }.map(\.id)
    }

    // MARK: Selection & navigation

    /// The threads an action applies to: the multi-selection, else the open thread.
    var targets: [String] {
        if selection.count > 1 { return orderedIDs.filter { selection.contains($0) } }
        // Only threads that belong to the tab on screen: e in Done must never mark an inbox thread done.
        let wantDone = scope == .done
        if let focused { return isDone(focused) == wantDone ? [focused] : [] }
        return selection.filter { isDone($0) == wantDone }
    }

    func open(_ id: String) {
        if focused != id { readMarkers[id] = notification(id)?.lastReadAt }
        focused = id
        selection = [id]
        Task { await loadDetail(id) }
        let ids = orderedIDs
        if let i = ids.firstIndex(of: id) { prefetch([i + 1, i - 1].filter(ids.indices.contains).map { ids[$0] }) }
        if prefs.markReadOnOpen, let n = notification(id), n.unread { markRead([id]) }
    }

    func move(_ delta: Int) {
        let ids = orderedIDs
        guard !ids.isEmpty else { return }
        let current = focused ?? selection.first
        let index = current.flatMap { ids.firstIndex(of: $0) } ?? (delta > 0 ? -1 : ids.count)
        let next = min(max(index + delta, 0), ids.count - 1)
        if focused != nil { open(ids[next]) } else { selection = [ids[next]] }
    }

    func closeDetail() { focused = nil }

    /// A github.com link to an issue, PR or discussion that's in the inbox opens here instead of the browser.
    func openInApp(_ url: URL) -> Bool {
        guard url.host == "github.com" else { return false }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 4, let number = Int(parts[3]), ["issues", "pull", "discussions"].contains(parts[2]) else { return false }
        let repo = "\(parts[0])/\(parts[1])".lowercased()
        guard let n = notifications.first(where: { $0.repository.fullName.lowercased() == repo && $0.number == number && !hidden.contains($0.id) })
        else { return false }
        open(n.id)
        return true
    }

    /// Before hiding `ids`, pick what to show next so triage can keep moving.
    private func advance(past ids: [String]) {
        let order = orderedIDs
        guard let focused, ids.contains(focused) else {
            selection.subtract(ids)
            return
        }
        guard prefs.advanceAfterAction else {
            self.focused = nil
            selection = []
            return
        }
        let idx = order.firstIndex(of: focused) ?? 0
        let remaining = order.filter { !ids.contains($0) }
        let after = order[idx...].first { !ids.contains($0) } ?? remaining.last
        selection = []
        if let after { open(after) } else { self.focused = nil }
    }

    // MARK: Inbox actions

    func markDone(_ ids: [String]) { queue(.done, ids.filter { !isDone($0) }) }

    /// App-only: GitHub's API has no "move to inbox", so on github.com the thread stays done. It shows in
    /// the inbox here until it's marked done again, or new activity puts it back in GitHub's inbox anyway.
    func moveToInbox(_ ids: [String]) {
        let list = ids.filter(isDone).compactMap { id in done.first { $0.id == id } }
        guard !list.isEmpty else { return }
        advance(past: list.map(\.id))
        local.restored.formUnion(list.map(\.id))
        for n in list { local.restoredThreads[n.id] = n }
        notifications = (notifications + list).sorted { $0.updatedAt > $1.updatedAt }
        let noun = list.count == 1 ? "1 notification" : "\(list.count) notifications"
        toast = Toast(message: "Moved \(noun) to the inbox (in this app only)")
    }

    /// e in the Done tab moves the thread back; everywhere else it marks it done.
    func toggleDone(_ ids: [String]) {
        if !ids.isEmpty, ids.allSatisfy(isDone) { moveToInbox(ids) } else { markDone(ids) }
    }
    func unsubscribe(_ ids: [String]) { queue(.unsubscribe, ids) }

    private func queue(_ kind: PendingAction.Kind, _ ids: [String]) {
        let ids = ids.filter { !hidden.contains($0) }
        guard !ids.isEmpty else { return }
        advance(past: ids)
        hidden.formUnion(ids)
        let noun = ids.count == 1 ? "1 notification" : "\(ids.count) notifications"
        let title = kind == .done ? "Marked \(noun) as done" : "Unsubscribed from \(noun)"
        let action = PendingAction(kind: kind, threadIDs: ids, title: title)
        pending.append(action)
        let delay = prefs.undoSeconds
        pendingTasks[action.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.commit(action.id)
        }
    }

    func undo(_ actionID: UUID? = nil) {
        guard let action = actionID.flatMap({ id in pending.first { $0.id == id } }) ?? pending.last else { return }
        pendingTasks[action.id]?.cancel()
        pendingTasks[action.id] = nil
        pending.removeAll { $0.id == action.id }
        hidden.subtract(action.threadIDs)
        if action.threadIDs.count == 1 {
            let id = action.threadIDs[0]
            if scope == .done, !isDone(id) { scope = .inbox }
            open(id)
        }
    }

    private func commit(_ actionID: UUID) async {
        guard let index = pending.firstIndex(where: { $0.id == actionID }), let client else { return }
        let action = pending.remove(at: index)
        pendingTasks[actionID] = nil
        committing += 1
        defer { committing -= 1 }
        var failed: [String] = []
        let unsubscribing = action.kind == .unsubscribe
        await withTaskGroup(of: (String, Bool).self) { group in
            for id in action.threadIDs {
                group.addTask {
                    do {
                        if unsubscribing { try await client.unsubscribe(thread: id) }
                        try await client.markDone(thread: id)
                        return (id, true)
                    } catch {
                        return (id, false)
                    }
                }
            }
            for await (id, ok) in group where !ok { failed.append(id) }
        }
        let finished = Set(action.threadIDs).subtracting(failed)
        // They show in the Done tab straight away, without waiting for its next fetch.
        let moved = finished.compactMap { id in notifications.first { $0.id == id } ?? done.first { $0.id == id } }
        done = (moved + done.filter { !finished.contains($0.id) }).sorted { $0.updatedAt > $1.updatedAt }
        notifications.removeAll { finished.contains($0.id) }
        hidden.subtract(action.threadIDs)
        if !local.restored.isDisjoint(with: finished) { local.restored.subtract(finished) }
        // It has left GitHub's inbox too, so the next Done fetch keeps it.
        inboxIDs.subtract(finished)
        for id in finished {
            local.saved.remove(id)
            local.snoozed[id] = nil
            details[id] = nil
        }
        if !failed.isEmpty {
            toast = Toast(message: "Couldn't update \(failed.count) notification\(failed.count == 1 ? "" : "s"). They're back in the list.", isError: true)
        }
    }

    /// Sends every waiting done/unsubscribe now (on quit).
    func flushPending() async {
        for action in pending {
            pendingTasks[action.id]?.cancel()
            await commit(action.id)
        }
        while committing > 0 { try? await Task.sleep(for: .milliseconds(100)) }
    }

    func markRead(_ ids: [String]) {
        guard let client else { return }
        if !local.markedUnread.isDisjoint(with: ids) { local.markedUnread.subtract(ids) }
        // A restored thread's stored record is what the inbox shows after a relaunch.
        let stale = ids.filter { local.restoredThreads[$0]?.unread == true }
        if !stale.isEmpty { for id in stale { local.restoredThreads[id]?.unread = false } }
        for id in ids {
            // A done thread can still be unread (done straight from the list); reading it there clears that too.
            if let d = done.firstIndex(where: { $0.id == id }), done[d].unread {
                done[d].unread = false
                if !notifications.contains(where: { $0.id == id }) { Task { try? await client.markRead(thread: id) } }
            }
            guard let i = notifications.firstIndex(where: { $0.id == id }), notifications[i].unread else { continue }
            notifications[i].unread = false
            Notifier.shared.remove(threadID: id)
            Task {
                do { try await client.markRead(thread: id) } catch {
                    if let j = notifications.firstIndex(where: { $0.id == id }) { notifications[j].unread = true }
                }
            }
        }
    }

    /// App-only: GitHub's API has no way to mark a thread unread, so github.com keeps showing it as read.
    func markUnread(_ ids: [String]) {
        for id in ids {
            guard let i = notifications.firstIndex(where: { $0.id == id }), !notifications[i].unread else { continue }
            notifications[i].unread = true
            local.markedUnread.insert(id)
        }
    }

    /// Read if any of them is unread, otherwise unread.
    func toggleRead(_ ids: [String]) {
        if ids.contains(where: { notification($0)?.unread == true }) { markRead(ids) } else { markUnread(ids) }
    }

    func markAllRead() {
        guard let client else { return }
        if !local.markedUnread.isEmpty { local.markedUnread = [] }
        let stamp = Date()
        let wasUnread = Set(notifications.filter(\.unread).map(\.id))
        for i in notifications.indices { notifications[i].unread = false }
        if local.restoredThreads.values.contains(where: \.unread) {
            local.restoredThreads = local.restoredThreads.mapValues { var n = $0; n.unread = false; return n }
        }
        Notifier.shared.removeAll()
        Task {
            do { try await client.markAllRead(before: stamp) } catch {
                for i in notifications.indices where wasUnread.contains(notifications[i].id) { notifications[i].unread = true }
                lastModified = nil  // the next poll fetches the real state
                showError(error)
            }
        }
    }

    func toggleSaved(_ ids: [String]) {
        // Saved and Snoozed list inbox threads; move a done thread to the inbox first.
        let ids = ids.filter { !isDone($0) }
        guard !ids.isEmpty else { return }
        let allSaved = ids.allSatisfy { local.saved.contains($0) }
        for id in ids { if allSaved { local.saved.remove(id) } else { local.saved.insert(id) } }
        toast = Toast(message: allSaved ? "Removed from Saved" : "Saved")
    }

    func snooze(_ ids: [String], until: Date) {
        let list = ids.filter { !isDone($0) }.compactMap { notification($0) }
        guard !list.isEmpty else { return }
        if scope != .snoozed { advance(past: ids) }
        for n in list { local.snoozed[n.id] = LocalState.Snooze(until: until, updatedAt: n.updatedAt) }
        let when = until.formatted(.relative(presentation: .named))
        toast = Toast(message: "Snoozed until \(until.formatted(date: .abbreviated, time: .shortened)) (\(when))")
    }

    func unsnooze(_ ids: [String]) {
        for id in ids { local.snoozed[id] = nil }
    }

    static func snoozeOptions(from now: Date = Date()) -> [(label: String, date: Date)] {
        let cal = Calendar.current
        let tonight = cal.date(bySettingHour: 18, minute: 0, second: 0, of: now)!
        let tomorrow = cal.date(bySettingHour: 9, minute: 0, second: 0, of: cal.date(byAdding: .day, value: 1, to: now)!)!
        var monday = cal.nextDate(after: now, matching: DateComponents(hour: 9, minute: 0, weekday: 2), matchingPolicy: .nextTime)!
        if cal.isDateInToday(monday) { monday = cal.date(byAdding: .day, value: 7, to: monday)! }
        var out: [(String, Date)] = [("In 1 hour", now.addingTimeInterval(3600)), ("In 3 hours", now.addingTimeInterval(3 * 3600))]
        if tonight > now.addingTimeInterval(3600) { out.append(("This evening", tonight)) }
        out.append(("Tomorrow morning", tomorrow))
        out.append(("Next week", monday))
        out.append(("In a month", cal.date(byAdding: .month, value: 1, to: now)!))
        return out
    }

    func showError(_ error: Error) {
        toast = Toast(message: error.localizedDescription, isError: true)
    }

    // MARK: Detail

    /// How many of the newest inbox threads get their conversation fetched after each refresh.
    static let prefetchCount = 25

    /// Fetches conversations ahead of time, four at a time, so opening a thread doesn't wait on GitHub:
    /// the newest inbox threads after each refresh, and the threads either side of the open one (for j and k).
    /// Changed threads drop their cached conversation in `apply`, so this fetches only what's new.
    private func prefetch(_ ids: [String]) {
        let todo = ids.filter { details[$0] == nil && !detailLoading.contains($0) }
        guard !todo.isEmpty else { return }
        Task {
            await withTaskGroup(of: Void.self) { group in
                var queue = todo.makeIterator()
                for _ in 0..<4 {
                    if let id = queue.next() { group.addTask { await self.loadDetail(id, quiet: true) } }
                }
                while await group.next() != nil {
                    if let id = queue.next() { group.addTask { await self.loadDetail(id, quiet: true) } }
                }
            }
        }
    }

    /// `quiet` is for prefetching: a failure isn't shown, and opening the thread tries again.
    func loadDetail(_ id: String, force: Bool = false, quiet: Bool = false) async {
        guard let client, let n = notification(id) else { return }
        if !force, details[id] != nil { return }
        guard !detailLoading.contains(id) else { return }
        let session = self.session
        detailLoading.insert(id)
        detailErrors[id] = nil
        defer { if session == self.session { detailLoading.remove(id) } }
        do {
            let detail: ThreadDetail
            var subject: SubjectInfo?
            switch n.kind {
            case .issue, .pullRequest:
                guard let number = n.number else { detail = .unsupported; break }
                nonisolated struct R: Decodable, Sendable { nonisolated struct Repo: Decodable, Sendable { var issueOrPullRequest: GQLSubject? }; var repository: Repo? }
                let r = try await client.graphQL(Queries.detail, variables: ["owner": n.owner, "name": n.repoName, "number": number], as: R.self)
                guard let s = r.repository?.issueOrPullRequest else { throw GitHubError.graphQL(["This thread is no longer available."]) }
                detail = .conversation(s)
                subject = SubjectInfo(s)
            case .discussion:
                let number = try await discussionNumber(n)
                nonisolated struct R: Decodable, Sendable { nonisolated struct Repo: Decodable, Sendable { var discussion: GQLSubject? }; var repository: Repo? }
                let r = try await client.graphQL(Queries.discussionDetail, variables: ["owner": n.owner, "name": n.repoName, "number": number], as: R.self)
                guard let s = r.repository?.discussion else { throw GitHubError.graphQL(["This discussion is no longer available."]) }
                detail = .conversation(s)
                subject = SubjectInfo(s)
            case .release:
                guard let url = n.subject.url else { detail = .unsupported; break }
                let release = try await client.release(apiURL: url)
                detail = .release(release)
                subject = SubjectInfo(release: release)
            default:
                detail = .unsupported
            }
            // Signed out meanwhile, or the thread changed while this was in flight: an old revision isn't cached.
            guard session == self.session else { return }
            guard notification(id)?.revisionKey == n.revisionKey else {
                if focused == id { Task { await loadDetail(id, force: true) } }
                return
            }
            if let subject {
                info[id] = subject
                if n.kind != .release { infoRevision[id] = n.revisionKey }
            }
            details[id] = detail
            detailRevision[id] = n.revisionKey
        } catch {
            // Moving to another thread cancels the fetch; that isn't worth an error page.
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            guard session == self.session else { return }
            // A prefetch fails quietly, unless the thread was opened meanwhile: then the pane shows it.
            if !quiet || focused == id { detailErrors[id] = error.localizedDescription }
        }
    }

    private func discussionNumber(_ n: GHNotification) async throws -> Int {
        if let number = n.number { return number }
        guard let client else { throw GitHubError.noToken }
        nonisolated struct R: Decodable, Sendable { nonisolated struct S: Decodable, Sendable { nonisolated struct N: Decodable, Sendable { var number: Int?; var title: String? }; var nodes: [N] }; var search: S }
        let q = "repo:\(n.repository.fullName) in:title \"\(n.subject.title.replacingOccurrences(of: "\"", with: ""))\""
        let r = try await client.graphQL(Queries.findDiscussion, variables: ["q": q], as: R.self)
        // Only an exact, unambiguous title match: a reply must never land on a different discussion.
        let hits = r.search.nodes.filter { $0.title == n.subject.title && $0.number != nil }
        guard hits.count == 1, let num = hits[0].number else {
            throw GitHubError.graphQL(["Couldn't identify this discussion for certain. Open it on GitHub instead."])
        }
        return num
    }

    // MARK: Conversation actions

    private func perform(_ id: String, success: String? = nil, _ work: @escaping (GitHubClient) async throws -> Void) async -> Bool {
        guard let client, !busy.contains(id) else { return false }
        busy.insert(id)
        defer { busy.remove(id) }
        do {
            try await work(client)
            if let success { toast = Toast(message: success) }
            await loadDetail(id, force: true)
            return true
        } catch {
            showError(error)
            return false
        }
    }

    /// Posts a reply, optionally closing (or reopening) in the same step like GitHub's "Close with comment".
    @discardableResult
    func reply(_ id: String, body: String, then stateChange: StateChange? = nil) async -> Bool {
        guard let s = details[id]?.subject, let subjectID = s.id else { return false }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let isDiscussion = s.__typename == "Discussion"
        return await perform(id, success: text.isEmpty ? nil : "Comment posted") { client in
            if !text.isEmpty {
                if isDiscussion {
                    try await client.mutate(Queries.addDiscussionComment, variables: ["id": subjectID, "body": text, "replyTo": nil])
                } else {
                    try await client.mutate(Queries.addComment, variables: ["id": subjectID, "body": text])
                }
            }
            if let stateChange { try await Self.apply(stateChange, to: s, client: client) }
        }
    }

    enum StateChange: Equatable {
        case close(CloseReason)
        case reopen
    }

    private static func apply(_ change: StateChange, to s: GQLSubject, client: GitHubClient) async throws {
        guard let id = s.id else { return }
        switch (s.__typename, change) {
        case ("Issue", .close(let reason)):
            try await client.mutate(Queries.closeIssue, variables: ["id": id, "reason": reason.rawValue])
        case ("Issue", .reopen):
            try await client.mutate(Queries.reopenIssue, variables: ["id": id])
        case ("PullRequest", .close):
            try await client.mutate(Queries.closePR, variables: ["id": id])
        case ("PullRequest", .reopen):
            try await client.mutate(Queries.reopenPR, variables: ["id": id])
        case ("Discussion", .close):
            try await client.mutate(Queries.closeDiscussion, variables: ["id": id])
        case ("Discussion", .reopen):
            try await client.mutate(Queries.reopenDiscussion, variables: ["id": id])
        default:
            break
        }
    }

    func setState(_ id: String, _ change: StateChange) async {
        guard let s = details[id]?.subject else { return }
        let message: String = switch change {
        case .reopen: "Reopened"
        case .close(.completed): "Closed"
        case .close(let r): r.label.replacingOccurrences(of: "Close", with: "Closed")
        }
        _ = await perform(id, success: message) { client in try await Self.apply(change, to: s, client: client) }
    }

    func merge(_ id: String, method: String) async {
        guard let pr = details[id]?.subject?.id else { return }
        _ = await perform(id, success: "Merged") { client in
            try await client.mutate(Queries.mergePR, variables: ["id": pr, "method": method])
        }
    }

    func review(_ id: String, event: String, body: String) async -> Bool {
        guard let pr = details[id]?.subject?.id else { return false }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = event == "APPROVE" ? "Approved" : event == "REQUEST_CHANGES" ? "Changes requested" : "Review posted"
        return await perform(id, success: message) { client in
            try await client.mutate(Queries.reviewPR, variables: ["id": pr, "event": event, "body": text.isEmpty ? nil : text])
        }
    }

    func labels(for n: GHNotification) async -> [GQLLabel] {
        if let cached = repoLabels[n.repository.fullName] { return cached }
        guard let client else { return [] }
        nonisolated struct R: Decodable, Sendable { nonisolated struct Repo: Decodable, Sendable { var labels: GQLNodes<GQLLabel> }; var repository: Repo? }
        do {
            let r = try await client.graphQL(Queries.repoLabels, variables: ["owner": n.owner, "name": n.repoName], as: R.self)
            let list = r.repository?.labels.items ?? []
            repoLabels[n.repository.fullName] = list
            return list
        } catch {
            showError(error)
            return []
        }
    }

    func toggleLabel(_ id: String, label: GQLLabel, on: Bool) async {
        guard let subject = details[id]?.subject?.id, let labelID = label.id else { return }
        _ = await perform(id) { client in
            try await client.mutate(on ? Queries.addLabels : Queries.removeLabels, variables: ["id": subject, "labels": [labelID]])
        }
    }

    func assignSelf(_ id: String) async {
        guard let subject = details[id]?.subject?.id, let me = viewer?.id else { return }
        _ = await perform(id, success: "Assigned to you") { client in
            try await client.mutate(Queries.assignSelf, variables: ["id": subject, "users": [me]])
        }
    }

    func react(_ id: String, subjectID: String, content: String, remove: Bool) async {
        _ = await perform(id) { client in
            try await client.mutate(remove ? Queries.removeReaction : Queries.addReaction, variables: ["id": subjectID, "content": content])
        }
    }
}
