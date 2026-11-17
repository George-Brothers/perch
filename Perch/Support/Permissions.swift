import AppKit
import ApplicationServices

/// Tracks whether Perch has Accessibility access. Perch uses it to list menu bar
/// icons and open them for you. macOS announces changes with a distributed
/// notification, so this never polls.
@MainActor
final class Permissions: ObservableObject {
    static let shared = Permissions()

    @Published private(set) var hasAccessibility = AXIsProcessTrusted()

    private var observer: NSObjectProtocol?

    private init() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            // The trust flag updates a moment after the notification arrives.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    func refresh() {
        let trusted = AXIsProcessTrusted()
        if trusted != hasAccessibility { hasAccessibility = trusted }
    }

    /// Shows macOS's own prompt, which adds Perch to the Accessibility list.
    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
