import AppKit
import Observation
import SwiftUI

/// Where the inbox is showing: the menu-bar popover, or a regular window the user popped it out into.
enum Presentation { case popover, window }

/// Owns the status item, the popover, the pop-out window, the settings window and the global hot key.
final class StatusController: NSObject, NSPopoverDelegate, NSWindowDelegate {
    let store: InboxStore
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var hotKey: HotKey?
    private let popoverBacking = PopoverBacking()

    static let compactSize = NSSize(width: 440, height: 680)
    static let expandedSize = NSSize(width: 1120, height: 720)

    init(store: InboxStore) {
        self.store = store
        super.init()
        configureButton()
        configurePopover()
        observeBadge()
        observeFocus()
        observeHotKey()
        observeOpacity()
    }

    // MARK: Status item

    private func configureButton() {
        guard let button = item.button else { return }
        button.image = Self.icon(hasItems: false)
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(statusClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "Triage"
    }

    static func icon(hasItems: Bool) -> NSImage {
        let name = hasItems ? "tray.full.fill" : "tray"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "GitHub notifications")!
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))!
        image.isTemplate = true
        return image
    }

    private func observeBadge() {
        withObservationTracking {
            _ = store.badgeCount
            _ = store.prefs.showCountInMenuBar
            _ = store.auth
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.updateBadge(); self?.observeBadge() }
        }
        updateBadge()
    }

    private func updateBadge() {
        guard let button = item.button else { return }
        let count = store.badgeCount
        button.image = Self.icon(hasItems: count > 0)
        let text = store.prefs.showCountInMenuBar && count > 0 ? " \(count)" : ""
        button.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .baselineOffset: 0.5,
        ])
        if case .signedOut = store.auth { button.appearsDisabled = true } else { button.appearsDisabled = false }
    }

    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            toggle()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh", action: #selector(refreshNow), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Open in Window", action: #selector(openWindow), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Triage", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func refreshNow() { Task { await store.refresh(force: true) } }
    @objc private func openWindow() { showWindow() }
    @objc private func openSettingsAction() { showSettings() }

    // MARK: Popover

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let host = NSHostingController(rootView: RootView(store: store, presentation: .popover, actions: actions))
        host.sizingOptions = []
        popover.contentViewController = host
        popover.contentSize = Self.compactSize
    }

    private var actions: WindowActions {
        WindowActions(
            popOut: { [weak self] in self?.showWindow() },
            settings: { [weak self] in self?.showSettings() },
            dismiss: { [weak self] in self?.dismiss() })
    }

    /// Popover grows to fit the conversation when a thread is open, and shrinks back when it's closed.
    private func observeFocus() {
        withObservationTracking {
            _ = store.focused
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.resizePopover(); self?.observeFocus() }
        }
    }

    private func resizePopover() {
        let size = store.focused == nil ? Self.compactSize : Self.expandedSize
        if popover.contentSize != size { popover.contentSize = size }
    }

    func toggle() {
        if let window, window.isVisible {
            if window.isKeyWindow { window.orderOut(nil) } else { NSApp.activate(); window.makeKeyAndOrderFront(nil) }
            return
        }
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }

    private func showPopover() {
        guard let button = item.button else { return }
        // A menu-bar manager (Hidden Bar, Bartender, Ice) may have pushed the icon offscreen: use the window then.
        guard let frame = button.window?.frame, button.window?.isVisible == true, frame.width > 0, frame.height > 0,
              NSScreen.screens.contains(where: { $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) }) else {
            showWindow()
            return
        }
        resizePopover()
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        installBacking()
        Task { await store.refresh() }
    }

    func dismiss() {
        if popover.isShown { popover.performClose(nil) }
    }

    /// From a banner click or the hot key: show the inbox, optionally on a thread.
    func show(thread id: String?) {
        if let id {
            store.scope = .inbox
            store.quickFilter = .all
            store.search = ""
            store.open(id)
        }
        if let window, window.isVisible {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else if !popover.isShown {
            showPopover()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        // Keep selection; drop the detail so the next open starts compact.
        if window?.isVisible != true { store.closeDetail() }
    }

    // MARK: Background opacity

    /// Puts the backing view behind the popover's content, in the frame view that also draws the arrow,
    /// so the whole popover (arrow included) gets the same tint.
    private func installBacking() {
        guard let frameView = popover.contentViewController?.view.window?.contentView?.superview else { return }
        popoverBacking.alpha = store.prefs.popoverOpacity
        guard popoverBacking.superview !== frameView else { return }
        popoverBacking.removeFromSuperview()
        popoverBacking.frame = frameView.bounds
        popoverBacking.autoresizingMask = [.width, .height]
        frameView.addSubview(popoverBacking, positioned: .below, relativeTo: popover.contentViewController?.view.window?.contentView)
    }

    private func observeOpacity() {
        withObservationTracking {
            _ = store.prefs.popoverOpacity
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.popoverBacking.alpha = self.store.prefs.popoverOpacity
                self.observeOpacity()
            }
        }
    }

    // MARK: Window

    func showWindow() {
        dismiss()
        if window == nil {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: Self.expandedSize),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Triage"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 760, height: 480)
            w.contentViewController = NSHostingController(rootView: RootView(store: store, presentation: .window, actions: actions))
            w.setContentSize(Self.expandedSize)
            w.center()
            w.setFrameAutosaveName("InboxWindow")
            w.delegate = self
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) == window { store.closeDetail() }
    }

    // MARK: Settings

    func showSettings() {
        dismiss()
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Triage Settings"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: SettingsView(store: store))
            w.center()
            settingsWindow = w
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Hot key

    private func observeHotKey() {
        withObservationTracking {
            _ = store.prefs.hotKeyEnabled
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observeHotKey() }
        }
        if store.prefs.hotKeyEnabled {
            if hotKey == nil { hotKey = HotKey { [weak self] in self?.toggle() } }
        } else {
            hotKey = nil
        }
    }
}

/// A window-colored fill at the chosen opacity. Drawn (not a layer color) so it follows light and dark.
final class PopoverBacking: NSView {
    var alpha: Double = 0 {
        didSet { if alpha != oldValue { isHidden = alpha <= 0.001; needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(alpha).setFill()
        dirtyRect.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Window-level actions the SwiftUI views can trigger.
struct WindowActions {
    var popOut: () -> Void
    var settings: () -> Void
    var dismiss: () -> Void
}
