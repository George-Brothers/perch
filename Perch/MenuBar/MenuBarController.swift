import AppKit
import Combine
import os

/// Owns Perch's two menu bar items and hides or reveals the hidden icons.
///
/// Left to right the bar reads:
///
///     [hidden icons] │ [shown icons] 🐦 [Control Center, clock]
///
/// macOS has no API for hiding another app's icon. Instead the │ divider is a
/// status item that Perch stretches to 10,000 points wide. Everything to its
/// left gets pushed off the screen. Shrinking it brings those icons back.
/// Perch's own icon starts next to Control Center, so a crowded bar can never
/// push it behind the notch.
@MainActor
final class MenuBarController: NSObject, ObservableObject {
    enum Visibility {
        case collapsed
        case revealed

        var isRevealed: Bool { self == .revealed }
    }

    private enum Autosave {
        static let perch = "PerchIcon"
        static let hidden = "PerchHiddenDivider"
        static let all = [perch, hidden]
    }

    /// macOS orders status items by a saved "preferred position": smaller means
    /// further right. Control Center sits around 130. Seeding these before the
    /// items exist puts Perch just left of Control Center with the divider beside it.
    private static let seededPositions: [String: Double] = [
        Autosave.perch: 100,
        Autosave.hidden: 101,
    ]

    private static let collapsedLength: CGFloat = 10_000
    /// Starting width; the real width hugs the icon (see `updatePerchIcon`).
    private static let perchLength: CGFloat = 12
    private static let dividerLength: CGFloat = 4

    @Published private(set) var visibility: Visibility = .revealed

    var openSettings: ((SettingsPane?) -> Void)?
    var openArrange: ((NSStatusBarButton?) -> Void)?
    /// Called once Perch's items are placed, and again after a reset.
    var onReady: (() -> Void)?
    /// Handles a click on the bird instead of revealing, when the drawer is on.
    /// Returns false to fall back to revealing in the menu bar.
    var toggleDrawer: (() -> Bool)?
    /// Runs once at launch while everything is still showing, before the first hide.
    var beforeFirstHide: (() async -> Void)?

    var perchButton: NSStatusBarButton? { perchItem.button }

    private let preferences: Preferences
    private let log = Logger(subsystem: "com.georgebrothers.perch", category: "menubar")
    private var perchItem: NSStatusItem!
    private var hiddenDivider: NSStatusItem!
    private var rehider: AutoRehider!
    private var cancellables = Set<AnyCancellable>()
    private var placementAttempts = 0
    private var hasReset = false
    /// While Perch moves icons it shows and hides the bar itself; clicks wait.
    var isBusy = false

    init(preferences: Preferences) {
        self.preferences = preferences
        super.init()
        rehider = AutoRehider(preferences: preferences) { [weak self] in self?.collapse() }
        removeRetiredItems()
        seedPositionsIfNeeded()
        createItems()
        observePreferences()
        collapseOncePlaced()
    }

    // MARK: - Showing and hiding

    func toggle() {
        guard !isBusy else { return }
        visibility.isRevealed ? collapse() : reveal()
    }

    func reveal(armAutoHide: Bool = true) {
        stopMenuWatch()
        isTemporaryReveal = false
        visibility = .revealed
        apply()
        if armAutoHide { rehider.arm() } else { rehider.disarm() }
    }

    func collapse() {
        stopMenuWatch()
        isTemporaryReveal = false
        rehider.disarm()
        guard perchIsRightOfDivider() else {
            // The bird ended up on the hidden side, so hiding would hide Perch
            // itself. Put Perch back next to Control Center, once. If macOS
            // still puts it on the wrong side, stay revealed rather than loop.
            if hasReset {
                log.error("Perch's items are still out of order; staying revealed")
                visibility = .revealed
                apply()
            } else {
                log.notice("Perch's items were out of order; resetting their positions")
                hasReset = true
                resetPositions()
            }
            return
        }
        visibility = .collapsed
        apply()
    }

    /// True while the bar is out only for an icon opened from the drawer or
    /// Spotlight, so Perch hides it again when that icon's menu closes.
    private(set) var isTemporaryReveal = false

