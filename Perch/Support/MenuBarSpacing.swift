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

    /// Apps with an icon in the menu bar, other than Perch and macOS's own
    /// helpers (macOS restarts those itself; Control Center is handled separately).
    static func appsToReopen(_ items: [MenuBarItem]) -> [NSRunningApplication] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let pids = Set(items.filter { $0.section != .notShowing }.map(\.pid)).filter { $0 != ownPID }
        return pids.compactMap { NSRunningApplication(processIdentifier: $0) }
            .filter { !($0.bundleIdentifier ?? "com.apple.").hasPrefix("com.apple.") }
    }

    /// True while apps are being reopened, so Apply can't start a second round.
    private(set) static var isApplying = false

    /// Quits and reopens each app that has a menu bar icon, plus Control
    /// Center, so they all draw with the new spacing. Perch reopens itself last.
    /// Apps that don't quit (an unsaved document, say) are left running and listed.
    static func reopenMenuBarApps(_ items: [MenuBarItem]) {
        guard !isApplying else { return }
        isApplying = true
        let apps = appsToReopen(items)

        Task {
            var notReopened: [String] = []
            for app in apps {
                let name = app.localizedName ?? "An app"
                guard let url = app.bundleURL else { continue }
                app.terminate()
                // Give each app up to ten seconds to quit on its own.
                for _ in 0..<100 where !app.isTerminated {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard app.isTerminated else {
                    log.notice("\(name, privacy: .public) didn't quit; skipping it")
                    notReopened.append(name)
                    continue
                }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                configuration.addsToRecentItems = false
                do {
                    _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                } catch {
                    log.error("couldn't reopen \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    notReopened.append(name)
                }
            }
            if !notReopened.isEmpty {
                let alert = NSAlert()
                alert.messageText = "Some apps weren't reopened"
                alert.informativeText = "\(notReopened.joined(separator: ", ")) didn't quit or reopen. They'll use the new spacing the next time they open."
                NSApp.activate()
                alert.runModal()
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
