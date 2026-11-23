import Foundation
import Observation
import ServiceManagement

enum GroupBy: String, CaseIterable, Identifiable {
    case date, repository, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .date: "Date"
        case .repository: "Repository"
        case .none: "None"
        }
    }
}

/// User settings, kept in UserDefaults.
@Observable
final class Preferences {
    static let shared = Preferences()
    private let d = UserDefaults.standard

    var groupBy: GroupBy { didSet { d.set(groupBy.rawValue, forKey: "groupBy") } }
    var markReadOnOpen: Bool { didSet { d.set(markReadOnOpen, forKey: "markReadOnOpen") } }
    var showCountInMenuBar: Bool { didSet { d.set(showCountInMenuBar, forKey: "showCountInMenuBar") } }
    var desktopNotifications: Bool { didSet { d.set(desktopNotifications, forKey: "desktopNotifications") } }
    var notifyReasons: Set<String> { didSet { d.set(Array(notifyReasons), forKey: "notifyReasons") } }
    var hotKeyEnabled: Bool { didSet { d.set(hotKeyEnabled, forKey: "hotKeyEnabled") } }
    var advanceAfterAction: Bool { didSet { d.set(advanceAfterAction, forKey: "advanceAfterAction") } }
    var undoSeconds: Double { didSet { d.set(undoSeconds, forKey: "undoSeconds") } }
    /// Badge counts unread threads only, or everything in the inbox.
    var badgeUnreadOnly: Bool { didSet { d.set(badgeUnreadOnly, forKey: "badgeUnreadOnly") } }
    /// How solid the menu-bar popover's background is: 0 is the system's glass, 1 is an opaque window color.
    var popoverOpacity: Double { didSet { d.set(popoverOpacity, forKey: "popoverOpacity") } }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Launch at login: \(error)")
            }
        }
    }

    static let notifiableReasons = ["mention", "team_mention", "assign", "review_requested", "author", "comment", "state_change", "manual", "subscribed", "security_alert", "ci_activity"]

    private init() {
        d.register(defaults: [
            "groupBy": GroupBy.date.rawValue,
            "markReadOnOpen": true,
            "showCountInMenuBar": true,
            "desktopNotifications": true,
            "notifyReasons": ["mention", "team_mention", "assign", "review_requested", "author", "comment"],
            "hotKeyEnabled": true,
            "advanceAfterAction": true,
            "undoSeconds": 5.0,
            "badgeUnreadOnly": true,
            "popoverOpacity": 0.0,
        ])
        groupBy = GroupBy(rawValue: d.string(forKey: "groupBy") ?? "") ?? .date
        markReadOnOpen = d.bool(forKey: "markReadOnOpen")
        showCountInMenuBar = d.bool(forKey: "showCountInMenuBar")
        desktopNotifications = d.bool(forKey: "desktopNotifications")
        notifyReasons = Set(d.stringArray(forKey: "notifyReasons") ?? [])
        hotKeyEnabled = d.bool(forKey: "hotKeyEnabled")
        advanceAfterAction = d.bool(forKey: "advanceAfterAction")
        undoSeconds = d.double(forKey: "undoSeconds")
        badgeUnreadOnly = d.bool(forKey: "badgeUnreadOnly")
        popoverOpacity = d.double(forKey: "popoverOpacity")
    }
}
