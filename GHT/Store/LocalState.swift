import Foundation

/// Things GitHub's API doesn't keep for us: saved threads, snoozes, custom filters and reply snippets.
struct LocalState: Codable {
    struct Snooze: Codable, Hashable {
        var until: Date
        /// The thread's `updated_at` when it was snoozed: new activity wakes it early.
        var updatedAt: Date
    }

    struct SavedFilter: Codable, Hashable, Identifiable {
        var id = UUID()
        var name: String
        var query: String
    }

    struct Snippet: Codable, Hashable, Identifiable {
        var id = UUID()
        var name: String
        var body: String
    }

    var saved: Set<String> = []
    var snoozed: [String: Snooze] = [:]
    /// Threads marked unread in the app. GitHub's API can't mark a thread unread, so this only lives here:
    /// github.com still shows them as read. Opening or reading the thread clears it.
    var markedUnread: Set<String> = []
    /// Done threads moved back to the inbox in the app. GitHub's API has no "move to inbox", so on
    /// github.com they stay done. New activity puts a thread back in GitHub's inbox, which ends this.
    var restored: Set<String> = []
    var filters: [SavedFilter] = [
        SavedFilter(name: "Needs me", query: "reason:mention,assign,review_requested,team_mention is:open"),
        SavedFilter(name: "Finished", query: "is:closed,merged"),
        SavedFilter(name: "Releases", query: "is:release"),
    ]
    var snippets: [Snippet] = [
        Snippet(name: "Thanks, fixed", body: "Thanks for the report! This is fixed in the `develop` branch and will be in the next release."),
        Snippet(name: "Need more info", body: "Thanks! Could you share the Grav version, PHP version, and the steps to reproduce this?"),
        Snippet(name: "Can't reproduce", body: "I can't reproduce this on the latest release. If it still happens for you, please reopen with the steps and your environment details."),
    ]

    init() {}

    /// Every key is optional, so a state.json from an older build (missing newer keys) still loads
    /// instead of being replaced by defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LocalState()
        saved = try c.decodeIfPresent(Set<String>.self, forKey: .saved) ?? d.saved
        snoozed = try c.decodeIfPresent([String: Snooze].self, forKey: .snoozed) ?? d.snoozed
        markedUnread = try c.decodeIfPresent(Set<String>.self, forKey: .markedUnread) ?? d.markedUnread
        restored = try c.decodeIfPresent(Set<String>.self, forKey: .restored) ?? d.restored
        filters = try c.decodeIfPresent([SavedFilter].self, forKey: .filters) ?? d.filters
        snippets = try c.decodeIfPresent([Snippet].self, forKey: .snippets) ?? d.snippets
    }

    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: Bundle.main.bundleIdentifier ?? "dev.skulkworks.ght", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "state.json")
    }

    static func load() -> LocalState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(LocalState.self, from: data) else { return LocalState() }
        return state
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) { try? data.write(to: Self.url, options: .atomic) }
    }
}
