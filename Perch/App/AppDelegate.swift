import AppKit
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController!
    private var settings: SettingsWindowController!
    private var panel: PanelController!

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
        let permissions = Permissions.shared
        let menuBar = MenuBarController(preferences: preferences)
        self.menuBar = menuBar

        settings = SettingsWindowController { navigation in
            AnyView(SettingsView(navigation: navigation, preferences: preferences,
                                 permissions: permissions, menuBar: menuBar))
        }
        menuBar.openSettings = { [weak self] pane in
            self?.panel.close()
            self?.settings.show(pane: pane)
        }

        let panelModel = PanelModel(permissions: permissions, menuBar: menuBar)
        panel = PanelController(model: panelModel) { [weak self] in
            AnyView(PanelView(
                model: panelModel,
                permissions: permissions,
                menuBar: menuBar,
                preferences: preferences,
                onOpenItem: { item in
                    self?.panel.close()
                    menuBar.open(item)
                },
                onToggleBar: {
                    self?.panel.close()
                    menuBar.toggle(showArchived: false)
                },
                onOpenSettings: {
                    self?.panel.close()
                    self?.settings.show(pane: nil)
                }
            ))
        }
        menuBar.togglePanel = { [weak self] anchor in
            self?.panel.toggle(anchor: anchor)
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
