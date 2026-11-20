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
    /// Kept narrow so Perch takes as little of the bar as possible.
    private static let perchLength: CGFloat = 18
    private static let dividerLength: CGFloat = 6

    @Published private(set) var visibility: Visibility = .revealed

    var openSettings: ((SettingsPane?) -> Void)?
    var openArrange: ((NSStatusBarButton?) -> Void)?
    /// Called once Perch's items are placed, and again after a reset.
    var onReady: (() -> Void)?

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
        visibility = .revealed
        apply()
        if armAutoHide { rehider.arm() } else { rehider.disarm() }
    }

    func collapse() {
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

    /// Opens another app's icon from the Arrange list. Hidden icons are revealed
    /// first, so their menu opens in the right place.
    func open(_ item: MenuBarItem) {
        guard !isBusy else { return }
        let needsReveal = item.section == .hidden && !visibility.isRevealed
        if needsReveal { reveal() }
        DispatchQueue.main.asyncAfter(deadline: .now() + (needsReveal ? 0.3 : 0.05)) {
            ItemOpener.open(item)
        }
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
            button.toolTip = "Click to show or hide icons. Right-click for more."
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
                    "archivedSectionEnabled", "clickAction", "hasSeenWelcome", "rehideOnAppSwitch"] {
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
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let image = (NSImage(systemSymbolName: name, accessibilityDescription: "Perch")
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: "Perch"))?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        button.image = image
    }

    private static let dividerImage: NSImage = {
        let image = NSImage(size: NSSize(width: 4, height: 14), flipped: false) { _ in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 2, y: 1.5))
            path.line(to: NSPoint(x: 2, y: 12.5))
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
            collapse()
            onReady?()
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

    @objc private func perchClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if event?.modifierFlags.contains(.option) == true {
            openArrange?(perchItem.button)
        } else {
            toggle()
        }
    }

    @objc private func dividerClicked(_ sender: NSStatusBarButton) {
        guard !isBusy else { return }
        collapse()
    }

    private func showMenu() {
        let menu = NSMenu()
        let toggleTitle = visibility.isRevealed ? "Hide Icons" : "Show Hidden Icons"
        menu.addItem(withTitle: toggleTitle, action: #selector(menuToggle), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Arrange Icons…", action: #selector(menuArrange), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Perch", action: #selector(menuQuit), keyEquivalent: "q").target = self

        perchItem.menu = menu
        perchItem.button?.performClick(nil)
        perchItem.menu = nil
    }

    @objc private func menuToggle() { toggle() }
    @objc private func menuArrange() { openArrange?(perchItem.button) }
    @objc private func menuSettings() { openSettings?(nil) }
    @objc private func menuQuit() { NSApp.terminate(nil) }

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
