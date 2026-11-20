import AppKit
import os

/// The gap macOS leaves around every menu bar icon.
///
/// macOS reads two hidden settings, `NSStatusItemSpacing` and
/// `NSStatusItemSelectionPadding`, when an app starts. Lowering them fits more
/// icons in the same bar. Apps pick up a change the next time they open;
/// Apple's icons change when Control Center restarts.
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

    /// True while the new spacing is being applied, so Apply can't start twice.
    private(set) static var isApplying = false

    /// Restarts Control Center, which redraws Apple's icons with the new
    /// spacing, then Perch, for its own items. Other apps' icons change the
    /// next time each app opens: Perch never restarts other apps.
    static func apply() {
        guard !isApplying else { return }
        isApplying = true
        Task {
            log.notice("applying spacing \(current, privacy: .public)")
            await AppRestarter.restartControlCenter()
            Permissions.shared.relaunch()
        }
    }
}
