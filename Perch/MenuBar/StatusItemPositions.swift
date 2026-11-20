import AppKit
import os

/// Where macOS puts each menu bar icon.
///
/// Every app saves a "preferred position" for each of its icons in its own
/// settings: roughly the distance from the right end of the bar, so smaller
/// means further right. macOS sorts the whole bar by these numbers.
///
/// That's how Perch moves icons without touching the mouse. It saves a new
/// number for an icon, and the icon goes there the next time Control Center
/// starts (see `AppRestarter`). Perch's own items move at once, since Perch
/// can recreate them itself.
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
        /// In a sandboxed app's container. macOS asks the user before every
        /// change there, so Perch never writes it (see `LayoutEngine.plan`).
        var isPrivate: Bool { domain.hasPrefix("/") }
    }

    /// The settings an app reads: its sandbox container if it's sandboxed.
    static func domain(for bundleID: String) -> String {
        guard isSandboxed(bundleID) else { return bundleID }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Preferences/\(bundleID)").path
    }

    private static let sandboxLock = NSLock()
    private nonisolated(unsafe) static var sandboxed: [String: Bool] = [:]

    /// From the app's own signature, never by looking inside its container:
    /// macOS guards other apps' containers, and touching one makes it ask the
    /// user for permission while the caller waits.
    static func isSandboxed(_ bundleID: String) -> Bool {
        sandboxLock.lock()
        if let known = sandboxed[bundleID] { sandboxLock.unlock(); return known }
        sandboxLock.unlock()
        var result = false
        if let url = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.bundleURL {
            var code: SecStaticCode?
            var info: CFDictionary?
            if SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
               SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
               let entitlements = (info as? [String: Any])?[kSecCodeInfoEntitlementsDict as String] as? [String: Any] {
                result = entitlements["com.apple.security.app-sandbox"] as? Bool ?? false
            }
        }
        sandboxLock.lock()
        sandboxed[bundleID] = result
        sandboxLock.unlock()
        return result
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

    /// Every write and undo runs here, one at a time, so an undo always lands
    /// after a write that was slow to finish, never before it.
    private static let queue = DispatchQueue(label: "com.georgebrothers.perch.positions", qos: .userInitiated)

    /// Saves a new spot off the main thread. False if macOS didn't save it or
    /// it didn't finish within `limit`.
    static func write(_ value: Double, for slot: Slot, within limit: TimeInterval) async -> Bool {
        await run(within: limit) { write(value, for: slot) }
    }

    /// Puts back the spot `slot` had (or removes it, if it had none). Runs
    /// after any write still under way for it. False if it didn't take.
    static func restore(_ slot: Slot, within limit: TimeInterval = 5) async -> Bool {
        await run(within: limit) { write(slot.value, for: slot) }
    }

    private static func run(within limit: TimeInterval, _ body: @escaping () -> Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            let lock = NSLock()
            var resumed = false
            let finish: (Bool) -> Void = { done in
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: done)
            }
            queue.async { finish(body()) }
            DispatchQueue.global().asyncAfter(deadline: .now() + limit) { finish(false) }
        }
    }

    /// False if macOS didn't save it.
    private static func write(_ value: Double?, for slot: Slot) -> Bool {
        let id = slot.domain as CFString
        CFPreferencesSetValue((prefix + slot.name) as CFString, value.map { $0 as NSNumber }, id,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesAppSynchronize(id) else {
            log.error("Couldn't save a position for \(slot.domain, privacy: .public)")
            return false
        }
        return true
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
            // A sandboxed app's saved spots are in its container, which Perch
            // doesn't read (see `isSandboxed`). Its icons sit between their
            // neighbors anyway, which is all the order needs.
            let saved = domain == bundleID ? saved(in: domain) : [:]
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

/// Restarts Control Center. On macOS 26 it draws every app's menu bar icons
/// and places each at its saved spot when it starts, so this applies saved
/// spots without restarting any app. It has no windows and macOS starts it
/// again by itself; Apple's icons blink for a moment.
enum AppRestarter {
    /// Kept in Perch's settings: Perch relaunches itself after a spacing change,
    /// and launchd doesn't tell apps when Control Center started.
    private static let lastRestartKey = "lastControlCenterRestart"
    @MainActor private static var lastRestart: Date? {
        get { UserDefaults.standard.object(forKey: lastRestartKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastRestartKey) }
    }
    private static let log = Logger(subsystem: "com.georgebrothers.perch", category: "positions")

    @MainActor static func restartControlCenter() async {
        // launchd waits 10 s before bringing back a process that ran for less
        // than that, leaving the bar without icons; space restarts out.
        func running() -> NSRunningApplication? {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first
        }
        var saidWaiting = false
        while true {
            // A time in the future means the clock changed; don't wait on it.
            if let started = lastRestart, Date().timeIntervalSince(started) >= 0,
               Date().timeIntervalSince(started) < 10.5 {
                try? await Task.sleep(for: .seconds(10.5 - Date().timeIntervalSince(started)))
                continue
            }
            // That wait can be long; don't restart while the screen is
            // locked (wait for the unlock, which can be overnight), or close
            // a menu you opened meanwhile (menus close soon; check twice a second).
            if screenIsLocked {
                log.notice("restart waiting for the screen to unlock")
                await waitForUnlock()
                continue
            }
            if MenuBarGeometry.isMenuOpen() {
                if !saidWaiting { log.notice("restart waiting: a menu is open") }
                saidWaiting = true
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }
            break
        }
        guard let app = running() else { return }
        lastRestart = Date()
        kill(app.processIdentifier, SIGTERM)
        // Gone, then back with its icons drawn.
        for _ in 0..<60 where !app.isTerminated { try? await Task.sleep(for: .milliseconds(50)) }
        for _ in 0..<240 {
            if let next = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first,
               next.processIdentifier != app.processIdentifier, next.isFinishedLaunching {
                // launchd counts its 10 s from the new launch, so the spacing does too.
                lastRestart = Date()
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: .milliseconds(300))
    }

    /// Waits for the screen to unlock; returns at once if it isn't locked.
    static func waitForUnlock() async {
        // Listen before looking, so an unlock in between isn't missed. A slow
        // check once a minute covers a notice that never comes.
        let center = DistributedNotificationCenter.default()
        let wakes = AsyncStream<Void> { continuation in
            let observer = center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil,
                                              queue: nil) { _ in continuation.yield() }
            let ticker = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    continuation.yield()
                }
            }
            continuation.onTermination = { _ in
                center.removeObserver(observer)
                ticker.cancel()
            }
        }
        guard screenIsLocked else { return }
        for await _ in wakes {
            // The lock flag can lag the notice by a moment.
            for _ in 0..<6 where screenIsLocked {
                try? await Task.sleep(for: .milliseconds(500))
            }
            if !screenIsLocked { return }
        }
    }

    /// Whether the login window is covering the screen.
    static var screenIsLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
