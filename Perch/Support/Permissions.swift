import AppKit
import ApplicationServices

/// Tracks Perch's two permissions.
///
/// - Accessibility (required): lets Perch see, open and move menu bar icons.
///   macOS announces changes with a distributed notification, so this never polls.
/// - Screen Recording (optional, only for the drawer): lets Perch draw other
///   apps' icons. Perch never asks for it unless you turn the drawer on.
@MainActor
final class Permissions: ObservableObject {
    static let shared = Permissions()

    @Published private(set) var hasAccessibility = AXIsProcessTrusted()
    @Published private(set) var hasScreenRecording = CGPreflightScreenCaptureAccess()

    private var observers: [NSObjectProtocol] = []

    private init() {
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            // The trust flag updates a moment after the notification arrives.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { self?.refresh() }
            }
        })
        // Coming back from System Settings is when a grant is most likely.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
    }

    func refresh() {
        let trusted = AXIsProcessTrusted()
        if trusted != hasAccessibility { hasAccessibility = trusted }
        let recording = CGPreflightScreenCaptureAccess()
        if recording != hasScreenRecording { hasScreenRecording = recording }
    }

    /// Shows macOS's own prompt, which adds Perch to the Accessibility list.
    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
    }

    func openAccessibilitySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    /// Asks macOS for Screen Recording. macOS shows its prompt only the first
    /// time; after that the switch lives in System Settings, so open it there.
    func requestScreenRecording() {
        // The first request shows macOS's prompt and returns false right away;
        // opening System Settings then would cover the prompt.
        let key = "askedForScreenRecording"
        let askedBefore = UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        if !CGRequestScreenCaptureAccess(), askedBefore {
            openPrivacyPane("Privacy_ScreenCapture")
        }
        refresh()
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// macOS applies a new Screen Recording grant only after the app restarts.
    func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this copy to quit (up to 5 s), then open a fresh one.
        let pid = ProcessInfo.processInfo.processIdentifier
        task.arguments = ["-c", "for i in $(seq 50); do kill -0 $1 2>/dev/null || break; sleep 0.1; done; /usr/bin/open -n \"$0\"", path, String(pid)]
        try? task.run()
        NSApp.terminate(nil)
    }
}
