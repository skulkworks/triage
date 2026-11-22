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
        case inbox, unread, saved, snoozed
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .inbox: "tray"
            case .unread: "circle.fill"
            case .saved: "bookmark"
            case .snoozed: "moon.zzz"
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
    var info: [String: SubjectInfo] = [:]
    var local = LocalState.load() { didSet { local.save() } }
    var hidden: Set<String> = []
    var pending: [PendingAction] = []
    var toast: Toast?
    var isRefreshing = false
    var lastRefreshed: Date?
    var lastError: String?
    var now = Date()

    var scope: Scope = .inbox
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
    private var lastModified: String?
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
        TokenProvider.delete()
        client = nil
        viewer = nil
        notifications = []
        info = [:]
        infoRevision = [:]
        details = [:]
        lastModified = nil
        seeded = false
        auth = .signedOut(tokenSource == .githubCLI ? "Signed out. GitHub Triage will use the GitHub CLI's login again on next launch unless you paste a token." : nil)
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
        do {
            let result = try await client.notifications(ifModifiedSince: force ? nil : lastModified)
            switch result {
            case .notModified(let interval):
                pollInterval = interval
            case .updated(let list, let lastModified, let interval):
                pollInterval = interval
                self.lastModified = lastModified
                apply(list)
                await enrich()
            }
            lastRefreshed = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func apply(_ list: [GHNotification]) {
        let ids = Set(list.map(\.id))
        let fresh = list.sorted { $0.updatedAt > $1.updatedAt }
        // A detail cached for an older revision is stale.
        for n in fresh where infoRevision[n.id] != n.revisionKey { details[n.id] = nil }
        notifications = fresh
        selection = selection.intersection(ids)
        // Snoozes for threads that left the inbox, or woke up on new activity, are finished.
        let stale = local.snoozed.filter { id, s in
            guard let n = fresh.first(where: { $0.id == id }) else { return true }
            return n.updatedAt > s.updatedAt
        }
        if !stale.isEmpty { for id in stale.keys { local.snoozed[id] = nil } }
        announce(fresh)
    }

    /// Fetches state, author and labels for every issue, PR and discussion that changed, in one request per 40.
    private func enrich() async {
        guard let client else { return }
        let todo = notifications.filter { n in
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
        }
    }

    var visible: [GHNotification] {
        let q = activeQuery
        return notifications.filter { inScope($0, scope) && (q.isEmpty || q.matches(facts($0))) }
    }

    func count(_ scope: Scope) -> Int { notifications.count { inScope($0, scope) } }

    func count(_ filter: QuickFilter) -> Int {
        var parts: [String] = []
        if case .custom(let id) = filter, let f = local.filters.first(where: { $0.id == id }) { parts.append(f.query) }
        if let q = filter.query { parts.append(q) }
        let q = InboxQuery(parts.joined(separator: " "))
        return notifications.count { inScope($0, scope) && (q.isEmpty || q.matches(facts($0))) }
    }

    var badgeCount: Int {
        notifications.count { !hidden.contains($0.id) && !isSnoozed($0) && (!prefs.badgeUnreadOnly || $0.unread) }
    }

    var repositories: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for n in notifications where inScope(n, scope) { counts[n.repository.fullName, default: 0] += 1 }
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
        return notifications.first { $0.id == id }
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
        if let focused { return [focused] }
        return Array(selection)
    }

    func open(_ id: String) {
        if focused != id { readMarkers[id] = notification(id)?.lastReadAt }
        focused = id
        selection = [id]
        Task { await loadDetail(id) }
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

    func markDone(_ ids: [String]) { queue(.done, ids) }
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
        toast = Toast(message: title, undoable: action.id)
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
        if action.threadIDs.count == 1 { open(action.threadIDs[0]) }
        toast = nil
    }

    private func commit(_ actionID: UUID) async {
        guard let index = pending.firstIndex(where: { $0.id == actionID }), let client else { return }
        let action = pending.remove(at: index)
        pendingTasks[actionID] = nil
        if toast?.undoable == actionID { toast = nil }
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
        let done = Set(action.threadIDs).subtracting(failed)
        notifications.removeAll { done.contains($0.id) }
        hidden.subtract(action.threadIDs)
        for id in done {
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
    }

    func markRead(_ ids: [String]) {
        guard let client else { return }
        for id in ids {
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

    func markAllRead() {
        guard let client else { return }
        let stamp = Date()
        for i in notifications.indices { notifications[i].unread = false }
        Notifier.shared.removeAll()
        Task {
            do { try await client.markAllRead(before: stamp) } catch { showError(error) }
        }
    }

    func toggleSaved(_ ids: [String]) {
        let allSaved = ids.allSatisfy { local.saved.contains($0) }
        for id in ids { if allSaved { local.saved.remove(id) } else { local.saved.insert(id) } }
        toast = Toast(message: allSaved ? "Removed from Saved" : "Saved")
    }

    func snooze(_ ids: [String], until: Date) {
        let list = ids.compactMap { notification($0) }
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

    func loadDetail(_ id: String, force: Bool = false) async {
        guard let client, let n = notification(id) else { return }
        if !force, details[id] != nil { return }
        guard !detailLoading.contains(id) else { return }
        detailLoading.insert(id)
        detailErrors[id] = nil
        defer { detailLoading.remove(id) }
        do {
            let detail: ThreadDetail
            switch n.kind {
            case .issue, .pullRequest:
                guard let number = n.number else { detail = .unsupported; break }
                nonisolated struct R: Decodable, Sendable { nonisolated struct Repo: Decodable, Sendable { var issueOrPullRequest: GQLSubject? }; var repository: Repo? }
                let r = try await client.graphQL(Queries.detail, variables: ["owner": n.owner, "name": n.repoName, "number": number], as: R.self)
                guard let s = r.repository?.issueOrPullRequest else { throw GitHubError.graphQL(["This thread is no longer available."]) }
                detail = .conversation(s)
                info[id] = SubjectInfo(s)
                infoRevision[id] = n.revisionKey
            case .discussion:
                let number = try await discussionNumber(n)
                nonisolated struct R: Decodable, Sendable { nonisolated struct Repo: Decodable, Sendable { var discussion: GQLSubject? }; var repository: Repo? }
                let r = try await client.graphQL(Queries.discussionDetail, variables: ["owner": n.owner, "name": n.repoName, "number": number], as: R.self)
                guard let s = r.repository?.discussion else { throw GitHubError.graphQL(["This discussion is no longer available."]) }
                detail = .conversation(s)
                info[id] = SubjectInfo(s)
                infoRevision[id] = n.revisionKey
            case .release:
                guard let url = n.subject.url else { detail = .unsupported; break }
                let release = try await client.release(apiURL: url)
                detail = .release(release)
                info[id] = SubjectInfo(release: release)
            default:
                detail = .unsupported
            }
            details[id] = detail
        } catch {
            detailErrors[id] = error.localizedDescription
        }
    }

    private func discussionNumber(_ n: GHNotification) async throws -> Int {
        if let number = n.number { return number }
        guard let client else { throw GitHubError.noToken }
        nonisolated struct R: Decodable, Sendable { nonisolated struct S: Decodable, Sendable { nonisolated struct N: Decodable, Sendable { var number: Int?; var title: String? }; var nodes: [N] }; var search: S }
        let q = "repo:\(n.repository.fullName) in:title \"\(n.subject.title.replacingOccurrences(of: "\"", with: ""))\""
        let r = try await client.graphQL(Queries.findDiscussion, variables: ["q": q], as: R.self)
        guard let hit = r.search.nodes.first(where: { $0.title == n.subject.title }) ?? r.search.nodes.first, let num = hit.number else {
            throw GitHubError.graphQL(["Couldn't find this discussion."])
        }
        return num
    }

    // MARK: Conversation actions

    private func perform(_ id: String, success: String? = nil, _ work: @escaping (GitHubClient) async throws -> Void) async -> Bool {
        guard let client else { return false }
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
