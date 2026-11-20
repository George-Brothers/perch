import AppKit
import Combine
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController!
    private var engine: LayoutEngine!
    private var settings: SettingsWindowController!
    private var arrangePanel: PanelController!
    private var drawer: DrawerController!
    private let images = IconImages()
    private let searchModel = SearchModel()
    private var searchPanel: PanelController!
    private var hotKey: HotKey!
    private var cancellables = Set<AnyCancellable>()

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
        let images = self.images
        let preferences = Preferences.shared
        let permissions = Permissions.shared
        let menuBar = MenuBarController(preferences: preferences)
        let engine = LayoutEngine(preferences: preferences, permissions: permissions, menuBar: menuBar)
        self.menuBar = menuBar
        self.engine = engine

        settings = SettingsWindowController { navigation in
            AnyView(SettingsView(navigation: navigation, preferences: preferences,
                                 permissions: permissions, engine: engine, images: images))
        }

        arrangePanel = PanelController(model: engine) { [weak self] in
            AnyView(ArrangePanelView(
                engine: engine,
                preferences: preferences,
                permissions: permissions,
                images: images,
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

        // The drawer shows pictures of hidden icons. macOS can only picture icons
        // that are on screen, so take them whenever the bar is showing everything.
        let captureVisible: () async -> Void = {
            guard preferences.drawerEnabled, permissions.hasScreenRecording else { return }
            let items = await engine.rescan()
            await images.capture(items.filter { $0.section != .notShowing })
        }
        menuBar.beforeFirstHide = captureVisible
        engine.whileRevealed = captureVisible
        menuBar.$visibility
            .removeDuplicates()
            .filter(\.isRevealed)
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { _ in
                guard menuBar.visibility.isRevealed, !engine.isArranging else { return }
                Task { await captureVisible() }
            }
            .store(in: &cancellables)
        arrangePanel.onOpen = { Task { await captureVisible() } }

        let drawer = DrawerController(engine: engine, images: images, preferences: preferences)
        self.drawer = drawer
        drawer.onOpenItem = { item in menuBar.openTemporarily(item) }
        drawer.onOpenArrange = { [weak self] in self?.arrangePanel.open(anchor: menuBar.perchButton) }
        menuBar.toggleDrawer = { [weak self] in
            guard preferences.drawerEnabled, permissions.hasScreenRecording, permissions.hasAccessibility else {
                return false
            }
            self?.arrangePanel.close()
            self?.drawer.toggle(anchor: menuBar.perchButton)
            return true
        }

        // Search: a shortcut (⌥⇧Space by default) finds and opens any icon.
        let searchModel = self.searchModel
        searchPanel = PanelController(model: engine) { [weak self] in
            AnyView(SearchView(model: searchModel, engine: engine) { item in
                self?.searchPanel.close()
                if item.section == .hidden {
                    menuBar.openTemporarily(item)
                } else {
                    ItemOpener.open(item)
                }
            })
        }
        searchPanel.onOpen = {
            searchModel.reset()
            engine.refresh()
        }
        let openSearch = { [weak self] in
            guard let self, permissions.hasAccessibility else { return }
            self.drawer.close()
            self.arrangePanel.close()
            self.searchPanel.toggle(anchor: menuBar.perchButton)
        }
        menuBar.openSearch = openSearch
        menuBar.searchShortcutTitle = {
            preferences.searchEnabled ? preferences.searchShortcut.displayString : nil
        }
        hotKey = HotKey(action: openSearch)
        Publishers.CombineLatest(preferences.$searchEnabled, preferences.$searchShortcut)
            .sink { [weak self] enabled, shortcut in
                self?.hotKey.register(enabled ? shortcut : nil)
            }
            .store(in: &cancellables)

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
