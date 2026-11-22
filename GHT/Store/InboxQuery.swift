import Foundation

/// GitHub-inbox style filter text: `repo:getgrav/grav reason:mention,assign is:unread -is:release crash`.
/// Comma-separated values are OR'd, separate terms are AND'd, a leading `-` negates a term.
nonisolated struct InboxQuery: Equatable, Sendable {
    struct Term: Equatable, Sendable {
        var key: String
        var values: [String]
        var negated: Bool
    }

    var terms: [Term] = []
    var text: [String] = []

    /// What a thread looks like to the matcher.
    struct Facts: Sendable {
        var title: String
        var repo: String  // owner/name
        var owner: String
        var reason: String
        var kind: SubjectKind
        var unread: Bool
        var state: SubjectState?
        var author: String?
        var authorIsBot: Bool = false
        var labels: [String]
        var saved: Bool
        var snoozed: Bool
    }

    static let keys: Set<String> = ["repo", "org", "owner", "reason", "is", "author", "label", "type"]

    init(_ string: String = "") {
        for raw in Self.tokenize(string) {
            var token = raw
            var negated = false
            if token.hasPrefix("-"), token.count > 1, token.contains(":") {
                negated = true
                token.removeFirst()
            }
            if let colon = token.firstIndex(of: ":") {
                let key = token[..<colon].lowercased()
                let value = String(token[token.index(after: colon)...])
                if Self.keys.contains(key), !value.isEmpty {
                    let values = value.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).lowercased() }
                    terms.append(Term(key: key == "owner" ? "org" : key, values: values, negated: negated))
                    continue
                }
            }
            text.append(raw.lowercased())
        }
    }

    var isEmpty: Bool { terms.isEmpty && text.isEmpty }

    /// Splits on spaces, keeping "quoted phrases" together.
    static func tokenize(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quoted = false
        for ch in s {
            if ch == "\"" { quoted.toggle(); continue }
            if ch.isWhitespace && !quoted {
                if !current.isEmpty { out.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    func matches(_ f: Facts) -> Bool {
        for word in text {
            if !f.title.lowercased().contains(word) && !f.repo.lowercased().contains(word) { return false }
        }
        for term in terms {
            let hit = term.values.contains { Self.match(key: term.key, value: $0, f) }
            if hit == term.negated { return false }
        }
        return true
    }

    static func match(key: String, value: String, _ f: Facts) -> Bool {
        switch key {
        case "repo":
            let repo = f.repo.lowercased()
            return value.contains("/") ? repo == value : repo.hasSuffix("/" + value)
        case "org":
            return f.owner.lowercased() == value
        case "reason":
            if value == "participating" { return Reason.participating.contains(f.reason) }
            let normalized = value.replacingOccurrences(of: "-", with: "_")
            let aliases = ["review": "review_requested", "mentioned": "mention", "assigned": "assign", "team": "team_mention"]
            return f.reason == (aliases[normalized] ?? normalized)
        case "author":
            return f.author?.lowercased() == value
        case "label":
            return f.labels.contains { $0.lowercased() == value }
        case "type", "is":
            switch value {
            case "unread": return f.unread
            case "read": return !f.unread
            case "saved": return f.saved
            case "snoozed": return f.snoozed
            case "issue", "issues": return f.kind == .issue
            case "pr", "pull", "pullrequest", "pull-request": return f.kind == .pullRequest
            case "discussion": return f.kind == .discussion
            case "release": return f.kind == .release
            case "commit": return f.kind == .commit
            case "ci", "check", "workflow": return f.kind == .checkSuite || f.kind == .workflowRun
            case "security", "advisory", "alert": return f.kind == .advisory || f.kind == .vulnerability || f.kind == .dependabot
            case "open": return f.state == .open || f.state == .draft
            case "closed": return f.state == .closed || f.state == .notPlanned || f.state == .duplicate
            case "merged": return f.state == .merged
            case "draft": return f.state == .draft
            case "finished", "done-able": return f.state?.isFinished == true
            case "notplanned", "not-planned": return f.state == .notPlanned
            case "answered": return f.state == .answered
            case "bot": return f.authorIsBot
            default: return false
            }
        default:
            return false
        }
    }
}
