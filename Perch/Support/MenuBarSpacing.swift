import AppKit
import os

/// The gap macOS leaves around every menu bar icon.
///
/// macOS reads two hidden settings, `NSStatusItemSpacing` and
/// `NSStatusItemSelectionPadding`, when an app starts. Lowering them fits more
/// icons in the same bar. Apps pick up a change the next time they open, so
/// Perch offers to reopen the apps that have menu bar icons.
@MainActor
enum MenuBarSpacing {
    /// What macOS uses when the settings aren't set.
    static let systemDefault = 16
    static let range = 4...16

    private static let keys = ["NSStatusItemSpacing", "NSStatusItemSelectionPadding"]
    private static let log = Logger(subsystem: "com.georgebrothers.perch", category: "spacing")

    /// The current spacing, or the system default when it isn't set.
    static var current: Int {
        let value = CFPreferencesCopyValue(
            keys[0] as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost
        )
        return (value as? NSNumber)?.intValue ?? systemDefault
    }

    /// Saves the spacing for every app. The default removes the settings.
    static func set(_ spacing: Int) {
        let value: CFPropertyList? = spacing >= systemDefault ? nil : (spacing as NSNumber)
        for key in keys {
            CFPreferencesSetValue(
                key as CFString, value, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost
            )
        }
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }

    /// Apps with an icon in the menu bar, other than Perch and macOS's own.
    static func appsToReopen(_ items: [MenuBarItem]) -> [NSRunningApplication] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let system: Set<String> = ["com.apple.controlcenter", "com.apple.systemuiserver"]
        let pids = Set(items.filter { $0.section != .notShowing }.map(\.pid)).filter { $0 != ownPID }
        return pids.compactMap { NSRunningApplication(processIdentifier: $0) }
            .filter { !system.contains($0.bundleIdentifier ?? "") }
    }

    /// Quits and reopens each app that has a menu bar icon, plus Control
    /// Center, so they all draw with the new spacing. Perch reopens itself last.
    static func reopenMenuBarApps(_ items: [MenuBarItem]) {
        let apps = appsToReopen(items)

        Task {
            for app in apps {
                guard let url = app.bundleURL else { continue }
                app.terminate()
                // Give each app up to three seconds to quit on its own.
                for _ in 0..<30 where !app.isTerminated {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard app.isTerminated else {
                    log.notice("\(app.localizedName ?? "an app", privacy: .public) didn't quit; skipping it")
                    continue
                }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                configuration.addsToRecentItems = false
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            }
            // macOS restarts Control Center by itself.
            let killall = Process()
            killall.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            killall.arguments = ["ControlCenter"]
            try? killall.run()
            try? await Task.sleep(for: .milliseconds(800))
            Permissions.shared.relaunch()
        }
    }
}
