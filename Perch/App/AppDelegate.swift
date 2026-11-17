import AppKit
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController!
    private var settings: SettingsWindowController!

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let preferences = Preferences.shared
        let menuBar = MenuBarController(preferences: preferences)
        self.menuBar = menuBar

        settings = SettingsWindowController { navigation in
            AnyView(SettingsView(navigation: navigation, preferences: preferences, menuBar: menuBar))
        }
        menuBar.openSettings = { [weak self] pane in
            self?.settings.show(pane: pane)
        }

        if !preferences.hasSeenWelcome {
            preferences.hasSeenWelcome = true
            settings.show(pane: .sections)
        }
    }

    /// Opening Perch again (from Finder, Spotlight or the Dock) shows Settings,
    /// so there is always a way back in even if the menu bar icon is out of view.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show(pane: nil)
        return false
    }
}
