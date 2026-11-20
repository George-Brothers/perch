import AppKit
import Combine
import os

/// Owns Perch's three menu bar items and hides or reveals the sections.
///
/// Left to right the bar reads:
///
///     [archived icons] ┆ [hidden icons] │ [shown icons] Perch [Control Center, clock]
///
/// Perch's own icon starts next to Control Center, so a crowded bar can never
/// push it behind the notch.
///
/// macOS has no API for hiding another app's icon. Instead, each divider is a
/// status item that Perch stretches to 10,000 points wide. Everything to its
/// left gets pushed off the screen. Shrinking it brings those icons back.
@MainActor
final class MenuBarController: NSObject, ObservableObject {
    enum Visibility {
        case collapsed
        case showingHidden
        case showingAll

        var isRevealed: Bool { self != .collapsed }
    }

    private enum Autosave {
        static let perch = "PerchIcon"
        static let hidden = "PerchHiddenDivider"
        static let archived = "PerchArchivedDivider"
        static let all = [perch, hidden, archived]
    }

    /// macOS orders status items by a saved "preferred position": smaller means
    /// further right. Control Center sits around 130. Seeding these before the
    /// items exist puts Perch just left of Control Center with both dividers
    /// right beside it, so every other icon starts in the hidden section.
    private static let seededPositions: [String: Double] = [
        Autosave.perch: 100,
        Autosave.hidden: 101,
        Autosave.archived: 102,
    ]

    private static let collapsedLength: CGFloat = 10_000
    private let log = Logger(subsystem: "com.georgebrothers.perch", category: "menubar")
    private var placementAttempts = 0

    /// True when the dividers sit in the wrong order, for example after the
    /// Perch icon was ⌘-dragged into the hidden section. Perch then refuses
    /// to hide anything, so it can never hide its own icon.
    @Published private(set) var layoutProblem = false
    @Published private(set) var visibility: Visibility = .showingAll

    var openSettings: ((SettingsPane?) -> Void)?

    private let preferences: Preferences
    private var perchItem: NSStatusItem!
    private var hiddenDivider: NSStatusItem!
    private var archivedDivider: NSStatusItem!
    private var rehider: AutoRehider!
    private var cancellables = Set<AnyCancellable>()

    init(preferences: Preferences) {
        self.preferences = preferences
        super.init()
        rehider = AutoRehider(preferences: preferences) { [weak self] in self?.collapse() }
        seedPositionsIfNeeded()
        createItems()
        observePreferences()
        collapseOncePlaced()
    }

    /// macOS lays the items out a moment after they're created. Until then their
    /// frames are empty, so wait for real frames (up to about 3 seconds) before
    /// the first hide. Otherwise the order check can't be trusted.
    private func collapseOncePlaced() {
        placementAttempts = 0
        waitForPlacement()
    }

