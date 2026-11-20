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
    private var guide: HostedWindow!
    private var setup: HostedWindow!
    private var setupStart: SetupView.Step = .welcome
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

        settings = SettingsWindowController { [weak self] in
            AnyView(SettingsView(preferences: preferences, permissions: permissions, engine: engine,
                                 onShowGuide: { self?.showGuide() }))
        }

        arrangePanel = PanelController(model: engine) { [weak self] in
            AnyView(ArrangePanelView(
                engine: engine,
                preferences: preferences,
                permissions: permissions,
                images: images,
                overBar: { self?.overBarGeometry() },
                onOpenItem: { item in
                    self?.arrangePanel.close()
                    Task { await self?.open(item) }
                },
                onOpenSettings: {
                    self?.arrangePanel.close()
                    self?.settings.show()
                },
                onDone: { self?.arrangePanel.close() }
            ))
        }
        // Over the menu bar, Arrange covers the bar from the screen's left edge.
        arrangePanel.topLeft = { [weak self] in
            guard let self, preferences.arrangeStyle == .over, let screen = self.menuBar.screen else { return nil }
            return NSPoint(x: screen.frame.minX, y: screen.frame.maxY)
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
            engine.hold(true, for: .arrange)
            Task { await images.refresh?() }
        }
        // Moves that need the bar to reset happen together once Arrange closes.
        arrangePanel.onClose = { engine.hold(false, for: .arrange) }
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

        menuBar.openArrange = { [weak self] in
            self?.closePanels(except: .arrange)
            self?.arrangePanel.toggle(anchor: menuBar.anchor)
        }

        // The Guide: every topic, from Settings → Guide or the end of setup.
        guide = HostedWindow(title: "Perch Guide", size: GuideView.size) { [weak self] close in
            AnyView(GuideView(
                permissions: permissions,
                preferences: preferences,
                onShowHiddenIcons: { self?.showHiddenIcons() },
                onOpenArrange: { self?.showArrange() },
                onOpenSettings: { self?.settings.show() },
                onDone: close
            ))
        }

        // First launch: setup, which also asks for Accessibility. It counts
        // as done once it closes with Accessibility allowed, so someone who
        // goes off to allow it sees it again when they come back.
        setup = HostedWindow(title: "Perch Setup", size: SetupView.size) { [weak self] close in
            AnyView(SetupView(
                permissions: permissions,
                preferences: preferences,
                startAt: self?.setupStart ?? .welcome,
                onOpenGuide: { self?.showGuide() },
                onDone: close
            ))
        }
        setup.onClose = {
            if permissions.hasAccessibility { UserDefaults.standard.set(true, forKey: Self.setupDoneKey) }
        }
        if !UserDefaults.standard.bool(forKey: Self.setupDoneKey) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.showSetup() }
        }
        permissions.$hasAccessibility
            .removeDuplicates()
            .dropFirst()
            .filter { $0 }
            .sink { [weak self] _ in
                // Back from System Settings with Accessibility on: bring setup
                // forward, at the step that asked (if it was closed meanwhile).
                guard !UserDefaults.standard.bool(forKey: Self.setupDoneKey) else { return }
                self?.setupStart = .access
                self?.showSetup()
            }
            .store(in: &cancellables)
    }

    private enum Panel { case drawer, arrange }

    /// Only one of Perch's panels is open at a time.
    private func closePanels(except kept: Panel?) {
        if kept != .drawer { drawer.close() }
        if kept != .arrange { arrangePanel.close() }
    }

    /// Set once setup closes with Accessibility allowed. (The key is from
    /// when setup was the welcome tour, so nobody sees it twice.)
    private static let setupDoneKey = "welcomeShown"

    func showGuide() {
        closePanels(except: nil)
        guide.show()
    }

    func showSetup() {
        closePanels(except: nil)
        setup.show()
    }

    // MARK: - Actions for Spotlight and Shortcuts

    /// Opens Perch's bar. Never closes it.
    func showHiddenIcons() {
        if drawer.isOpen { return }
        if menuBar.toggleDrawer?() != true { showArrange() }
    }

    /// Where Arrange goes over the menu bar: from the left edge (or the notch)
    /// to just left of the clock and Control Center, which stay visible.
    private func overBarGeometry() -> OverBarGeometry? {
        guard let screen = menuBar.screen else { return nil }
        let left = screen.frame.minX
        let fixed = engine.items.filter {
            $0.isInMenuBar && $0.isFixed && $0.frame.minX >= left && $0.frame.minX < screen.frame.maxX
        }
        return OverBarGeometry(
            width: screen.frame.width,
            barHeight: MenuBarGeometry.menuBarHeight(for: screen),
            bandStart: screen.auxiliaryTopRightArea.map { $0.minX - left } ?? 0,
            bandEnd: (fixed.map(\.frame.minX).min() ?? screen.frame.maxX) - left - 4
        )
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
        await open(item)
        return .opened
    }

    enum OpenResult { case opened, gone, noPermission }

    /// Opens an icon's menu. A hidden icon opens right where you are (under
    /// Perch's bar, or under the menu bar), without coming into the menu bar.
    /// Only if that fails does it come out just until its menu closes.
    private func open(_ item: MenuBarItem, at point: NSPoint? = nil) async {
        guard item.section == .hidden else {
            ItemOpener.open(item)
            return
        }
        if await MenuMirror.open(item, at: point ?? defaultMenuPoint()) != .failed { return }
        menuBar.openTemporarily(item)
    }

    /// Opens an icon clicked in Perch's bar. True when Perch's bar should
    /// close: after you pick something, or if the icon had to come out into
    /// the menu bar. Closing its menu without picking leaves the bar open.
    private func openFromBar(_ item: MenuBarItem, at point: NSPoint) async -> Bool {
        switch await MenuMirror.open(item, at: point, stillWanted: { [weak self] in self?.drawer.isOpen == true }) {
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

    /// A move that's under way finishes before Perch quits (up to 25 s): its
    /// new spots are already saved, and quitting midway would leave them for
    /// the next restart to apply unchecked. Closing Arrange lets held moves go.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard engine != nil else { return .terminateNow }
        arrangePanel.close()
        guard engine.isArranging || engine.hasQueuedMoves else { return .terminateNow }
        Task { @MainActor in
            for _ in 0..<125 where engine.isArranging || engine.hasQueuedMoves {
                try? await Task.sleep(for: .milliseconds(200))
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Opening Perch again (from Finder, Spotlight or the Dock) shows Settings,
    /// so there is always a way back in even if the menu bar icon is out of view.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let opened = openedFromSpotlight, Date().timeIntervalSince(opened) < 2 { return false }
        settings.show()
        return false
    }
}
