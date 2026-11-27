import AppKit
import SwiftUI

enum SettingsTab: Int, CaseIterable {
    case general, notifications, snippets, filters, account, about
}

/// The Settings window's tabs. An AppKit tab view controller with toolbar tabs, the standard Mac
/// Settings window: a SwiftUI TabView in this window hid every tab behind the toolbar's » button.
final class SettingsTabController: NSTabViewController {
    init(store: InboxStore) {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        func add(_ title: String, _ symbol: String, _ view: some View) {
            let host = NSHostingController(rootView: view.frame(width: 560, height: 480))
            host.sizingOptions = .preferredContentSize
            host.title = title  // the window shows the selected tab's name
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            addTabViewItem(item)
        }
        // In SettingsTab order.
        add("General", "gearshape", GeneralSettings(prefs: store.prefs))
        add("Notifications", "bell.badge", NotificationSettings(prefs: store.prefs))
        add("Snippets", "text.bubble", SnippetSettings(store: store))
        add("Filters", "line.3.horizontal.decrease", FilterSettings(store: store))
        add("Account", "person.crop.circle", AccountSettings(store: store))
        add("About", "info.circle", AboutSettings())
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func select(_ tab: SettingsTab) { selectedTabViewItemIndex = tab.rawValue }
}

private struct AboutSettings: View {
    private static let links: [(title: String, url: URL)] = [
        ("Triage on skulkworks.dev", URL(string: "https://skulkworks.dev/triage")!),
        ("Release notes", URL(string: "https://skulkworks.dev/triage/changelog")!),
        ("Source on GitHub", URL(string: "https://github.com/skulkworks/triage")!),
        ("Privacy policy", URL(string: "https://skulkworks.dev/privacy")!),
    ]