    /// Opens a hidden icon picked from the drawer or Spotlight: shows the hidden icons just
    /// long enough for its menu, then hides them again when the menu closes.
    /// Returns false when Perch is busy arranging and can't open it now.
    @discardableResult
    func openTemporarily(_ item: MenuBarItem) -> Bool {
        guard !isBusy else { return false }
        // A newer open replaces an older one that hasn't finished.
        stopMenuWatch()
        if !visibility.isRevealed {
            visibility = .revealed
            apply()
            rehider.disarm()
            isTemporaryReveal = true
        }
        pendingOpen += 1
        let request = pendingOpen
        let isCurrent = { [weak self] in
            guard let self else { return false }
            return self.pendingOpen == request && self.visibility.isRevealed && !self.isBusy
        }
        // Its menu opens wherever the icon is, so wait until it's on screen.
        whenOnScreen(item, attempts: 20) { [weak self] onScreen in
            guard let self, isCurrent() else { return }
            guard onScreen else {
                self.log.notice("\(item.displayName, privacy: .public) didn't come on screen; not opening it")
                if self.isTemporaryReveal { self.collapse() }
                return
            }
            ItemOpener.open(item, if: isCurrent)
            if self.isTemporaryReveal { self.collapseWhenMenuCloses() }
        }
        return true
    }

    /// The latest `openTemporarily` request; older ones that are still waiting give up.
    private var pendingOpen = 0

    /// Calls `action(true)` once the icon has moved on screen, checking every
    /// 50 ms for up to `attempts` tries, or `action(false)` if it never does.
    private func whenOnScreen(_ item: MenuBarItem, attempts: Int, _ action: @escaping (Bool) -> Void) {
        let onScreen = AX.frame(of: item.element).map { MenuBarGeometry.isOnScreen($0, screen: screen) } ?? false
        if onScreen {
            // A moment more for the move to settle.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                action(true)
            }
            return
        }
        guard attempts > 0 else { return action(false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.whenOnScreen(item, attempts: attempts - 1, action)
        }
    }

    private var menuWatch: Timer?

    private func stopMenuWatch() {
        menuWatch?.invalidate()
        menuWatch = nil
    }

    /// Checks twice a second while the opened menu is up, and only then.
    private func collapseWhenMenuCloses() {
        stopMenuWatch()
        var checks = 0
        var sawMenu = false
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                checks += 1
                let open = MenuBarGeometry.isMenuOpen()
                sawMenu = sawMenu || open
                // Done when the menu closed, or if none ever opened, or after 2 minutes.
                if (!open && (sawMenu || checks >= 5)) || checks > 300 {
                    self.stopMenuWatch()
                    if self.visibility.isRevealed, !self.isBusy { self.collapse() }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        menuWatch = timer
    }

    // MARK: - Geometry for the layout engine

    /// The divider's frame in screen coordinates (top-left origin), while revealed.
    func dividerFrame() -> CGRect? { screenFrame(of: hiddenDivider) }

    /// The bird's frame in screen coordinates (top-left origin).
    func perchFrame() -> CGRect? { screenFrame(of: perchItem) }

    var screen: NSScreen? { perchItem.button?.window?.screen ?? NSScreen.main }

    /// Puts Perch's items back next to Control Center, in the right order.
    func resetPositions() {
        guard !isBusy else { return }
        rehider.disarm()
        for item in [perchItem, hiddenDivider] {
            if let item { NSStatusBar.system.removeStatusItem(item) }
        }
        let defaults = UserDefaults.standard
        for name in Autosave.all {
            defaults.removeObject(forKey: Self.positionKey(name))
            defaults.removeObject(forKey: "NSStatusItem Visible \(name)")
            defaults.removeObject(forKey: "NSStatusItem VisibleCC \(name)")
        }
        visibility = .revealed
        seedPositionsIfNeeded()
        createItems()
        collapseOncePlaced()
    }

    // MARK: - Items

    private func createItems() {
        let bar = NSStatusBar.system

        perchItem = bar.statusItem(withLength: Self.perchLength)
        perchItem.autosaveName = Autosave.perch
        if let button = perchItem.button {
            button.target = self
            button.action = #selector(perchClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Perch")
            button.toolTip = "Click to show or hide icons. Right-click to arrange."
        }

        hiddenDivider = bar.statusItem(withLength: Self.dividerLength)
        hiddenDivider.autosaveName = Autosave.hidden
        if let button = hiddenDivider.button {
            button.target = self
            button.action = #selector(dividerClicked(_:))
            button.setAccessibilityLabel("Perch divider")
        }

        apply()
    }

    /// Earlier versions had an "Archived" divider. Remove its saved state.
    private func removeRetiredItems() {
        let defaults = UserDefaults.standard
        for key in ["NSStatusItem Preferred Position PerchArchivedDivider",
                    "NSStatusItem VisibleCC PerchArchivedDivider",
                    "NSStatusItem Visible PerchArchivedDivider",
                    "archivedSectionEnabled", "clickAction", "hasSeenWelcome", "rehideOnAppSwitch",
                    "searchEnabled", "searchKeyCode", "searchModifiers"] {
            defaults.removeObject(forKey: key)
        }
    }

    private func apply() {
        if visibility.isRevealed {
            hiddenDivider.length = Self.dividerLength
            hiddenDivider.button?.image = Self.dividerImage
        } else {
            hiddenDivider.button?.image = nil
            hiddenDivider.length = Self.collapsedLength
        }
        updatePerchIcon()
    }

    private func updatePerchIcon() {
        guard let button = perchItem.button else { return }
        let name = preferences.iconStyle.symbolName(revealed: visibility.isRevealed)
        // Small and tight: Perch should take as little of the bar as possible.
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        let image = (NSImage(systemSymbolName: name, accessibilityDescription: "Perch")
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: "Perch"))?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        button.image = image
        if let width = image?.size.width {
            perchItem.length = ceil(width)
        }
    }

