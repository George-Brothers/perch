import AppKit

/// Hides revealed icons again. It only exists while icons are revealed:
/// `arm()` starts a timer and event listeners, `disarm()` tears them all down.
@MainActor
final class AutoRehider {
    private let preferences: Preferences
    private let rehide: () -> Void

    private var delayTimer: Timer?
    private var retryTimer: Timer?
    private var clickMonitor: Any?
    private var appSwitchObserver: NSObjectProtocol?
    private var isArmed = false

    init(preferences: Preferences, rehide: @escaping () -> Void) {
        self.preferences = preferences
        self.rehide = rehide
    }

    func arm() {
        disarm()
        guard preferences.autoRehideEnabled else { return }
        isArmed = true

        let timer = Timer(timeInterval: preferences.rehideDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.attempt() }
        }
        RunLoop.main.add(timer, forMode: .common)
        delayTimer = timer

        if preferences.rehideOnClickOutside {
            // Global monitors see clicks in other apps only, never clicks on Perch's own items.
            clickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard !MenuBarGeometry.isInMenuBar(NSEvent.mouseLocation) else { return }
                    self?.attempt()
                }
            }
        }

        if preferences.rehideOnAppSwitch {
            appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.attempt() }
            }
        }
    }

    func disarm() {
        isArmed = false
        delayTimer?.invalidate()
        delayTimer = nil
        retryTimer?.invalidate()
        retryTimer = nil
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        if let appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appSwitchObserver)
            self.appSwitchObserver = nil
        }
    }

    /// Hide now, unless a menu is open or the pointer is in the menu bar.
    /// In that case check again once a second until the coast is clear.
    private func attempt() {
        guard isArmed else { return }
        if shouldWait {
            startRetrying()
        } else {
            rehide()
        }
    }

    private var shouldWait: Bool {
        MenuBarGeometry.isMenuOpen() || MenuBarGeometry.isInMenuBar(NSEvent.mouseLocation)
    }

    private func startRetrying() {
        guard retryTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isArmed, !self.shouldWait else { return }
                self.rehide()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
    }
}
