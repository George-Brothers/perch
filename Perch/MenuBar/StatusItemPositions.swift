import AppKit
import os

/// Where macOS puts each menu bar icon.
///
/// Every app saves a "preferred position" for each of its icons in its own
/// settings: roughly the distance from the right end of the bar, so smaller
/// means further right. macOS sorts the whole bar by these numbers.
///
/// That's how Perch moves icons without touching the mouse. It saves a new
/// number for an icon, and the icon goes there when its app next starts.
/// Perch's own items move at once, since Perch can recreate them itself.
enum StatusItemPositions {
    static let prefix = "NSStatusItem Preferred Position "
    private static let log = Logger(subsystem: "com.georgebrothers.perch", category: "positions")

    /// One icon's saved spot.
    struct Slot: Equatable {
        /// The settings domain: a bundle ID, or a sandboxed app's container plist path.
        let domain: String
        /// The icon's autosave name, the part of the key after the prefix.
        let name: String
        var value: Double?
    }

    /// The settings an app reads: its sandbox container if it has one.
    static func domain(for bundleID: String) -> String {
        let container = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Preferences/\(bundleID)")
        return FileManager.default.fileExists(atPath: container.path + ".plist") ? container.path : bundleID
    }

    /// Every saved icon position in a domain: autosave name → position.
    static func saved(in domain: String) -> [String: Double] {
        let id = domain as CFString
        CFPreferencesAppSynchronize(id)
        guard let keys = CFPreferencesCopyKeyList(id, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] else {
            return [:]
        }
        var result: [String: Double] = [:]
        for key in keys where key.hasPrefix(prefix) {
            let value = CFPreferencesCopyValue(key as CFString, id, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            if let number = value as? NSNumber {
                result[String(key.dropFirst(prefix.count))] = number.doubleValue
            }
        }
        return result
    }

    static func write(_ value: Double, for slot: Slot) {
        let id = slot.domain as CFString
        CFPreferencesSetValue((prefix + slot.name) as CFString, value as NSNumber, id,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        if !CFPreferencesAppSynchronize(id) {
            log.error("Couldn't save a position for \(slot.domain, privacy: .public)")
        }
    }

    /// Works out which saved position belongs to which icon.
    ///
    /// Macs don't say which autosave name an icon has, so Perch matches them
    /// by order: an app's icons left to right line up with its saved positions
    /// from largest to smallest. Apple's icons are matched by name. An icon
    /// that can't be matched is left out, and Perch won't try to move it.
    static func slots(for items: [MenuBarItem]) -> [String: Slot] {
        var result: [String: Slot] = [:]
        let byApp = Dictionary(grouping: items.filter { $0.isInMenuBar && $0.bundleID != nil }, by: { $0.bundleID! })
        for (bundleID, appItems) in byApp {
            let domain = domain(for: bundleID)
            let saved = saved(in: domain)
            // The clock has no saved position; skip it.
            let icons = appItems
                .filter { $0.identifier != "com.apple.menuextra.clock" }
                .sorted { $0.frame.minX < $1.frame.minX }
            if bundleID.hasPrefix("com.apple.") {
                for icon in icons {
                    if let name = appleName(for: icon, among: Array(saved.keys)) {
                        result[icon.key] = Slot(domain: domain, name: name, value: saved[name])
                    }
                }
                continue
            }
            let names = saved.sorted { $0.value > $1.value }.map(\.key)
            if names.count == icons.count {
                for (icon, name) in zip(icons, names) {
                    result[icon.key] = Slot(domain: domain, name: name, value: saved[name])
                }
            } else if icons.count == 1, names.isEmpty {
                // Never moved: AppKit's default name for an app's first icon.
                result[icons[0].key] = Slot(domain: domain, name: "Item-0", value: nil)
            } else if icons.count == 1, let name = names.first(where: { $0 == "Item-0" }) ?? (names.count == 1 ? names.first : nil) {
                result[icons[0].key] = Slot(domain: domain, name: name, value: saved[name])
            }
        }
        return result
    }

    /// Apple's autosave names, matched to an icon's identifier.
    private static func appleName(for icon: MenuBarItem, among names: [String]) -> String? {
        guard let identifier = icon.identifier else { return nil }
        let word = identifier.replacingOccurrences(of: "com.apple.menuextra.", with: "")
        let aliases: [String: [String]] = [
            "controlcenter": ["BentoBox-0", "BentoBox"],
            "focusmode": ["FocusModes"],
            "wifi": ["WiFi"],
            "nowplaying": ["NowPlaying"],
            "screenmirroring": ["ScreenMirroring"],
            "keyboardbrightness": ["KeyboardBrightness"],
            "textinput": ["TextInput"],
        ]
        let candidates = (aliases[word] ?? []) + [word]
        for candidate in candidates {
            if let match = names.first(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) { return match }
        }
        return nil
    }
}

/// Restarts apps so their icons pick up new positions.
enum AppRestarter {
    private static let log = Logger(subsystem: "com.georgebrothers.perch", category: "positions")

    /// Apps whose icons belong to a system process that macOS restarts by itself.
    static func isSystemAgent(_ bundleID: String) -> Bool {
        bundleID.hasPrefix("com.apple.")
    }

    /// Whether restarting the app could interrupt you: it has a Dock icon and
    /// windows. Those wait until the app restarts on its own.
    static func isSafeToRestart(_ app: NSRunningApplication) -> Bool {
        guard let bundleID = app.bundleIdentifier else { return false }
        if isSystemAgent(bundleID) { return true }
        return app.activationPolicy != .regular
    }

    /// Quits the app and opens it again in the background. Returns false if it wouldn't quit.
    static func restart(_ app: NSRunningApplication) async -> Bool {
        let bundleID = app.bundleIdentifier ?? ""
        if isSystemAgent(bundleID) {
            // Control Center and friends come straight back on their own.
            kill(app.processIdentifier, SIGTERM)
            return await waitUntilGone(app)
        }
        guard let url = app.bundleURL else { return false }
        app.terminate()
        guard await waitUntilGone(app) else {
            log.notice("\(bundleID, privacy: .public) didn't quit; its icon will move when it next starts")
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.hides = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return true
        } catch {
            log.error("Couldn't reopen \(bundleID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func waitUntilGone(_ app: NSRunningApplication) async -> Bool {
        for _ in 0..<100 {
            if app.isTerminated { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return app.isTerminated
    }
}
