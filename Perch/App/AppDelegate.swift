import AppKit
import CoreSpotlight
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
    private var welcomePanel: PanelController!
    private let images = IconImages()
    private var spotlight: SpotlightIndex!
    private var cancellables = Set<AnyCancellable>()

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
                maxWidth: min((menuBar.screen?.visibleFrame.width ?? 900) - 60, 900),
                onOpenItem: { item in
                    self?.arrangePanel.close()
                    Task { if await self?.open(item) == false { NSSound.beep() } }
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
            guard preferences.drawerEnabled, permissions.hasScreenRecording else { return }
            // Always rescan, so Arrange and Settings show current icons even with a menu open.
            let items = await engine.rescan()
            // The drawer may have been turned off during the scan.
            guard preferences.drawerEnabled, !MenuBarGeometry.isMenuOpen() else { return }
            await images.capture(items.filter { $0.section != .notShowing && images.needsCapture($0) })
        }
        menuBar.beforeFirstHide = captureVisible
        menuBar.$visibility
            .removeDuplicates()
            .filter(\.isRevealed)
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { _ in
                // Not while an icon opened from the drawer or search is showing its menu.
                guard menuBar.visibility.isRevealed, !menuBar.isTemporaryReveal, !engine.isArranging else { return }
                Task { await captureVisible() }
            }
            .store(in: &cancellables)
        images.refresh = {
            if preferences.drawerEnabled && permissions.hasScreenRecording {
                await captureVisible()
            } else {
                _ = await engine.rescan()
            }
        }
        arrangePanel.onOpen = {
            engine.holdsMoves = true
            Task { await images.refresh?() }
        }
        // Moves that need the bar to reset happen together once Arrange closes.
        arrangePanel.onClose = { engine.holdsMoves = false }
        // Perch's icon stays in the bar until it can tell empty menu bar space
        // from an icon, which needs Accessibility.
        permissions.$hasAccessibility
            .removeDuplicates()
            .sink { menuBar.hasAccessibility = $0 }
            .store(in: &cancellables)
        // Adding or removing Perch's item moves the others; Arrange should show it.
        preferences.$barItem
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { _ in engine.refresh() }
            .store(in: &cancellables)
        // Turning the drawer on (with permission already granted): show the
        // hidden icons for a moment so the drawer has pictures of them.
        preferences.$drawerEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { on in
                // Turned off: forget the pictures.
                guard on else { return images.clear() }
                guard permissions.hasScreenRecording, !engine.isArranging,
                      !menuBar.visibility.isRevealed else { return }
                Task {
                    menuBar.reveal()
                    try? await Task.sleep(for: .milliseconds(400))
                    await captureVisible()
                    // The reveal also starts the usual capture; let it finish first.
                    await images.waitUntilIdle()
                    if menuBar.visibility.isRevealed { menuBar.collapse() }
                }
            }
            .store(in: &cancellables)

        let drawer = DrawerController(engine: engine, images: images, preferences: preferences)
        self.drawer = drawer
        drawer.onOpenItem = { [weak self] item, point in
            await self?.openFromBar(item, at: point) ?? true
        }
        drawer.onOpenArrange = { [weak self] in self?.arrangePanel.open(anchor: menuBar.anchor) }
        menuBar.toggleDrawer = { [weak self] in
            guard permissions.hasAccessibility else { return false }
            self?.closePanels(except: .drawer)
            self?.drawer.toggle(anchor: menuBar.anchor)
            return true
        }


        // Every icon is a Spotlight result; picking one opens its menu.
        spotlight = SpotlightIndex(engine: engine)

        menuBar.openSettings = { [weak self] pane in
            self?.closePanels(except: nil)
            self?.settings.show(pane: pane)
        }
        menuBar.openArrange = { [weak self] in
            self?.closePanels(except: .arrange)
            self?.arrangePanel.toggle(anchor: menuBar.anchor)
        }

        // First launch: a short welcome, which also asks for Accessibility.
        // It counts as seen once it closes with Accessibility allowed, so
        // someone who goes off to allow it sees it again when they come back.
        welcomePanel = PanelController(model: engine) { [weak self] in
            AnyView(WelcomeView(permissions: permissions) { self?.welcomePanel.close() })
        }
        welcomePanel.onOpen = {}
        welcomePanel.onClose = {
            if permissions.hasAccessibility { UserDefaults.standard.set(true, forKey: WelcomeView.shownKey) }
        }
        if !UserDefaults.standard.bool(forKey: WelcomeView.shownKey) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.showWelcome() }
        }
        permissions.$hasAccessibility
            .removeDuplicates()
            .dropFirst()
            .filter { $0 }
            .sink { [weak self] _ in
                guard !UserDefaults.standard.bool(forKey: WelcomeView.shownKey) else { return }
                self?.showWelcome()
            }
            .store(in: &cancellables)
    }

    private enum Panel { case drawer, arrange, welcome }

    /// Only one of Perch's panels is open at a time.
    private func closePanels(except kept: Panel?) {
        if kept != .drawer { drawer.close() }
        if kept != .arrange { arrangePanel.close() }
        if kept != .welcome { welcomePanel?.close() }
    }

    private func showWelcome() {
        closePanels(except: .welcome)
        welcomePanel.open(anchor: menuBar.anchor)
    }

    // MARK: - Actions for Spotlight and Shortcuts

    /// Opens Perch's bar. Never closes it.
    func showHiddenIcons() {
        if drawer.isOpen { return }
        if menuBar.toggleDrawer?() != true { showArrange() }
    }

    /// Opens Arrange (from Spotlight); running it again leaves it open.
    func showArrange() {
        guard !arrangePanel.isOpen else { return }
        closePanels(except: .arrange)
        arrangePanel.open(anchor: menuBar.anchor)
    }

    func icons() async -> [MenuBarItem] {
        await engine.rescan().filter { $0.section != .notShowing }
    }

    /// Opens the icon with this key.
    func openIcon(key: String) async -> OpenResult {
        guard Permissions.shared.hasAccessibility else { return .noPermission }
        guard let item = await icons().first(where: { $0.key == key }) else { return .gone }
        return await open(item) ? .opened : .busy
    }

    enum OpenResult { case opened, gone, busy, noPermission }

    /// Opens an icon's menu. A hidden icon opens right where you are (under
    /// Perch's bar, or under the menu bar), without coming into the menu bar.
    /// Only if that fails does it come out just until its menu closes.
    @discardableResult
    private func open(_ item: MenuBarItem, at point: NSPoint? = nil) async -> Bool {
        guard item.section == .hidden else {
            ItemOpener.open(item)
            return true
        }
        if await MenuMirror.open(item, at: point ?? defaultMenuPoint()) != .failed { return true }
        return menuBar.openTemporarily(item)
    }

    /// Opens an icon clicked in Perch's bar. True when Perch's bar should
    /// close: after you pick something, or if the icon had to come out into
    /// the menu bar. Closing its menu without picking leaves the bar open.
    private func openFromBar(_ item: MenuBarItem, at point: NSPoint) async -> Bool {
        switch await MenuMirror.open(item, at: point) {
        case .picked: return true
        case .dismissed, .panel: return false
        case .failed:
            menuBar.openTemporarily(item)
            return true
        }
    }

    /// Just under the menu bar, where hidden icons start.
    private func defaultMenuPoint() -> NSPoint {
        guard let anchor = menuBar.anchor() else {
            let screen = NSScreen.main?.frame ?? .zero
            return NSPoint(x: screen.midX, y: screen.maxY - 30)
        }
        return NSPoint(x: anchor.minX - 8, y: anchor.minY - 4)
    }

    /// Picking a menu bar icon in Spotlight opens its menu.
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let key = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String
        else { return false }
        openedFromSpotlight = Date()
        Task {
            if await openIcon(key: key) != .opened { NSSound.beep() }
        }
        return true
    }

    /// When Spotlight last opened an icon, so the reopen that comes with it
    /// doesn't also show Settings.
    private var openedFromSpotlight: Date?

    /// Opening Perch again (from Finder, Spotlight or the Dock) shows Settings,
    /// so there is always a way back in even if the menu bar icon is out of view.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let opened = openedFromSpotlight, Date().timeIntervalSince(opened) < 2 { return false }
        settings.show(pane: nil)
        return false
    }
}
