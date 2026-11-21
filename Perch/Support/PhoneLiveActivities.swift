import Foundation
import os

/// Your iPhone's Live Activities in the Mac's menu bar (an app's running
/// status, like T3 Code's agents or a ride on its way).
///
/// macOS places these itself, so Perch can't move or hide just one. It can
/// turn them all on or off: the same switch as System Settings, which
/// Control Center reads when it starts. Turning them off on the iPhone, per
/// app, is the only way to keep some.
enum PhoneLiveActivities {
    private static let domain = "com.apple.controlcenter" as CFString
    private static let key = "RemoteLiveActivitiesEnabled" as CFString
    private static let log = Logger(subsystem: "com.georgebrothers.perch", category: "live-activities")

    /// On unless you or Perch turned them off. macOS shows them by default.
    static var isEnabled: Bool {
        CFPreferencesAppSynchronize(domain)
        let value = CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return (value as? Bool) ?? true
    }

    /// Saves the switch and restarts Control Center so it takes effect.
    /// Apple's icons blink once; your apps don't restart.
    @MainActor static func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled else { return }
        CFPreferencesSetValue(key, enabled as CFBoolean, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesAppSynchronize(domain)
        log.notice("iPhone Live Activities \(enabled ? "on" : "off", privacy: .public)")
        await AppRestarter.restartControlCenter()
    }
}
