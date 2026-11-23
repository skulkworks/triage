import AppKit
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
        let isDone = store.isDone(n.id)
        HStack(alignment: .top, spacing: 7) {
            // Click the dot to flip read and unread, like Mail. A faint ring shows where it is on hover.
            Button { store.toggleRead([n.id]) } label: {
                Circle()
                    .fill(n.unread ? AnyShapeStyle(GHColor.accent) : AnyShapeStyle(Color.clear))
                    .overlay { if !n.unread && hovering && !isDone { Circle().strokeBorder(.tertiary, lineWidth: 1) } }
                    .frame(width: 7, height: 7)
                    .frame(width: 15, height: 17)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, -4)
            .disabled(isDone)
            .help(isDone ? "" : n.unread ? "Mark as read (⇧I)" : "Mark as unread (⇧U)")
            .accessibilityLabel(n.unread ? "Unread. Mark as read" : "Mark as unread")
            Image(systemName: glyph.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(glyph.color)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(n.repository.fullName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let number = n.number { Text(verbatim: "#\(number)").monospacedDigit().opacity(0.8) }
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
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

                // Read threads keep full-strength text; weight and the blue dot carry "unread".
                Text(n.subject.title)
                    .font(.system(size: 13, weight: n.unread ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .opacity(n.unread ? 1 : 0.86)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    ReasonChip(label: Reason.label(n.reason), tint: reasonTint(n.reason))
                    if let author = info?.author {
                        HStack(spacing: 4) {
                            Avatar(url: author.avatarUrl, size: 14)
                            Text(author.display).lineLimit(1)
                        }
                    }
                    if let count = info?.commentCount, count > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "bubble.left").imageScale(.small)
                            Text("\(count)").monospacedDigit()
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(count) comment\(count == 1 ? "" : "s")")
                    }
                    ForEach(info?.labels.prefix(3) ?? [], id: \.name) { LabelChip(name: $0.name, color: $0.color) }
                    if let extra = info?.labels.count, extra > 3 {
                        Text("+\(extra - 3)")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 1)
            }
            // Room for the Done button, which sits over the row's trailing edge.
            Color.clear.frame(width: CircleButton.width)
        }
        .padding(.vertical, 5)
        // The row draws its own tinted selection (see InboxPane), so text never flips to the
        // white-on-accent treatment and state colors stay readable.
        .environment(\.backgroundProminence, .standard)
        .overlay(alignment: .trailing) {
            HStack(spacing: 6) {
                if hovering && store.selection.count <= 1 { quickActions(isDone: isDone) }
                if isDone {
                    CircleButton(symbol: "tray.and.arrow.up", tint: GHColor.accent, help: "Move to Inbox (e)") { store.moveToInbox([notification.id]) }
                } else {
                    CircleButton(symbol: "checkmark", tint: GHColor.open, help: "Mark as done (e)") { store.markDone([notification.id]) }
                }
            }
        }
        .onHover { hovering = $0 }
        .contextMenu { RowMenu(store: store, ids: menuTargets) }
    }

    /// Right-clicking a row in a multi-selection acts on the whole selection, like Finder.
    private var menuTargets: [String] {
        store.selection.contains(notification.id) && store.selection.count > 1 ? store.targets : [notification.id]
    }

    /// Save and Snooze are for inbox threads; a done thread gets just Open.
    private func quickActions(isDone: Bool) -> some View {
        HStack(spacing: 2) {
            if !isDone {
                QuickButton(symbol: store.local.saved.contains(notification.id) ? "bookmark.fill" : "bookmark", help: "Save (s)") {
                    store.toggleSaved([notification.id])
                }
                // A SwiftUI Menu here draws its icon black on the glass capsule, so pop up an NSMenu from a plain button.
                QuickButton(symbol: "moon.zzz", help: "Snooze") { showSnoozeMenu() }
            }
            QuickButton(symbol: "arrow.up.forward.square", help: "Open on GitHub (o)") {
                NSWorkspace.shared.open(store.webURL(notification))
                store.markRead([notification.id])
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .glassEffect(.regular, in: Capsule())
    }

    private func showSnoozeMenu() {
        let id = notification.id
        let menu = NSMenu()
        for option in InboxStore.snoozeOptions() {
            menu.addItem(MenuAction.item(option.label) { [store] in store.snooze([id], until: option.date) })
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// nil is the neutral chip, for reasons that don't call for attention.
    private func reasonTint(_ reason: String) -> Color? {
        switch reason {
        case "mention", "team_mention": GHColor.accent
        case "review_requested", "approval_requested": GHColor.attention
        case "assign": GHColor.done
        case "author", "comment", "manual": GHColor.open
        case "security_alert", "security_advisory_credit": GHColor.closed
        default: nil
        }
    }
}

private struct ReasonChip: View {
    var label: String
    var tint: Color?
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Text(label)
            .font(.system(size: 10.5, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(tint.map { AnyShapeStyle($0.opacity(0.16)) } ?? AnyShapeStyle(Color.primary.opacity(0.08)))
            }
            .foregroundStyle(contrast == .increased ? AnyShapeStyle(.primary) : tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
    }
}

/// Done (or, in the Done tab, Move to Inbox). Always visible on every row, so a pass through the inbox
/// can be click, click, click on Done. Quiet at rest; fills with its tint under the pointer.
private struct CircleButton: View {
    static let width: CGFloat = 26
    var symbol: String
    var tint: Color
    var help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(hovering ? AnyShapeStyle(tint) : AnyShapeStyle(Color.clear))
                Circle()
                    .strokeBorder(hovering ? AnyShapeStyle(tint) : AnyShapeStyle(.tertiary), lineWidth: 1.2)
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(hovering ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            }
            .frame(width: Self.width, height: Self.width)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.12), value: hovering)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Target for an NSMenuItem that runs a closure. The item keeps it alive through representedObject.
private final class MenuAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) { self.handler = handler }

    @objc func fire() { handler() }

    static func item(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
        let action = MenuAction(handler)
        let item = NSMenuItem(title: title, action: #selector(fire), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        return item
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
        .accessibilityLabel(help)
    }
}

struct RowMenu: View {
    var store: InboxStore
    var ids: [String]

    var body: some View {
        let single = ids.count == 1 ? store.notification(ids[0]) : nil
        let allDone = ids.allSatisfy(store.isDone)
        if allDone {
            Button("Move to Inbox", systemImage: "tray.and.arrow.up") { store.moveToInbox(ids) }
        } else {
            Button("Mark as Done", systemImage: "checkmark") { store.markDone(ids) }
            if ids.contains(where: { store.notification($0)?.unread == true }) {
                Button("Mark as Read", systemImage: "envelope.open") { store.markRead(ids) }
            } else {
                Button("Mark as Unread", systemImage: "envelope.badge") { store.markUnread(ids) }
            }
            Button(ids.allSatisfy { store.local.saved.contains($0) } ? "Unsave" : "Save", systemImage: "bookmark") { store.toggleSaved(ids) }
            Menu("Snooze", systemImage: "moon.zzz") {
                ForEach(InboxStore.snoozeOptions(), id: \.label) { o in
                    Button(o.label) { store.snooze(ids, until: o.date) }
                }
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
            if !allDone {
                Button("Done All in \(n.repository.fullName)", systemImage: "checkmark.circle") {
                    store.markDone(store.visible.filter { $0.repository.fullName == n.repository.fullName }.map(\.id))
                }
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