    private func waitForPlacement() {
        if frame(of: perchItem) != nil || placementAttempts >= 12 {
            collapse()
            return
        }
        placementAttempts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.waitForPlacement() }
    }

    // MARK: - Showing and hiding

    func toggle(showArchived: Bool) {
        let target: Visibility = showArchived && preferences.archivedSectionEnabled ? .showingAll : .showingHidden
        switch (visibility, target) {
        case (.collapsed, _), (.showingHidden, .showingAll):
            reveal(target)
        default:
            collapse()
        }
    }

    func reveal(_ target: Visibility) {
        guard target.isRevealed else {
            collapse()
            return
        }
        visibility = (target == .showingAll && !preferences.archivedSectionEnabled) ? .showingHidden : target
        apply()
        rehider.arm()
    }

    func collapse() {
        rehider.disarm()
        guard sectionsAreInOrder() else {
            visibility = .showingAll
            apply()
            if !layoutProblem {
                layoutProblem = true
                openSettings?(.sections)
            }
            return
        }
        layoutProblem = false
        visibility = .collapsed
        apply()
    }

    /// Puts Perch's items back at the far left of the status area, in the right order.
    func resetPositions() {
        rehider.disarm()
        for item in [perchItem, hiddenDivider, archivedDivider] {
            if let item { NSStatusBar.system.removeStatusItem(item) }
        }
        let defaults = UserDefaults.standard
        for name in Autosave.all {
            defaults.removeObject(forKey: Self.positionKey(name))
            defaults.removeObject(forKey: "NSStatusItem Visible \(name)")
            defaults.removeObject(forKey: "NSStatusItem VisibleCC \(name)")
        }
        visibility = .showingAll
        layoutProblem = false
        seedPositionsIfNeeded()
        createItems()
        collapseOncePlaced()
    }

    private static func positionKey(_ name: String) -> String {
        "NSStatusItem Preferred Position \(name)"
    }

    private func seedPositionsIfNeeded() {
        let defaults = UserDefaults.standard
        for (name, position) in Self.seededPositions where defaults.object(forKey: Self.positionKey(name)) == nil {
            defaults.set(position, forKey: Self.positionKey(name))
        }
    }

    // MARK: - Items

    private func createItems() {
        let bar = NSStatusBar.system

        perchItem = bar.statusItem(withLength: NSStatusItem.variableLength)
        perchItem.autosaveName = Autosave.perch
        if let button = perchItem.button {
            button.target = self
            button.action = #selector(perchClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Perch")
        }

        hiddenDivider = bar.statusItem(withLength: NSStatusItem.variableLength)
        hiddenDivider.autosaveName = Autosave.hidden
        configureDivider(hiddenDivider, tooltip: "Icons left of this line are hidden. ⌘-drag icons across it.")

        archivedDivider = bar.statusItem(withLength: NSStatusItem.variableLength)
        archivedDivider.autosaveName = Autosave.archived
        configureDivider(archivedDivider, tooltip: "Icons left of this line are archived. ⌘-drag icons across it.")

        apply()
    }

    private func configureDivider(_ item: NSStatusItem, tooltip: String) {
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(dividerClicked(_:))
        button.toolTip = tooltip
        button.setAccessibilityLabel("Perch divider")
    }

    private func apply() {
        archivedDivider.isVisible = preferences.archivedSectionEnabled
        switch visibility {
        case .collapsed:
            setDivider(hiddenDivider, expanded: false, dashed: false)
            setDivider(archivedDivider, expanded: false, dashed: true)
        case .showingHidden:
            setDivider(hiddenDivider, expanded: true, dashed: false)
            setDivider(archivedDivider, expanded: false, dashed: true)
        case .showingAll:
            setDivider(hiddenDivider, expanded: true, dashed: false)
            setDivider(archivedDivider, expanded: true, dashed: true)
        }
        updatePerchIcon()
    }

    private func setDivider(_ item: NSStatusItem, expanded: Bool, dashed: Bool) {
        if expanded {
            item.length = NSStatusItem.variableLength
            item.button?.image = Self.dividerImage(dashed: dashed)
        } else {
            item.button?.image = nil
            item.length = Self.collapsedLength
        }
    }

    private func updatePerchIcon() {
        guard let button = perchItem.button else { return }
        let name = preferences.iconStyle.symbolName(revealed: visibility.isRevealed)
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let image = (NSImage(systemSymbolName: name, accessibilityDescription: "Perch")
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: "Perch"))?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        button.image = image
    }

    private static func dividerImage(dashed: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 8, height: 16), flipped: false) { _ in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 4, y: 1.5))
            path.line(to: NSPoint(x: 4, y: 14.5))
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            if dashed {
                path.setLineDash([0.5, 3], count: 2, phase: 0)
                path.lineWidth = 2
            }
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Checked while the dividers are narrow, right before hiding.
    private func sectionsAreInOrder() -> Bool {
        log.debug("order check perch=\(String(describing: self.frame(of: self.perchItem)), privacy: .public) hidden=\(String(describing: self.frame(of: self.hiddenDivider)), privacy: .public) archived=\(String(describing: self.frame(of: self.archivedDivider)), privacy: .public)")
        guard let perch = frame(of: perchItem), let hidden = frame(of: hiddenDivider) else { return true }
        if hidden.maxX > perch.minX + 1 { return false }
        if preferences.archivedSectionEnabled,
           let archived = frame(of: archivedDivider),
           archived.maxX > hidden.minX + 1 {
            return false
        }
        return true
    }

    private func frame(of item: NSStatusItem) -> CGRect? {
        // Before macOS places an item its frame is empty, so treat that as unknown.
        guard item.isVisible, let frame = item.button?.window?.frame, frame.height > 0 else { return nil }
        return frame
    }

    // MARK: - Clicks and menu

    @objc private func perchClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
            return
        }
        toggle(showArchived: event?.modifierFlags.contains(.option) == true)
    }

    @objc private func dividerClicked(_ sender: NSStatusBarButton) {
        collapse()
    }

    private func showMenu() {
        let menu = NSMenu()

        let toggleTitle = visibility.isRevealed ? "Hide Icons" : "Show Hidden Icons"
        menu.addItem(withTitle: toggleTitle, action: #selector(menuToggle), keyEquivalent: "").target = self
        if preferences.archivedSectionEnabled, visibility != .showingAll {
            menu.addItem(withTitle: "Show Archived Icons", action: #selector(menuShowAll), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "About Perch", action: #selector(menuAbout), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Perch", action: #selector(menuQuit), keyEquivalent: "q").target = self

        perchItem.menu = menu
        perchItem.button?.performClick(nil)
        perchItem.menu = nil
    }

    @objc private func menuToggle() { toggle(showArchived: false) }
    @objc private func menuShowAll() { reveal(.showingAll) }
    @objc private func menuSettings() { openSettings?(nil) }
    @objc private func menuAbout() { openSettings?(.about) }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    // MARK: - Preferences

    private func observePreferences() {
        preferences.$iconStyle
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updatePerchIcon() }
            }
            .store(in: &cancellables)

        preferences.$archivedSectionEnabled
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.apply()
                    if !self.visibility.isRevealed { self.collapse() }
                }
            }
            .store(in: &cancellables)

        Publishers.MergeMany(
            preferences.$autoRehideEnabled.map { _ in () }.eraseToAnyPublisher(),
            preferences.$rehideDelay.map { _ in () }.eraseToAnyPublisher(),
            preferences.$rehideOnClickOutside.map { _ in () }.eraseToAnyPublisher(),
            preferences.$rehideOnAppSwitch.map { _ in () }.eraseToAnyPublisher()
        )
        .dropFirst(4)
        .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
        .sink { [weak self] in
            guard let self, self.visibility.isRevealed else { return }
            self.rehider.arm()
        }
        .store(in: &cancellables)
    }
}
