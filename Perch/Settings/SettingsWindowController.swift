import AppKit
import SwiftUI

/// Builds the Settings window on first use and reuses it after that.
@MainActor
final class SettingsWindowController {
    static let title = "Perch Settings"
    private let makeContent: () -> AnyView
    private var window: NSWindow?

    init(makeContent: @escaping () -> AnyView) {
        self.makeContent = makeContent
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: makeContent())
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = Self.title
            window.styleMask = [.titled, .closable]
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("PerchSettingsWindow")
            self.window = window
        } else if let window, !window.isVisible {
            // Fresh content each time Settings opens (permissions, an unapplied spacing edit).
            let origin = window.frame.origin
            let hosting = NSHostingController(rootView: makeContent())
            hosting.sizingOptions = [.preferredContentSize]
            window.contentViewController = hosting
            window.setFrameOrigin(origin)
        }

        // Perch has no Dock icon, so macOS won't always bring it forward on its own.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}
