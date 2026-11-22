import SwiftUI

struct InboxPane: View {
    @Bindable var store: InboxStore
    @Environment(\.presentation) private var presentation
    @Environment(\.windowActions) private var windowActions
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool
    @State private var showShortcuts = false
    @State private var savingFilter = false
    @State private var newFilterName = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            searchBar
            filterChips
            Divider()
            list
            if store.selection.count > 1 { BulkBar(store: store) }
            footer
        }
        .sheet(isPresented: $showShortcuts) { ShortcutsSheet() }
        .onAppear { listFocused = true }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            ForEach(InboxStore.Scope.allCases) { scope in
                ScopeTab(scope: scope, count: store.count(scope), selected: store.scope == scope) {
                    store.scope = scope
                }
            }
            Spacer(minLength: 4)
            Button {
                Task { await store.refresh(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
                    .animation(store.isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: store.isRefreshing)
            }
            .help("Refresh (⌘R)")
            .keyboardShortcut("r", modifiers: .command)
            tidyMenu
            moreMenu
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var tidyMenu: some View {
        Menu {
            Section("Mark as done") {
                ForEach(TidyKind.allCases) { kind in
                    let ids = store.tidyCandidates(kind)
                    Button {
                        store.markDone(ids)
                    } label: {
                        Label("\(kind.label) (\(ids.count))", systemImage: kind.symbol)
                    }
                    .disabled(ids.isEmpty)
                }
                let shown = store.visible.map(\.id)
                Button {
                    store.markDone(shown)
                } label: {
                    Label("Everything shown (\(shown.count))", systemImage: "checkmark.circle")
                }
                .disabled(shown.isEmpty)
            }
            Section {
                Button("Mark all as read", systemImage: "envelope.open") { store.markAllRead() }
            }
        } label: {
            Image(systemName: "wand.and.sparkles")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Tidy up: clear whole groups at once")
    }

    private var moreMenu: some View {
        Menu {
            Picker("Group by", selection: Bindable(store.prefs).groupBy) {
                ForEach(GroupBy.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            if presentation == .popover {
                Button("Open in Window", systemImage: "macwindow") { windowActions.popOut() }
            }
            Button("Keyboard Shortcuts", systemImage: "keyboard") { showShortcuts = true }
            Button("Settings…", systemImage: "gearshape") { windowActions.settings() }
            Divider()
            Button("Quit GitHub Triage", systemImage: "power") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: Search & filters

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(.secondary)
            TextField("Filter — repo:, org:, reason:, is:, label:, author:", text: $store.search)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { listFocused = true }
                .onKeyPress(.escape) {
                    if store.search.isEmpty { listFocused = true } else { store.search = "" }
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    listFocused = true
                    store.move(1)
                    return .handled
                }
            if !store.search.isEmpty {
                Menu {
                    Button("Save as Filter…") { newFilterName = ""; savingFilter = true }
                    Button("Clear") { store.search = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                } primaryAction: {
                    store.search = ""
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .buttonStyle(.borderless)
            }
            Menu {
                Section("Repositories") {
                    ForEach(store.repositories.prefix(30), id: \.name) { repo in
                        Button("\(repo.name)  (\(repo.count))") { setTerm("repo", repo.name) }
                    }
                }
                Section("Type") {
                    Button("Issues") { setTerm("is", "issue") }
                    Button("Pull requests") { setTerm("is", "pr") }
                    Button("Discussions") { setTerm("is", "discussion") }
                    Button("Releases") { setTerm("is", "release") }
                }
                Section("State") {
                    Button("Open") { setTerm("is", "open") }
                    Button("Closed or merged") { setTerm("is", "finished") }
                    Button("Unread") { setTerm("is", "unread") }
                }
            } label: {
                Image(systemName: "chevron.down.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .buttonStyle(.borderless)
            .help("Filter by repository, type or state")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .background {
            Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command).hidden()
        }
        .alert("Save Filter", isPresented: $savingFilter) {
            TextField("Name", text: $newFilterName)
            Button("Save") {
                let name = newFilterName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                let f = LocalState.SavedFilter(name: name, query: store.search)
                store.local.filters.append(f)
                store.search = ""
                store.quickFilter = .custom(f.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(store.search)
        }
    }

    /// Replaces any existing `key:` term in the search text.
    private func setTerm(_ key: String, _ value: String) {
        var tokens = InboxQuery.tokenize(store.search).filter { !$0.lowercased().hasPrefix("\(key):") }
        tokens.append("\(key):\(value)")
        store.search = tokens.joined(separator: " ")
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(InboxStore.QuickFilter.builtIn) { f in
                    FilterChip(title: f.label, count: f == .all ? nil : store.count(f), selected: store.quickFilter == f) {
                        store.quickFilter = f
                    }
                }
                ForEach(store.local.filters) { f in
                    FilterChip(title: f.name, count: store.count(.custom(f.id)), selected: store.quickFilter == .custom(f.id)) {
                        store.quickFilter = store.quickFilter == .custom(f.id) ? .all : .custom(f.id)
                    }
                    .contextMenu {
                        Button("Show Query") { store.search = f.query; store.quickFilter = .all }
                        Button("Delete Filter", role: .destructive) {
                            store.local.filters.removeAll { $0.id == f.id }
                            if store.quickFilter == .custom(f.id) { store.quickFilter = .all }
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 8)
    }

    // MARK: List

    private var list: some View {
        ScrollViewReader { proxy in
            List(selection: $store.selection) {
                ForEach(store.groups) { group in
                    Section {
                        ForEach(group.items) { n in
                            NotificationRow(store: store, notification: n, isOpen: store.focused == n.id)
                                .tag(n.id)
                                .id(n.id)
                        }
                    } header: {
                        if !group.title.isEmpty { GroupHeader(store: store, group: group) }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .focused($listFocused)
            .overlay { if store.visible.isEmpty { EmptyInbox(store: store) } }
            .onChange(of: store.selection) { _, selection in
                if selection.count == 1, let id = selection.first, id != store.focused { store.open(id) }
            }
            .onChange(of: store.focused) { _, id in
                if let id { withAnimation { proxy.scrollTo(id) } }
            }
            .onKeyPress(phases: .down) { press in
                guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
                return handle(press)
            }
            .onKeyPress(.return) {
                if let id = store.selection.first, store.selection.count == 1 { store.open(id) }
                return .handled
            }
            .onKeyPress(.escape) {
                if store.focused != nil { store.closeDetail(); return .handled }
                if store.selection.count > 1 { store.selection = []; return .handled }
                return .ignored
            }
            .onKeyPress(.delete) {
                store.markDone(store.targets)
                return .handled
            }
        }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let shift = press.modifiers.contains(.shift)
        switch press.characters.lowercased() {
        case "j": store.move(1)
        case "k": store.move(-1)
        case "e": store.markDone(store.targets)
        case "i" where shift: store.markRead(store.targets)
        case "u" where shift: store.unsubscribe(store.targets)
        case "s": store.toggleSaved(store.targets)
        case "z":
            if let tomorrow = InboxStore.snoozeOptions().first(where: { $0.label == "Tomorrow morning" }) {
                store.snooze(store.targets, until: tomorrow.date)
            }
        case "o":
            for id in store.targets { if let n = store.notification(id) { NSWorkspace.shared.open(store.webURL(n)) } }
            store.markRead(store.targets)
        case "r":
            if let id = store.targets.first {
                if store.focused != id { store.open(id) }
                store.replyFocusRequest += 1
            }
        case "?": showShortcuts = true
        default: return .ignored
        }
        return .handled
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let error = store.lastError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(GHColor.attention)
                Text(error).lineLimit(1).truncationMode(.tail)
            } else if let date = store.lastRefreshed {
                Text("Updated \(date.formatted(.relative(presentation: .named)))")
            }
            Spacer()
            if let login = store.viewer?.login {
                Avatar(url: store.viewer?.avatarUrl, size: 14)
                Text(login)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

// MARK: - Pieces

private struct ScopeTab: View {
    var scope: InboxStore.Scope
    var count: Int
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(scope.label)
                    .fontWeight(selected ? .semibold : .regular)
                    .lineLimit(1)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(selected ? AnyShapeStyle(.tint.opacity(0.25)) : AnyShapeStyle(.quaternary), in: Capsule())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(selected ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .foregroundStyle(selected ? .primary : .secondary)
    }
}

private struct FilterChip: View {
    var title: String
    var count: Int?
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                if let count, count > 0 {
                    Text("\(count)").monospacedDigit().foregroundStyle(selected ? .primary : .secondary)
                }
            }
            .font(.system(size: 11, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 9)
            .padding(.vertical, 3.5)
            .background(selected ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.5)), in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? AnyShapeStyle(.tint.opacity(0.5)) : AnyShapeStyle(.clear), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct GroupHeader: View {
    var store: InboxStore
    var group: InboxStore.Group
    @State private var hovering = false

    var body: some View {
        HStack {
            Text(group.title)
            Text("\(group.items.count)").foregroundStyle(.tertiary)
            Spacer()
            if hovering {
                Button("Done all") { store.markDone(group.items.map(\.id)) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                Button("Read all") { store.markRead(group.items.map(\.id)) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        .onHover { hovering = $0 }
    }
}

private struct EmptyInbox: View {
    var store: InboxStore

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: store.scope == .inbox && store.activeQuery.isEmpty ? "checkmark.circle" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(store.scope == .inbox && store.activeQuery.isEmpty ? AnyShapeStyle(GHColor.open) : AnyShapeStyle(.tertiary))
            Text(message).foregroundStyle(.secondary)
            if !store.activeQuery.isEmpty {
                Button("Clear filters") {
                    store.search = ""
                    store.quickFilter = .all
                }
                .buttonStyle(.link)
            }
        }
        .padding()
    }

    private var message: String {
        if !store.activeQuery.isEmpty { return "Nothing matches these filters" }
        switch store.scope {
        case .inbox: return "Inbox zero. Nice."
        case .unread: return "No unread notifications"
        case .saved: return "Nothing saved. Press S to save a thread."
        case .snoozed: return "Nothing snoozed"
        }
    }
}

struct BulkBar: View {
    var store: InboxStore

    var body: some View {
        let ids = store.targets
        HStack(spacing: 10) {
            Text("\(store.selection.count) selected").font(.callout.weight(.semibold))
            Spacer()
            Button("Done", systemImage: "checkmark") { store.markDone(ids) }
            Button("Read", systemImage: "envelope.open") { store.markRead(ids) }
            Button("Save", systemImage: "bookmark") { store.toggleSaved(ids) }
            SnoozeMenu(store: store, ids: ids)
            Button("Unsubscribe", systemImage: "bell.slash") { store.unsubscribe(ids) }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.tint.opacity(0.1))
    }
}

struct SnoozeMenu: View {
    var store: InboxStore
    var ids: [String]
    var title = "Snooze"

    var body: some View {
        Menu {
            ForEach(InboxStore.snoozeOptions(), id: \.label) { option in
                Button("\(option.label) — \(option.date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))") {
                    store.snooze(ids, until: option.date)
                }
            }
            if ids.contains(where: { id in store.notification(id).map(store.isSnoozed) ?? false }) {
                Divider()
                Button("Unsnooze") { store.unsnooze(ids) }
            }
        } label: {
            Label(title, systemImage: "moon.zzz")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Snooze: hide until later. New activity brings it back early.")
    }
}

private struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let rows: [(String, String)] = [
        ("j / k  or  ↓ / ↑", "Next / previous"),
        ("↩", "Open"),
        ("e  or  ⌫", "Mark as done (next one opens)"),
        ("⇧ I", "Mark as read"),
        ("s", "Save / unsave"),
        ("z", "Snooze until tomorrow morning"),
        ("⇧ U", "Unsubscribe"),
        ("o", "Open on github.com"),
        ("r", "Reply"),
        ("⌘↩", "Send reply"),
        ("⌘Z", "Undo done / unsubscribe"),
        ("⌘F", "Filter"),
        ("⌘R", "Refresh"),
        ("esc", "Close the conversation"),
        ("\(HotKey.display)", "Show or hide GitHub Triage from anywhere"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyboard Shortcuts").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                ForEach(rows, id: \.0) { row in
                    GridRow {
                        Text(row.0).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                        Text(row.1)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
