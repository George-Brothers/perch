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
    private var openSearchAction: (() -> Void)?

    /// For App Intents (Spotlight and Shortcuts), which run inside Perch.
    private(set) static weak var shared: AppDelegate?

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
        Self.shared = self
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
                    self?.open(item)
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
            // Skip while a menu is open: its icon would be pictured highlighted.
            guard preferences.drawerEnabled, permissions.hasScreenRecording,
                  !MenuBarGeometry.isMenuOpen() else { return }
            let items = await engine.rescan()
            await images.capture(items.filter { $0.section != .notShowing && images.needsCapture($0) })
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
        arrangePanel.onOpen = {
            Task {
                if preferences.drawerEnabled && permissions.hasScreenRecording {
                    await captureVisible()
                } else {
                    _ = await engine.rescan()
                }
            }
        }
        // Turning the drawer on (with permission already granted): show the
        // hidden icons for a moment so the drawer has pictures of them.
        preferences.$drawerEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { on in
                // Turned off: forget the pictures.
                guard on else { return images.clear() }
                guard permissions.hasScreenRecording, !menuBar.isBusy, !engine.isArranging,
                      !menuBar.visibility.isRevealed else { return }
                Task {
                    menuBar.reveal(armAutoHide: false)
                    try? await Task.sleep(for: .milliseconds(400))
                    await captureVisible()
                    if menuBar.visibility.isRevealed, !menuBar.isBusy { menuBar.collapse() }
                }
            }
            .store(in: &cancellables)

        let drawer = DrawerController(engine: engine, images: images, preferences: preferences)
        self.drawer = drawer
        drawer.onOpenItem = { item in menuBar.openTemporarily(item) }
        drawer.onOpenArrange = { [weak self] in self?.arrangePanel.open(anchor: menuBar.perchButton) }
        menuBar.toggleDrawer = { [weak self] in
            guard preferences.drawerEnabled, permissions.hasScreenRecording, permissions.hasAccessibility else {
                return false
            }
            self?.closePanels(except: .drawer)
            self?.drawer.toggle(anchor: menuBar.perchButton)
            return true
        }

        // Search: a shortcut (⌥⇧Space by default) finds and opens any icon.
        let searchModel = self.searchModel
        searchPanel = PanelController(model: engine) { [weak self] in
            AnyView(SearchView(model: searchModel, engine: engine) { item in
                self?.searchPanel.close()
                self?.open(item)
            })
        }
        searchPanel.onOpen = {
            searchModel.reset()
            engine.refresh()
        }
        let openSearch = { [weak self] in
            guard let self else { return }
            // Without Accessibility there's nothing to search; show why instead.
            guard permissions.hasAccessibility else {
                self.closePanels(except: .arrange)
                self.arrangePanel.open(anchor: menuBar.perchButton)
                return
            }
            self.closePanels(except: .search)
            self.searchPanel.toggle(anchor: menuBar.perchButton)
        }
        menuBar.openSearch = openSearch
        openSearchAction = openSearch
        menuBar.searchShortcut = {
            preferences.searchEnabled && !preferences.searchShortcutTaken ? preferences.searchShortcut : nil
        }
        menuBar.usesDrawer = {
            preferences.drawerEnabled && permissions.hasScreenRecording && permissions.hasAccessibility
        }
        hotKey = HotKey(action: openSearch)
        Publishers.CombineLatest3(preferences.$searchEnabled, preferences.$searchShortcut, preferences.$isRecordingShortcut)
            .sink { [weak self] enabled, shortcut, recording in
                guard let self else { return }
                let registered = self.hotKey.register(enabled && !recording ? shortcut : nil)
                if !recording { preferences.searchShortcutTaken = enabled && !registered }
            }
            .store(in: &cancellables)

        menuBar.openSettings = { [weak self] pane in
            self?.closePanels(except: nil)
            self?.settings.show(pane: pane)
        }
        menuBar.openArrange = { [weak self] anchor in
            self?.closePanels(except: .arrange)
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

    private enum Panel { case drawer, arrange, search }

    /// Only one of Perch's panels is open at a time.
    private func closePanels(except kept: Panel?) {
        if kept != .drawer { drawer.close() }
        if kept != .arrange { arrangePanel.close() }
        if kept != .search { searchPanel.close() }
    }

    // MARK: - Actions for Spotlight and Shortcuts

    /// Opens the drawer, or shows hidden icons in the bar. Never hides them.
    func showHiddenIcons() {
        if drawer.isOpen { return }
        if menuBar.toggleDrawer?() == true { return }
        menuBar.reveal()
    }

    /// Opens search; running it again leaves search open.
    func searchIcons() {
        if searchPanel.isOpen { return }
        openSearchAction?()
    }

    func icons() async -> [MenuBarItem] {
        await engine.rescan().filter { $0.section != .notShowing }
    }

    /// Opens the icon with this key. Returns false if it's gone.
    func openIcon(key: String) async -> Bool {
        guard let item = await icons().first(where: { $0.key == key }) else { return false }
        return open(item)
    }

    /// Opens an icon's menu. A hidden icon comes out just until its menu closes.
    /// False when Perch is busy arranging.
    @discardableResult
    private func open(_ item: MenuBarItem) -> Bool {
        if item.section == .hidden {
            return menuBar.openTemporarily(item)
        }
        ItemOpener.open(item)
        return true
    }

    /// Opening Perch again (from Finder, Spotlight or the Dock) shows Settings,
    /// so there is always a way back in even if the menu bar icon is out of view.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show(pane: nil)
        return false
    }
}
