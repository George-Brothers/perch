import AppKit
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController!
    private var engine: LayoutEngine!
    private var settings: SettingsWindowController!
    private var arrangePanel: PanelController!
    private var drawer: DrawerController!

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
        let engine = LayoutEngine(preferences: preferences, permissions: permissions, menuBar: menuBar)
        self.menuBar = menuBar
        self.engine = engine

        settings = SettingsWindowController { navigation in
            AnyView(SettingsView(navigation: navigation, preferences: preferences,
                                 permissions: permissions, engine: engine))
        }

        arrangePanel = PanelController(model: engine) { [weak self] in
            AnyView(ArrangePanelView(
                engine: engine,
                preferences: preferences,
                permissions: permissions,
                onOpenItem: { item in
                    self?.arrangePanel.close()
                    menuBar.open(item)
                },
                onOpenSettings: {
                    self?.arrangePanel.close()
                    self?.settings.show(pane: .general)
                }
            ))
        }

        let drawer = DrawerController(engine: engine, images: IconImages(), preferences: preferences)
        self.drawer = drawer
        drawer.onOpenItem = { item in menuBar.openFromDrawer(item) }
        drawer.onOpenArrange = { [weak self] in self?.arrangePanel.open(anchor: menuBar.perchButton) }
        menuBar.toggleDrawer = { [weak self] in
            guard preferences.drawerEnabled, permissions.hasScreenRecording, permissions.hasAccessibility else {
                return false
            }
            self?.arrangePanel.close()
            self?.drawer.toggle(anchor: menuBar.perchButton)
            return true
        }

        menuBar.openSettings = { [weak self] pane in
            self?.arrangePanel.close()
            self?.settings.show(pane: pane)
        }
        menuBar.openArrange = { [weak self] anchor in
            self?.drawer.close()
            self?.arrangePanel.toggle(anchor: anchor)
        }

        // First launch: Perch needs Accessibility to arrange anything, so show
        // the Arrange list (which asks for it) instead of a tutorial.
        if !permissions.hasAccessibility {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.arrangePanel.open(anchor: menuBar.perchButton)
            }
        }
    }

    /// Opening Perch again (from Finder, Spotlight or the Dock) shows Settings,
    /// so there is always a way back in even if the menu bar icon is out of view.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show(pane: nil)
        return false
    }
}
