import AppKit
import Combine
import os

/// Owns Perch's two menu bar items and hides or reveals the hidden icons.
///
/// Left to right the bar reads:
///
///     [hidden icons] │ [shown icons] 🐦 [Control Center, clock]
///
/// The 🐦 is optional (in Settings): it can be a thin line, or nothing
/// at all. Clicking empty menu bar space does the same as clicking it.
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

    /// Each of Perch's items has two names it switches between. To move an
    /// item, Perch creates it again under the other name at the new position,
    /// then removes the old one: removing an item makes macOS forget its
    /// position, so the new one can't reuse the old name.
    private enum Autosave {
        static let perchNames = ["PerchIcon", "PerchIconB"]
        static let dividerNames = ["PerchHiddenDivider", "PerchHiddenDividerB"]
        static let all = perchNames + dividerNames
        private static let perchKey = "perchItemName"
        private static let dividerKey = "dividerItemName"

        static var perch: String { current(perchNames, perchKey) }
        static var hidden: String { current(dividerNames, dividerKey) }

        /// Switches to the other name and returns it.
        static func switchPerch() -> String { next(perchNames, perchKey) }
        static func switchDivider() -> String { next(dividerNames, dividerKey) }

        static func resetNames() {
            UserDefaults.standard.removeObject(forKey: perchKey)
            UserDefaults.standard.removeObject(forKey: dividerKey)
        }

        private static func current(_ names: [String], _ key: String) -> String {
            UserDefaults.standard.string(forKey: key).flatMap { names.contains($0) ? $0 : nil } ?? names[0]
        }

        private static func next(_ names: [String], _ key: String) -> String {
            let name = current(names, key) == names[0] ? names[1] : names[0]
            UserDefaults.standard.set(name, forKey: key)
            return name
        }
    }

    /// macOS orders status items by a saved "preferred position": smaller means
    /// further right. Control Center sits around 130. Seeding these before the
    /// items exist puts Perch just left of Control Center with the divider beside it.
    private static var seededPositions: [String: Double] {
        [Autosave.perch: 100, Autosave.hidden: 101]
    }

    private static let collapsedLength: CGFloat = 10_000
    /// Starting width; the real width hugs the icon (see `updatePerchIcon`).
    private static let perchLength: CGFloat = 12
    private static let dividerLength: CGFloat = 4

    @Published private(set) var visibility: Visibility = .revealed

    var openArrange: (() -> Void)?
    /// Called once Perch's items are placed, and again after a reset.
    var onReady: (() -> Void)?
    /// Something right of the divider appeared, went or changed width: a Live
    /// Activity, say, which macOS adds without any app launching. What fits
    /// may have changed.
    var onBarChange: (() -> Void)?
    /// Opens or closes Perch's bar. Returns false if it can't open (no Accessibility).
    var toggleDrawer: (() -> Bool)?
    /// Runs once at launch while everything is still showing, before the first hide.
    var beforeFirstHide: (() async -> Void)?

    /// Where Perch's panels hang from: Perch's own item, or when there's
    /// nothing in the bar, the spot where the hidden icons start.
    var anchor: PanelAnchor {
        { [weak self] in self?.anchorFrame() }
    }

    /// False until Perch has Accessibility. Without it Perch can't tell empty
    /// menu bar space from an icon, so its icon stays in the bar.
    var hasAccessibility = AXIsProcessTrusted() {
        didSet {
            guard hasAccessibility != oldValue else { return }
            updatePerchIcon()
            if hasAccessibility, waitsForAccessibility {
                waitsForAccessibility = false
                Task { await firstHide() }
            } else if !hasAccessibility {
                // Perch can no longer see the icons or open hidden ones: show
                // them all, and hide again once the permission is back.
                waitsForAccessibility = true
                hasPlaced = false
                reveal()
            }
        }
    }

    /// Places the divider from a real look at the bar, before Perch first
    /// hides anything (set by the layout engine). False if it couldn't look
    /// yet (a menu was open, say).
    var placeFirst: (() async -> Bool)?
    /// Perch started without Accessibility, so it hasn't hidden anything yet.
    private var waitsForAccessibility = false
    /// The divider has been placed from a real look at the bar, so hiding is safe.
    private var hasPlaced = false
    private var isFirstHiding = false

    /// What's in the bar for Perch right now.
    private var barItem: PerchBarItem { hasAccessibility ? preferences.barItem : .icon }

    private let preferences: Preferences
    private let log = Logger(subsystem: "com.georgebrothers.perch", category: "menubar")
    private var perchItem: NSStatusItem!
    private var hiddenDivider: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()
    private var placementAttempts = 0
    private var hasReset = false
    private var barClickMonitor: Any?
    private var dividerMoveObserver: NSObjectProtocol?
    /// The divider's right edge when last seen, in screen points.
    private var dividerRightEdge: CGFloat?
    /// Perch just moved one of its own items; the bar is still settling, and
    /// what moves until then is Perch's doing, not a new icon.
    private var settlesAt = Date.distantPast

    init(preferences: Preferences) {
        self.preferences = preferences
        super.init()
        removeRetiredItems()
        seedPositionsIfNeeded()
        createItems()
        observePreferences()
        watchEmptyBarClicks()
        collapseOncePlaced()
    }

    // MARK: - Showing and hiding

    /// Shows every icon in the bar. Perch does this only at launch, to picture
    /// icons for its bar, and as a last resort for an icon it can't open otherwise.
    func reveal() {
        stopMenuWatch()
        isTemporaryReveal = false
        visibility = .revealed
        apply()
    }

    func collapse() {
        stopMenuWatch()
        isTemporaryReveal = false
        // Every caller, not just the bird: without Accessibility, or before the
        // divider has a real spot, hiding could hide the icons you want.
        guard hasAccessibility, hasPlaced else {
            log.notice("not hiding: Perch hasn't placed the divider with Accessibility yet")
            visibility = .revealed
            apply()
            return
        }
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
        // A newer open replaces an older one that hasn't finished.
        stopMenuWatch()
        if !visibility.isRevealed {
            visibility = .revealed
            apply()
            isTemporaryReveal = true
        }
        pendingOpen += 1
        let request = pendingOpen
        let isCurrent = { [weak self] in
            guard let self else { return false }
            return self.pendingOpen == request && self.visibility.isRevealed
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
                    if self.visibility.isRevealed { self.collapse() }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        menuWatch = timer
    }

    // MARK: - Geometry for the layout engine

    /// The divider's frame in screen coordinates (top-left origin), while revealed.
    func dividerFrame() -> CGRect? { screenFrame(of: hiddenDivider) }

    /// Perch's item's frame in screen coordinates (top-left origin), or nil
    /// when it isn't in the bar.
    func perchFrame() -> CGRect? { perchItem.isVisible ? screenFrame(of: perchItem) : nil }

    /// The display whose menu bar holds Perch's items.
    var screen: NSScreen? {
        if perchItem.isVisible, let screen = perchItem.button?.window?.screen { return screen }
        return anchorFrame().flatMap(PanelAnchorScreen.of) ?? NSScreen.main
    }

    /// Bottom-left origin, like window frames. The divider's right edge is
    /// where the hidden icons end, even while it's stretched off screen.
    private func anchorFrame() -> NSRect? {
        if perchItem.isVisible, let frame = perchItem.button?.window?.frame, frame.height > 0 { return frame }
        guard let frame = hiddenDivider.button?.window?.frame, frame.height > 0 else { return nil }
        return NSRect(x: frame.maxX - 1, y: frame.minY, width: 1, height: frame.height)
    }

    /// Puts Perch's items back next to Control Center, in the right order.
    func resetPositions() {
        for item in [perchItem, hiddenDivider] {
            if let item { NSStatusBar.system.removeStatusItem(item) }
        }
        let defaults = UserDefaults.standard
        for name in Autosave.all {
            defaults.removeObject(forKey: Self.positionKey(name))
            defaults.removeObject(forKey: "NSStatusItem Visible \(name)")
            defaults.removeObject(forKey: "NSStatusItem VisibleCC \(name)")
        }
        Autosave.resetNames()
        visibility = .revealed
        seedPositionsIfNeeded()
        createItems()
        collapseOncePlaced()
    }

    // MARK: - Items

    private func createItems() {
        makePerchItem()
        makeDivider()
        apply()
    }

    private func makePerchItem() {
        perchItem = NSStatusBar.system.statusItem(withLength: Self.perchLength)
        perchItem.autosaveName = Autosave.perch
        if let button = perchItem.button {
            button.target = self
            button.action = #selector(perchClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Perch")
            button.toolTip = "Click to show or hide icons. Right-click to arrange."
        }
    }

    private func makeDivider() {
        hiddenDivider = NSStatusBar.system.statusItem(withLength: Self.dividerLength)
        hiddenDivider.autosaveName = Autosave.hidden
        if let button = hiddenDivider.button {
            button.target = self
            button.action = #selector(dividerClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Perch divider")
            button.toolTip = "Click to hide icons. Right-click to arrange."
        }
        watchDivider()
    }

    /// How long the bar takes to finish sliding icons around after Perch moves an item.
    private static let settleTime: TimeInterval = 2

    /// macOS lines the icons up from the right, so the divider's right edge
    /// moves only when the icons right of it change: one appears or goes, or
    /// one changes width. Perch growing or shrinking the divider itself moves
    /// its left edge, not this one. It costs nothing: AppKit reports it.
    private func watchDivider() {
        if let dividerMoveObserver { NotificationCenter.default.removeObserver(dividerMoveObserver) }
        dividerMoveObserver = nil
        // A new divider starts a new baseline.
        dividerRightEdge = nil
        settlesAt = Date().addingTimeInterval(Self.settleTime)
        guard let window = hiddenDivider.button?.window else { return }
        dividerMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, let window else { return }
                let edge = window.frame.maxX
                defer { self.dividerRightEdge = edge }
                guard Date() >= self.settlesAt,
                      let last = self.dividerRightEdge, abs(edge - last) > 0.5 else { return }
                self.log.debug("the icons right of the divider changed")
                self.onBarChange?()
            }
        }
    }

    // MARK: - Moving Perch's own items

    /// Saved position of the divider: everything with a larger position (further
    /// left) is hidden. See `StatusItemPositions`.
    var dividerPosition: Double? {
        UserDefaults.standard.object(forKey: Self.positionKey(Autosave.hidden)) as? Double
    }

    var perchPosition: Double? {
        UserDefaults.standard.object(forKey: Self.positionKey(Autosave.perch)) as? Double
    }

    /// Moves the divider by recreating it at `position`. Instant, and no mouse:
    /// macOS puts a new item wherever its saved position says.
    /// False if it's already there. Spots next to an icon Perch can't read
    /// can be very close together, so "there" means within a millionth.
    @discardableResult
    func moveDivider(to position: Double) -> Bool {
        guard dividerPosition.map({ abs($0 - position) > 1e-6 }) ?? true else { return false }
        let old = hiddenDivider
        Self.save(position, for: Autosave.switchDivider())
        makeDivider()
        if let old { NSStatusBar.system.removeStatusItem(old) }
        apply()
        return true
    }

    /// Moves Perch's own line or icon the same way. False if it's already there.
    @discardableResult
    func movePerch(to position: Double) -> Bool {
        guard perchPosition.map({ abs($0 - position) > 1e-6 }) ?? true else { return false }
        let old = perchItem
        Self.save(position, for: Autosave.switchPerch())
        settlesAt = Date().addingTimeInterval(Self.settleTime)
        makePerchItem()
        if let old { NSStatusBar.system.removeStatusItem(old) }
        apply()
        return true
    }

    private static func save(_ position: Double, for name: String) {
        let defaults = UserDefaults.standard
        defaults.set(position, forKey: positionKey(name))
        // Removing an item can mark it hidden; a new one should show.
        defaults.removeObject(forKey: "NSStatusItem Visible \(name)")
        defaults.removeObject(forKey: "NSStatusItem VisibleCC \(name)")
    }

    /// Earlier versions had an "Archived" divider. Remove its saved state.
    private func removeRetiredItems() {
        let defaults = UserDefaults.standard
        for key in ["NSStatusItem Preferred Position PerchArchivedDivider",
                    "NSStatusItem VisibleCC PerchArchivedDivider",
                    "NSStatusItem Visible PerchArchivedDivider",
                    "archivedSectionEnabled", "clickAction", "hasSeenWelcome", "rehideOnAppSwitch",
                    "autoRehideEnabled", "rehideDelay", "rehideOnClickOutside",
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
        let item = barItem
        let visible = item != .none
        if perchItem.isVisible != visible { perchItem.isVisible = visible }
        switch item {
        case .none:
            return
        case .line:
            button.image = visibility.isRevealed ? Self.lineImage(alpha: 0.9) : Self.lineImage(alpha: 0.6)
            perchItem.length = Self.lineImageWidth
            return
        case .icon:
            break
        }
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

    private static let lineImageWidth: CGFloat = 6

    /// Perch's item as a line: a little taller and bolder than the divider,
    /// so it reads as something to click.
    private static func lineImage(alpha: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: lineImageWidth, height: 14), flipped: false) { _ in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: lineImageWidth / 2, y: 1))
            path.line(to: NSPoint(x: lineImageWidth / 2, y: 13))
            path.lineWidth = 2
            path.lineCapStyle = .round
            NSColor.black.withAlphaComponent(alpha).setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Perch"
        return image
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

    /// Waits until the divider has its new frame after a move: a new status
    /// item's frame is empty or stale for a moment.
    func settle() async {
        var last: NSRect?
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(50))
            let now = screenFrame(of: hiddenDivider)
            if let now, now == last { return }
            last = now
        }
    }

    private func waitForPlacement() {
        let placed = screenFrame(of: hiddenDivider) != nil
            && (!perchItem.isVisible || screenFrame(of: perchItem) != nil)
        if placed || placementAttempts >= 12 {
            Task {
                if let beforeFirstHide {
                    await beforeFirstHide()
                    self.beforeFirstHide = nil
                }
                // Without Accessibility Perch can't see where icons are, so
                // hiding would hide nearly all of them. Wait for the permission.
                guard hasAccessibility else {
                    log.notice("staying revealed until Perch has Accessibility")
                    waitsForAccessibility = true
                    return
                }
                await firstHide()
            }
            return
        }
        placementAttempts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.waitForPlacement() }
    }

    /// Hides only once the divider is where a real look at the bar puts it:
    /// at a stale spot, icons you want to see could vanish.
    private func firstHide() async {
        guard !isFirstHiding else { return }
        isFirstHiding = true
        defer { isFirstHiding = false }
        while await placeFirst?() == false {
            guard hasAccessibility else { return }
            try? await Task.sleep(for: .seconds(1))
        }
        guard hasAccessibility else { return }
        hasPlaced = true
        collapse()
        onReady?()
    }

    private func perchIsRightOfDivider() -> Bool {
        guard let perch = perchFrame(), let divider = screenFrame(of: hiddenDivider) else { return true }
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
        if Self.wantsArrange(NSApp.currentEvent) {
            openArrange?()
        } else {
            menuToggle()
        }
    }

    /// Revealed, the divider is the thin line: a click hides. Collapsed, it
    /// stretches under empty menu bar space, so a click there may land on it.
    @objc private func dividerClicked(_ sender: NSStatusBarButton) {
        if Self.wantsArrange(NSApp.currentEvent) {
            openArrange?()
        } else {
            menuToggle()
        }
    }

    private static func wantsArrange(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        return event.type == .rightMouseUp || event.type == .rightMouseDown
            || event.modifierFlags.contains(.control) || event.modifierFlags.contains(.option)
    }

    /// Empty menu bar space works like Perch's item: click to show or hide,
    /// right-click to arrange. A global monitor only sees clicks meant for
    /// other apps, and this one asks Accessibility what's under the pointer
    /// only for clicks inside the menu bar. Nothing runs between clicks.
    private func watchEmptyBarClicks() {
        barClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.barClicked(event) }
        }
    }

    private func barClicked(_ event: NSEvent) {
        // Single clicks only, and not ⌘-drags.
        guard event.clickCount == 1, !event.modifierFlags.contains(.command),
              MenuBarGeometry.isEmptyMenuBarSpace(NSEvent.mouseLocation),
              !MenuBarGeometry.isMenuOpen() else { return }
        if Self.wantsArrange(event) {
            openArrange?()
        } else {
            menuToggle()
        }
    }

    /// Opens or closes Perch's bar. If the menu bar is showing everything
    /// (only right after launch), a click hides the extras instead.
    private func menuToggle() {
        if visibility.isRevealed {
            // Without Accessibility, or before the divider has a real spot,
            // hiding could hide the icons you want; Arrange explains instead.
            if hasAccessibility && hasPlaced { collapse() } else { openArrange?() }
        } else if toggleDrawer?() != true {
            openArrange?()
        }
    }

    // MARK: - Preferences

    private func observePreferences() {
        preferences.$iconStyle.map { _ in () }
            .merge(with: preferences.$barItem.map { _ in () })
            .dropFirst(2)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updatePerchIcon() }
            }
            .store(in: &cancellables)
    }
}
