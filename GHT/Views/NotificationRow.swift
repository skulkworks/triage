import SwiftUI

struct NotificationRow: View {
    var store: InboxStore
    var notification: GHNotification
    var isOpen: Bool
    @State private var hovering = false

    var body: some View {
        let n = notification
        let info = store.info[n.id]
        let glyph = SubjectGlyph(kind: n.kind, state: info?.state)
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(n.unread ? GHColor.accent : .clear)
                .frame(width: 7, height: 7)
                .padding(.top, 6)
            Image(systemName: glyph.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(glyph.color)
                .frame(width: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(n.repository.fullName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let number = n.number { Text(verbatim: "#\(number)").foregroundStyle(.tertiary) }
                    Spacer(minLength: 4)
                    if store.local.saved.contains(n.id) {
                        Image(systemName: "bookmark.fill").foregroundStyle(GHColor.attention).imageScale(.small)
                    }
                    if store.isSnoozed(n), let until = store.local.snoozed[n.id]?.until {
                        Label(until.shortAgoFuture, systemImage: "moon.zzz.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(GHColor.done)
                    }
                    Text(n.updatedAt.shortAgo)
                        .monospacedDigit()
                        .help(n.updatedAt.formatted(date: .complete, time: .shortened))
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(n.subject.title)
                    .font(.system(size: 13, weight: n.unread ? .semibold : .regular))
                    .foregroundStyle(n.unread ? .primary : .secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 5) {
                    Text(Reason.label(n.reason))
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(reasonTint(n.reason).opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(reasonTint(n.reason))
                    if let author = info?.author {
                        Avatar(url: author.avatarUrl, size: 13)
                        Text(author.display).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let count = info?.commentCount, count > 0 {
                        Label("\(count)", systemImage: "bubble.left")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }
                    ForEach(info?.labels.prefix(3) ?? [], id: \.name) { LabelChip(name: $0.name, color: $0.color) }
                    if let extra = info?.labels.count, extra > 3 {
                        Text("+\(extra - 3)").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .overlay(alignment: .trailing) {
            if hovering && store.selection.count <= 1 { quickActions }
        }
        .onHover { hovering = $0 }
        .contextMenu { RowMenu(store: store, ids: menuTargets) }
    }

    /// Right-clicking a row in a multi-selection acts on the whole selection, like Finder.
    private var menuTargets: [String] {
        store.selection.contains(notification.id) && store.selection.count > 1 ? store.targets : [notification.id]
    }

    private var quickActions: some View {
        HStack(spacing: 2) {
            QuickButton(symbol: "checkmark", help: "Done (e)") { store.markDone([notification.id]) }
            QuickButton(symbol: store.local.saved.contains(notification.id) ? "bookmark.fill" : "bookmark", help: "Save (s)") {
                store.toggleSaved([notification.id])
            }
            Menu {
                ForEach(InboxStore.snoozeOptions(), id: \.label) { o in
                    Button(o.label) { store.snooze([notification.id], until: o.date) }
                }
            } label: {
                Image(systemName: "moon.zzz")
            }
            .menuIndicator(.hidden)
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Snooze")
            QuickButton(symbol: "arrow.up.forward.square", help: "Open on GitHub (o)") {
                NSWorkspace.shared.open(store.webURL(notification))
                store.markRead([notification.id])
            }
        }
        .padding(3)
        .glassEffect(.regular, in: Capsule())
        .padding(.trailing, 2)
        .padding(.top, 14)
    }

    private func reasonTint(_ reason: String) -> Color {
        switch reason {
        case "mention", "team_mention": GHColor.accent
        case "review_requested", "approval_requested": GHColor.attention
        case "assign": GHColor.done
        case "author", "comment", "manual": GHColor.open
        case "security_alert", "security_advisory_credit": GHColor.closed
        default: GHColor.muted
        }
    }
}

private struct QuickButton: View {
    var symbol: String
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

struct RowMenu: View {
    var store: InboxStore
    var ids: [String]

    var body: some View {
        let single = ids.count == 1 ? store.notification(ids[0]) : nil
        Button("Mark as Done", systemImage: "checkmark") { store.markDone(ids) }
        Button("Mark as Read", systemImage: "envelope.open") { store.markRead(ids) }
        Button(ids.allSatisfy { store.local.saved.contains($0) } ? "Unsave" : "Save", systemImage: "bookmark") { store.toggleSaved(ids) }
        Menu("Snooze", systemImage: "moon.zzz") {
            ForEach(InboxStore.snoozeOptions(), id: \.label) { o in
                Button(o.label) { store.snooze(ids, until: o.date) }
            }
        }
        Button("Unsubscribe", systemImage: "bell.slash") { store.unsubscribe(ids) }
        Divider()
        Button("Open on GitHub", systemImage: "arrow.up.forward.square") {
            for id in ids { if let n = store.notification(id) { NSWorkspace.shared.open(store.webURL(n)) } }
            store.markRead(ids)
        }
        if let n = single {
            Button("Copy Link", systemImage: "link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(store.webURL(n).absoluteStringWithoutQuery, forType: .string)
            }
            Divider()
            Button("Only \(n.repository.fullName)", systemImage: "line.3.horizontal.decrease") {
                store.search = "repo:\(n.repository.fullName)"
            }
            Button("Done All in \(n.repository.fullName)", systemImage: "checkmark.circle") {
                store.markDone(store.visible.filter { $0.repository.fullName == n.repository.fullName }.map(\.id))
            }
        }
    }
}

extension URL {
    /// The page link without GitHub Triage's notification referrer (for sharing).
    var absoluteStringWithoutQuery: String {
        guard var c = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return absoluteString }
        c.queryItems = nil
        return c.url?.absoluteString ?? absoluteString
    }
}

extension Date {
    /// Time left on a snooze: "3h", "2d".
    var shortAgoFuture: String {
        let s = timeIntervalSinceNow
        if s < 3600 { return "\(max(1, Int(s / 60)))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }
}
