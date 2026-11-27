import Foundation

/// `-triageSelfTest [-triageOut <dir>]`: read-only checks against the signed-in account. Lists the inbox, enriches it,
/// loads one conversation of each kind and writes the rendered pages to the out dir. Never changes anything on GitHub.
enum SelfTest {
    static func run() async {
        let args = CommandLine.arguments
        let out = args.firstIndex(of: "-triageOut").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            ?? NSTemporaryDirectory() + "triage-selftest"
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        func log(_ s: String) { print(s); fflush(stdout) }

        let store = InboxStore()
        await store.signIn()
        guard store.auth == .signedIn else { log("FAIL sign-in: \(store.auth)"); return }
        log("OK signed in as \(store.viewer?.login ?? "?") via \(store.tokenSource?.rawValue ?? "?")")
        // signIn started polling; wait for the first refresh + enrichment to land.
        for _ in 0..<60 where store.lastRefreshed == nil { try? await Task.sleep(for: .milliseconds(500)) }
        try? await Task.sleep(for: .seconds(2))
        if let e = store.lastError { log("FAIL refresh: \(e)") }
        log("OK \(store.notifications.count) notifications, \(store.info.count) enriched, unread \(store.count(.unread))")
        let kinds = Dictionary(grouping: store.notifications, by: { $0.subject.type }).mapValues(\.count)
        log("   kinds: \(kinds)")
        let states = Dictionary(grouping: store.info.values, by: { $0.state.rawValue }).mapValues(\.count)
        log("   states: \(states)")
        for kind in TidyKind.allCases { log("   tidy \(kind): \(store.tidyCandidates(kind).count)") }

        var picks: [GHNotification] = []
        // `-triageSelfTestAll`: every inbox and done thread instead of one of each kind.
        if args.contains("-triageSelfTestAll") {
            await store.refreshDone()
            picks = store.notifications + store.done
            log("   all: \(picks.count) threads")
        }
        for type in ["Issue", "PullRequest", "Release", "Discussion", "RepositoryAdvisory"] {
            if let n = store.notifications.first(where: { $0.subject.type == type }), !picks.contains(n) { picks.append(n) }
        }
        // An issue with lots of comments, to see a long thread.
        if let busy = store.notifications.filter({ $0.kind == .issue }).max(by: { (store.info[$0.id]?.commentCount ?? 0) < (store.info[$1.id]?.commentCount ?? 0) }),
           !picks.contains(busy) { picks.append(busy) }

        for n in picks {
            await store.loadDetail(n.id)
            if let e = store.detailErrors[n.id] {
                log("FAIL detail \(n.subject.type) \(n.repository.fullName)#\(n.number ?? 0): \(e)")
                continue
            }
            guard let d = store.details[n.id] else { log("FAIL detail missing \(n.id)"); continue }
            let html = ConversationHTML.render(d, notification: n, viewer: store.viewer?.login, lastRead: n.lastReadAt)
            let file = "\(out)/\(n.subject.type)-\(n.id).html"
            try? html.write(toFile: file, atomically: true, encoding: .utf8)
            let items = d.subject?.timelineItems?.items.count ?? d.subject?.comments?.items.count ?? 0
            log("OK detail \(n.subject.type) \(n.repository.fullName)#\(n.number ?? 0) items=\(items) html=\(html.count) → \(file)")
        }
        // Every thread was just loaded, so checking them again must find nothing changed.
        let loaded = picks.map(\.id).filter { store.details[$0]?.subject != nil }
        await store.checkForChanges(loaded)
        let check = store.lastChangeCheck
        log("\(check.changed == 0 && check.checked == loaded.count ? "OK" : "FAIL") change check: \(check.checked) of \(loaded.count) checked, \(check.changed) changed")
        #if DEBUG
        // And a thread that did change must be caught and reloaded.
        if let id = loaded.first {
            store.debugAgeCachedCopy(id)
            await store.checkForChanges([id])
            let caught = store.lastChangeCheck.changed == 1
            for _ in 0..<40 where store.debugCachedStamp(id) == "stale" { try? await Task.sleep(for: .milliseconds(250)) }
            let reloaded = store.debugCachedStamp(id) != "stale"
            log("\(caught && reloaded ? "OK" : "FAIL") changed thread: caught \(caught), reloaded \(reloaded)")
        }
        #endif
        log("DONE")
    }
}
