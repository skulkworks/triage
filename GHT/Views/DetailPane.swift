import SwiftUI

struct DetailPane: View {
    @Bindable var store: InboxStore
    var notification: GHNotification
    /// Drafts live in the store, so switching threads (or closing the popover) keeps a half-written reply.
    private var draft: Binding<String> {
        Binding(get: { store.drafts[notification.id] ?? "" }, set: { store.drafts[notification.id] = $0 })
    }

    private var n: GHNotification { notification }
    private var detail: ThreadDetail? { store.details[n.id] }
    private var subject: GQLSubject? { detail?.subject }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            toolbar
            Divider()
            content
            if let subject, canReply(subject) {
                Divider()
                Composer(store: store, notification: n, subject: subject, draft: draft)
            }
        }
        .task { await store.loadDetail(n.id) }
        .onKeyPress(.escape) {
            store.closeDetail()
            return .handled
        }
    }

    private func canReply(_ s: GQLSubject) -> Bool { s.locked != true || s.viewerCanUpdate == true }

    // MARK: Header

    private var header: some View {
        let state = store.info[n.id]?.state ?? .unknown
        let glyph = SubjectGlyph(kind: n.kind, state: state)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: glyph.symbol)
                    .foregroundStyle(glyph.color)
                    .font(.system(size: 16, weight: .semibold))
                (Text(subject?.title ?? n.subject.title).font(.system(size: 17, weight: .semibold))
                    + Text(verbatim: n.number.map { "  #\($0)" } ?? "").font(.system(size: 17)).foregroundStyle(.secondary))
                    .textSelection(.enabled)
                    .lineLimit(3)
                Spacer()
                Button {
                    store.closeDetail()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close (esc)")
            }
            HStack(spacing: 8) {
                StatePill(kind: n.kind, state: state)
                metaLine
                Spacer(minLength: 0)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if let s = subject, !(s.labels?.items.isEmpty ?? true) || !(s.assignees?.items.isEmpty ?? true) || s.milestone != nil {
                HStack(spacing: 5) {
                    ForEach(s.labels?.items ?? [], id: \.name) { LabelChip(name: $0.name, color: $0.color) }
                    if let m = s.milestone {
                        Label(m.title, systemImage: "signpost.right").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    ForEach(s.assignees?.items ?? [], id: \.login) { a in
                        Avatar(url: a.avatarUrl, size: 18).help("Assigned to \(a.display)")
                    }
                }
            }
            if let s = subject, s.__typename == "PullRequest" { PRSummary(subject: s) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var metaLine: some View {
        let repo = Text(n.repository.fullName).fontWeight(.medium)
        if let s = subject, let author = s.author?.display, let created = s.createdAt {
            let comments = s.__typename == "Discussion" ? (s.comments?.totalCount ?? 0) : (store.info[n.id]?.commentCount ?? 0)
            Text("\(repo) · \(Text(author).fontWeight(.medium)) opened \(created.formatted(.relative(presentation: .named))) · \(comments) comment\(comments == 1 ? "" : "s")")
                .lineLimit(1)
        } else if case .release(let r) = detail {
            Text("\(repo) · \(r.tagName)\(r.prerelease ? " · Pre-release" : "")")
        } else {
            Text("\(repo) · \(n.kind.label) · \(Reason.label(n.reason))")
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 4) {
            Button("Done", systemImage: "checkmark") { store.markDone([n.id]) }
                .help("Mark as done (e)")
            Button(store.local.saved.contains(n.id) ? "Saved" : "Save",
                   systemImage: store.local.saved.contains(n.id) ? "bookmark.fill" : "bookmark") { store.toggleSaved([n.id]) }
                .help("Save (s)")
            SnoozeMenu(store: store, ids: [n.id])
            Button("Unsubscribe", systemImage: "bell.slash") { store.unsubscribe([n.id]) }
                .help("Unsubscribe and mark done (⇧U)")
            if let s = subject {
                Divider().frame(height: 16).padding(.horizontal, 4)
                StateMenu(store: store, id: n.id, subject: s)
                if s.__typename != "Discussion", s.viewerCanUpdate == true {
                    LabelMenu(store: store, notification: n, subject: s)
                    if !(s.assignees?.items.contains { $0.login == store.viewer?.login } ?? false) {
                        Button("Assign me", systemImage: "person.badge.plus") { Task { await store.assignSelf(n.id) } }
                            .help("Assign yourself")
                    }
                }
            }
            Spacer()
            if store.busy.contains(n.id) || store.detailLoading.contains(n.id) { ProgressView().controlSize(.small) }
            Button("Reload", systemImage: "arrow.clockwise") { Task { await store.loadDetail(n.id, force: true) } }
            Button("Copy Link", systemImage: "link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(store.webURL(n).absoluteStringWithoutQuery, forType: .string)
                store.toast = Toast(message: "Link copied")
            }
            Button("Open on GitHub", systemImage: "arrow.up.forward.square") { NSWorkspace.shared.open(store.webURL(n)) }
                .help("Open on github.com (o)")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .imageScale(.large)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: Body

    @ViewBuilder private var content: some View {
        if let error = store.detailErrors[n.id] {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(GHColor.attention)
                Text(error).multilineTextAlignment(.center).foregroundStyle(.secondary)
                HStack {
                    Button("Try Again") { Task { await store.loadDetail(n.id, force: true) } }
                    Button("Open on GitHub") { NSWorkspace.shared.open(store.webURL(n)) }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let detail {
            switch detail {
            case .unsupported:
                UnsupportedView(store: store, notification: n)
            default:
                ConversationWebView(
                    html: ConversationHTML.render(detail, notification: n, viewer: store.viewer?.login, lastRead: store.readMarkers[n.id] ?? nil),
                    anchors: ["ght-new"] + [n.latestCommentAnchor].compactMap { $0 }
                ) { message in
                    handle(message)
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func handle(_ message: WebMessage) {
        switch message {
        case .quote(let text):
            let quoted = text.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
            let current = draft.wrappedValue
            draft.wrappedValue = (current.isEmpty ? "" : current + "\n\n") + quoted + "\n\n"
            store.replyFocusRequest += 1
        case .mention(let login):
            let current = draft.wrappedValue
            draft.wrappedValue = current + (current.isEmpty || current.hasSuffix(" ") || current.hasSuffix("\n") ? "" : " ") + "@\(login) "
            store.replyFocusRequest += 1
        case .react(let subjectID, let content, let remove):
            Task { await store.react(n.id, subjectID: subjectID, content: content, remove: remove) }
        case .open(let url):
            if !store.openInApp(url) { NSWorkspace.shared.open(url) }
        }
    }
}

private struct PRSummary: View {
    var subject: GQLSubject

    var body: some View {
        HStack(spacing: 10) {
            if let head = subject.headRefName, let base = subject.baseRefName {
                Text("\(Text(base).font(.system(.caption, design: .monospaced))) ← \(Text(head).font(.system(.caption, design: .monospaced)))")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let add = subject.additions, let del = subject.deletions {
                HStack(spacing: 3) {
                    Text("+\(add)").foregroundStyle(GHColor.open)
                    Text("−\(del)").foregroundStyle(GHColor.closed)
                    Text("· \(subject.changedFiles ?? 0) file\(subject.changedFiles == 1 ? "" : "s")").foregroundStyle(.secondary)
                }
                .font(.caption.monospacedDigit())
            }
            if let checks = subject.commits?.items.first?.commit.statusCheckRollup?.state {
                ChecksBadge(state: checks)
            }
            if let decision = subject.reviewDecision {
                ReviewBadge(decision: decision)
            }
            if subject.mergeable == "CONFLICTING" {
                Label("Conflicts", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(GHColor.closed)
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct ChecksBadge: View {
    var state: String
    var body: some View {
        let (symbol, color, text): (String, Color, String) = switch state {
        case "SUCCESS": ("checkmark.circle.fill", GHColor.open, "Checks passed")
        case "FAILURE", "ERROR": ("xmark.circle.fill", GHColor.closed, "Checks failed")
        case "PENDING", "EXPECTED": ("clock.fill", GHColor.attention, "Checks running")
        default: ("questionmark.circle", GHColor.muted, state.capitalized)
        }
        Label(text, systemImage: symbol).foregroundStyle(color).font(.caption)
    }
}

private struct ReviewBadge: View {
    var decision: String
    var body: some View {
        let (symbol, color, text): (String, Color, String) = switch decision {
        case "APPROVED": ("checkmark.seal.fill", GHColor.open, "Approved")
        case "CHANGES_REQUESTED": ("exclamationmark.bubble.fill", GHColor.closed, "Changes requested")
        default: ("eye", GHColor.attention, "Review required")
        }
        Label(text, systemImage: symbol).foregroundStyle(color).font(.caption)
    }
}

/// Close / reopen / merge, depending on what the subject is and what the viewer may do.
private struct StateMenu: View {
    var store: InboxStore
    var id: String
    var subject: GQLSubject

    var body: some View {
        let isOpen = subject.state == "OPEN" || (subject.__typename == "Discussion" && subject.closed != true)
        if subject.__typename == "PullRequest" && subject.state == "OPEN" {
            Menu {
                if subject.viewerCanUpdate == true {
                    Section("Merge") {
                        Button("Squash and merge") { Task { await store.merge(id, method: "SQUASH") } }
                        Button("Create a merge commit") { Task { await store.merge(id, method: "MERGE") } }
                        Button("Rebase and merge") { Task { await store.merge(id, method: "REBASE") } }
                    }
                }
                Section("Review") {
                    Button("Approve") { Task { _ = await store.review(id, event: "APPROVE", body: "") } }
                }
                if subject.viewerCanClose ?? subject.viewerCanUpdate ?? false {
                    Divider()
                    Button("Close pull request", role: .destructive) { Task { await store.setState(id, .close(.completed)) } }
                }
            } label: {
                Label("Merge or close", systemImage: "arrow.triangle.merge")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Merge, approve or close")
        } else if isOpen, subject.viewerCanClose ?? subject.viewerCanUpdate ?? false {
            Menu {
                if subject.__typename == "Issue" {
                    ForEach(CloseReason.allCases) { reason in
                        Button(reason.label) { Task { await store.setState(id, .close(reason)) } }
                    }
                } else {
                    Button("Close") { Task { await store.setState(id, .close(.completed)) } }
                }
            } label: {
                Label("Close", systemImage: "checkmark.circle")
            } primaryAction: {
                Task { await store.setState(id, .close(.completed)) }
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Close (click) — or pick a reason (hold)")
        } else if !isOpen, subject.state != "MERGED", subject.viewerCanReopen ?? subject.viewerCanUpdate ?? false {
            Button("Reopen", systemImage: "arrow.uturn.backward.circle") { Task { await store.setState(id, .reopen) } }
                .help("Reopen")
        }
    }
}

private struct LabelMenu: View {
    var store: InboxStore
    var notification: GHNotification
    var subject: GQLSubject
    @State private var labels: [GQLLabel] = []

    var body: some View {
        let current = Set(subject.labels?.items.map(\.name) ?? [])
        Menu {
            if labels.isEmpty {
                Text("Loading labels…")
            }
            ForEach(labels, id: \.name) { label in
                let on = current.contains(label.name)
                Button {
                    Task { await store.toggleLabel(notification.id, label: label, on: !on) }
                } label: {
                    Label { Text(label.name) } icon: { Image(systemName: on ? "checkmark.circle.fill" : "circle") }
                }
            }
        } label: {
            Label("Labels", systemImage: "tag")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Labels")
        .task { labels = await store.labels(for: notification) }
    }
}

private struct UnsupportedView: View {
    var store: InboxStore
    var notification: GHNotification

    var body: some View {
        let glyph = SubjectGlyph(kind: notification.kind, state: nil)
        VStack(spacing: 12) {
            Image(systemName: glyph.symbol).font(.system(size: 40, weight: .light)).foregroundStyle(glyph.color)
            Text(notification.kind.label).font(.title3.weight(.semibold))
            Text("GitHub's API doesn't share the details of this kind of notification. Open it on github.com, or mark it done here.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            HStack {
                Button("Open on GitHub") {
                    NSWorkspace.shared.open(store.webURL(notification))
                    store.markRead([notification.id])
                }
                .buttonStyle(.borderedProminent)
                Button("Mark as Done") { store.markDone([notification.id]) }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