    var body: some View {
        let info = Bundle.main.infoDictionary
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 88, height: 88)
                        .accessibilityHidden(true)
                    Text("Triage").font(.title2.weight(.semibold))
                    Text("Version \(Bundle.main.shortVersion)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .textSelection(.enabled)
                    Text("Your GitHub notifications inbox in the menu bar: read, reply and triage without opening a browser.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                    Button("Check for Updates…") { Updater.shared.checkForUpdates() }
                        .disabled(!Updater.shared.canCheck)
                        .padding(.top, 6)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section {
                ForEach(Self.links, id: \.title) { link in
                    Link(destination: link.url) {
                        HStack {
                            Text(link.title)
                            Spacer()
                            Image(systemName: "arrow.up.forward").foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("\(info?["NSHumanReadableCopyright"] as? String ?? "© SkulkWorks") · Apache License 2.0")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
    }
}

private struct GeneralSettings: View {
    @Bindable var prefs: Preferences
    @State private var launchAtLogin = Preferences.shared.launchAtLogin
    @State private var checksAutomatically = Updater.shared.automaticallyChecks

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in prefs.launchAtLogin = v }
                Toggle("Show or hide with \(HotKey.display) from any app", isOn: $prefs.hotKeyEnabled)
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $checksAutomatically)
                    .onChange(of: checksAutomatically) { _, v in Updater.shared.automaticallyChecks = v }
                LabeledContent("Version \(Bundle.main.shortVersion)") {
                    Button("Check Now") { Updater.shared.checkForUpdates() }
                        .disabled(!Updater.shared.canCheck)
                }
            }
            Section("Menu bar") {
                Toggle("Show a count next to the icon", isOn: $prefs.showCountInMenuBar)
                Picker("Count", selection: $prefs.badgeUnreadOnly) {
                    Text("Unread threads").tag(true)
                    Text("Everything in the inbox").tag(false)
                }
                .disabled(!prefs.showCountInMenuBar)
                LabeledContent("Background") {
                    Slider(value: $prefs.popoverOpacity, in: 0...1) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text("Clear")
                    } maximumValueLabel: {
                        Text("Solid")
                    }
                    .frame(maxWidth: 240)
                }
                .help("How see-through the inbox dropdown is")
            }
            Section("Triage") {
                Toggle("Mark as read when opened", isOn: $prefs.markReadOnOpen)
                Toggle("Open the next thread after Done, Snooze or Unsubscribe", isOn: $prefs.advanceAfterAction)
                Picker("Undo window", selection: $prefs.undoSeconds) {
                    Text("3 seconds").tag(3.0)
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                }
                Picker("Group by", selection: $prefs.groupBy) {
                    ForEach(GroupBy.allCases) { Text($0.label).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct NotificationSettings: View {
    @Bindable var prefs: Preferences

    var body: some View {
        Form {
            Section {
                Toggle("Show a macOS notification for new activity", isOn: $prefs.desktopNotifications)
            } footer: {
                Text("Banners have Done and Mark as read buttons. Snoozed threads stay quiet.")
            }
            Section("Notify me when the reason is") {
                ForEach(Preferences.notifiableReasons, id: \.self) { reason in
                    Toggle(Reason.label(reason), isOn: Binding(
                        get: { prefs.notifyReasons.contains(reason) },
                        set: { on in if on { prefs.notifyReasons.insert(reason) } else { prefs.notifyReasons.remove(reason) } }))
                }
            }
            .disabled(!prefs.desktopNotifications)
        }
        .formStyle(.grouped)
    }
}

private struct SnippetSettings: View {
    @Bindable var store: InboxStore
    @State private var selection: UUID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.local.snippets) { s in Text(s.name).tag(s.id) }
                        .onMove { store.local.snippets.move(fromOffsets: $0, toOffset: $1) }
                }
                HStack {
                    Button("Add", systemImage: "plus") {
                        let s = LocalState.Snippet(name: "New snippet", body: "")
                        store.local.snippets.append(s)
                        selection = s.id
                    }
                    Button("Remove", systemImage: "minus") {
                        store.local.snippets.removeAll { $0.id == selection }
                        selection = nil
                    }
                    .disabled(selection == nil)
                    Spacer()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(width: 180)
            Divider()
            if let index = store.local.snippets.firstIndex(where: { $0.id == selection }) {
                Form {
                    TextField("Name", text: $store.local.snippets[index].name)
                    TextEditor(text: $store.local.snippets[index].body)
                        .font(.system(size: 13))
                        .frame(minHeight: 200)
                }
                .padding()
            } else {
                Text("Saved replies you can drop into a comment from the Snippets menu.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct FilterSettings: View {
    @Bindable var store: InboxStore

    var body: some View {
        Form {
            Section {
                ForEach($store.local.filters) { $f in
                    HStack {
                        TextField("Name", text: $f.name).frame(width: 130)
                        TextField("Query", text: $f.query).font(.system(.body, design: .monospaced))
                        Button {
                            store.local.filters.removeAll { $0.id == f.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add Filter") { store.local.filters.append(.init(name: "New filter", query: "is:unread")) }
            } footer: {
                Text("""
                Terms: repo:owner/name, org:owner, reason:mention,assign (or participating), author:login, label:bug, \
                is:unread / read / issue / pr / discussion / release / ci / open / closed / merged / draft / finished / bot / saved. \
                Commas mean OR, spaces mean AND, a leading - negates (-is:release). Other words match the title.
                """)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AccountSettings: View {
    var store: InboxStore
    @State private var token = ""

    var body: some View {
        Form {
            Section("Signed in") {
                if let v = store.viewer {
                    HStack {
                        Avatar(url: v.avatarUrl, size: 28)
                        VStack(alignment: .leading) {
                            Text(v.login).font(.headline)
                            Text(store.tokenSource == .githubCLI ? "Using the GitHub CLI's login" : "Using a saved token (Keychain)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Sign Out") { store.signOut() }
                    }
                } else {
                    Text("Not signed in").foregroundStyle(.secondary)
                }
            }
            Section {
                SecureField("Personal access token", text: $token)
                Button("Use This Token") {
                    let t = token
                    token = ""
                    Task { await store.signIn(token: t) }
                }
                .disabled(token.isEmpty)
            } header: {
                Text("Use a different token")
            } footer: {
                Text("Classic tokens need the notifications and repo scopes. A saved token takes priority over the GitHub CLI.")
            }
        }
        .formStyle(.grouped)
    }
}

extension Bundle {
    /// "0.1.0 (1)"
    var shortVersion: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