    private static let dividerImage: NSImage = {
        let image = NSImage(size: NSSize(width: 4, height: 12), flipped: false) { _ in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 2, y: 1.5))
            path.line(to: NSPoint(x: 2, y: 10.5))
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            NSColor.black.withAlphaComponent(0.55).setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()

    // MARK: - Placement

    private static func positionKey(_ name: String) -> String {
        "NSStatusItem Preferred Position \(name)"
    }

    private func seedPositionsIfNeeded() {
        let defaults = UserDefaults.standard
        for (name, position) in Self.seededPositions where defaults.object(forKey: Self.positionKey(name)) == nil {
            defaults.set(position, forKey: Self.positionKey(name))
        }
    }

    /// macOS lays the items out a moment after they're created. Until then their
    /// frames are empty, so wait for real frames (up to about 3 seconds).
    private func collapseOncePlaced() {
        placementAttempts = 0
        // Always async, so `onReady` is wired up before it can fire.
        DispatchQueue.main.async { [weak self] in self?.waitForPlacement() }
    }

    private func waitForPlacement() {
        if screenFrame(of: perchItem) != nil || placementAttempts >= 12 {
            Task {
                if let beforeFirstHide {
                    await beforeFirstHide()
                    self.beforeFirstHide = nil
                }
                collapse()
                onReady?()
            }
            return
        }
        placementAttempts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.waitForPlacement() }
    }

    private func perchIsRightOfDivider() -> Bool {
        guard let perch = screenFrame(of: perchItem), let divider = screenFrame(of: hiddenDivider) else { return true }
        return divider.maxX <= perch.minX + 1
    }

    /// Item frame converted to screen coordinates with a top-left origin,
    /// the same space Accessibility and mouse events use.
    private func screenFrame(of item: NSStatusItem) -> CGRect? {
        guard let frame = item.button?.window?.frame, frame.height > 0 else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.maxY
        return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    // MARK: - Clicks and menu

    /// Click: show or hide icons (or the drawer). Right-click, Control-click
    /// or Option-click: Arrange, which also holds Settings and Quit.
    @objc private func perchClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
            || event?.modifierFlags.contains(.option) == true {
            openArrange?(perchItem.button)
        } else {
            menuToggle()
        }
    }

    @objc private func dividerClicked(_ sender: NSStatusBarButton) {
        guard !isBusy else { return }
        collapse()
    }

    /// With the bar already showing everything, a click hides it again
    /// rather than opening the drawer on top.
    private func menuToggle() {
        if visibility.isRevealed || toggleDrawer?() != true { toggle() }
    }

    // MARK: - Preferences

    private func observePreferences() {
        preferences.$iconStyle
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updatePerchIcon() }
            }
            .store(in: &cancellables)

        Publishers.Merge3(
            preferences.$autoRehideEnabled.map { _ in () },
            preferences.$rehideDelay.map { _ in () },
            preferences.$rehideOnClickOutside.map { _ in () }
        )
        .dropFirst(3)
        .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
        .sink { [weak self] in
            guard let self, self.visibility.isRevealed else { return }
            self.rehider.arm()
        }
        .store(in: &cancellables)
    }
}
