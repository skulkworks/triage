import AppKit
import SwiftUI

/// Plain AppKit entry point: the app is a status item with a popover, no SwiftUI scenes to manage.
@main
enum TriageMain {
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = InboxStore()
    private var status: StatusController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("-triageSelfTest") {
            Task { await SelfTest.run(); NSApp.terminate(nil) }
            return
        }
        installMainMenu()
        Notifier.shared.setUp()
        status = StatusController(store: store)
        Notifier.shared.onOpen = { [weak self] id in self?.status?.show(thread: id.isEmpty ? nil : id) }
        Notifier.shared.onDone = { [weak self] id in self?.store.markDone([id]) }
        Notifier.shared.onRead = { [weak self] id in self?.store.markRead([id]) }
        store.start()
        _ = Updater.shared  // starts Sparkle's scheduled checks
        // Screenshot helpers: -triageDemo (made-up inbox, see DemoData), -triageShowOnLaunch, -triageWindow,
        // -triageOpenThread <id>, -triageScope <tab>, -triageSearch <query>, -triageAppearance light|dark.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "-triageAppearance"), args.indices.contains(i + 1) {
            NSApp.appearance = NSAppearance(named: args[i + 1] == "light" ? .aqua : .darkAqua)
        }
        if args.contains("-triageWindow") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.status?.showWindow() }
        } else if args.contains("-triageShowOnLaunch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.status?.show(thread: nil) }
        }
        if let i = args.firstIndex(of: "-triageOpenThread"), args.indices.contains(i + 1) {
            let id = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.status?.show(thread: id) }
        }
        if let i = args.firstIndex(of: "-triageScope"), args.indices.contains(i + 1), let scope = InboxStore.Scope(rawValue: args[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.store.scope = scope }
        }
        if let i = args.firstIndex(of: "-triageSearch"), args.indices.contains(i + 1) {
            let query = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.store.search = query }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !store.pending.isEmpty || store.committing > 0 else { return .terminateNow }
        Task {
            await store.flushPending()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        status?.show(thread: nil)
        return false
    }

    /// Menu-bar apps have no visible menu, but text fields still need Edit's key equivalents (⌘C, ⌘V, ⌘Z…).
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Triage", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    @objc private func openSettings() { status?.showSettings() }
    @objc private func checkForUpdates() { Updater.shared.checkForUpdates() }
}
