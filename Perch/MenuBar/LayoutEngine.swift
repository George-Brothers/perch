import AppKit
import Combine
import os

/// Keeps the menu bar arranged by your priorities: every "Always" icon and as
/// many "Auto" icons as fit stay right of the divider; the rest go left of it.
///
/// It reacts to events only (launch, a priority change, a display change, wake,
/// an app opening or quitting) and moves nothing when the bar is already right.
@MainActor
final class LayoutEngine: ObservableObject {
    @Published private(set) var items: [MenuBarItem] = []
    @Published private(set) var hasScanned = false
    @Published private(set) var isArranging = false

    private let preferences: Preferences
    private let permissions: Permissions
    private let menuBar: MenuBarController
    private let log = Logger(subsystem: "com.georgebrothers.perch", category: "layout")
    private var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var pendingArrange: DispatchWorkItem?
    private var arrangeAgain = false
    /// How many times in a row a pass waited for a menu or the mouse.
    private var deferrals = 0
    /// Icons that didn't move when asked, with where they were. Skipped until
    /// they move or you change a priority, so a stuck icon doesn't make the
    /// bar flash on every trigger.
    private var stuck: [String: CGFloat] = [:]
    /// Bumped on a priority change, display change, wake or unlock, so a pass
    /// that started before one of those doesn't mark icons stuck.
    private var stuckGeneration = 0
    /// The display layout at the last display-change trigger.
    private var lastScreenFrames: [CGRect] = NSScreen.screens.map(\.frame)


    init(preferences: Preferences, permissions: Permissions, menuBar: MenuBarController) {
        self.preferences = preferences
        self.permissions = permissions
        self.menuBar = menuBar
        observeTriggers()
    }

    func priority(of item: MenuBarItem) -> IconPriority {
        preferences.priority(for: item.key)
    }

    func setPriority(_ priority: IconPriority, for item: MenuBarItem) {
        preferences.setPriority(priority, for: item.key)
    }

    /// Exact spots asked for in Arrange, done by the next pass.
    private var placements: [String: Placement] = [:]

    /// Moves an icon to an exact spot (from Arrange) and gives it `priority`.
    func place(_ item: MenuBarItem, _ placement: Placement, priority: IconPriority) {
        placements[item.key] = placement
        stuck[item.key] = nil
        if preferences.priority(for: item.key) != priority {
            preferences.setPriority(priority, for: item.key) // schedules a pass
        } else {
            scheduleArrange(after: 0.05)
        }
    }

    /// Where to put Perch's own item (its line or icon), from Arrange.
    private var perchPlacement: Placement?

    func placePerch(_ placement: Placement) {
        perchPlacement = placement
        scheduleArrange(after: 0.05)
    }

    /// Perch's own x position, so Arrange can show where it sits among the icons.
    @Published private(set) var perchMinX: CGFloat?

    /// Rescans so the Arrange list is current. Cheap; runs when the list opens.
    func refresh() {
        Task { await scan() }
    }

    /// Runs while a pass has every icon on screen, so the drawer can picture them.
    var whileRevealed: (() async -> Void)?

    /// Rescans and returns the icons, for callers that need them right away.
    func rescan() async -> [MenuBarItem] {
        await scan()
    }

    /// Asks for an arrange pass after `delay`. Repeated requests collapse into one.
    func scheduleArrange(after delay: TimeInterval = 0.4) {
        pendingArrange?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { await self?.arrange() }
        }
        pendingArrange = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Scanning

    @discardableResult
    private func scan() async -> [MenuBarItem] {
        permissions.refresh()
        guard permissions.hasAccessibility else {
            items = []
            return []
        }
        let found = await MenuBarScanner.scan()
        let dividerMidX = menuBar.dividerFrame()?.midX
        items = found.map { item in
            var item = item
            if !item.isInMenuBar {
                item.section = .notShowing
            } else if let dividerMidX, item.frame.midX < dividerMidX {
                item.section = .hidden
            } else {
                item.section = .shown
            }
            return item
        }
        perchMinX = menuBar.perchFrame()?.minX
        hasScanned = true
        return items
    }

    // MARK: - Arranging

    private struct Move {
        let item: MenuBarItem
        let target: Placement

        /// Whether the icon should end up right of the divider.
        var show: Bool { target.isShown }
    }

    /// Where an icon goes in the bar.
    enum Placement: Equatable {
        /// Right of the divider, at its left end.
        case shown
        /// Left of the divider, at its right end.
        case hidden
        /// Just left of another icon, the divider or Perch, ending up shown or hidden.
        case before(Anchor, shown: Bool)

        var isShown: Bool {
            switch self {
            case .hidden, .before(_, shown: false): false
            case .shown, .before(_, shown: true): true
            }
        }
    }

    enum Anchor: Equatable {
        case icon(String)
        case divider
        case perch
        /// The right end of the icons, just before the clock and Control Center.
        case end
    }

    /// Tries again in 2 s, up to five times; the next trigger starts over.
    private func deferOrGiveUp() {
        deferrals += 1
        if deferrals <= 5 {
            scheduleArrange(after: 2)
        } else {
            log.notice("a menu stayed open; skipping this pass")
            deferrals = 0
        }
    }

    private func arrange() async {
        guard !isArranging else {
            arrangeAgain = true
            return
        }
        // Nothing can be moved behind the lock screen; unlocking triggers a pass.
        if Self.screenIsLocked() { return }
        // Don't fight the user: wait while a menu is open or a mouse button is
        // down. Give up after a few tries; the next trigger tries again.
        if Self.userIsBusy() {
            deferOrGiveUp()
            return
        }
        isArranging = true
        defer {
            isArranging = false
            menuBar.isBusy = false
            if arrangeAgain {
                arrangeAgain = false
                scheduleArrange()
            }
        }

        let current = await scan()
        let moves = plan(for: current)
        let perchMove = perchPlacement
        guard !moves.isEmpty || perchMove != nil else { return }
        // Something opened during the scan (an icon from the drawer, say): try later.
        if Self.userIsBusy() || menuBar.isTemporaryReveal {
            deferOrGiveUp()
            return
        }
        deferrals = 0
        placements.removeAll()
        perchPlacement = nil
        log.notice("arranging: \(moves.count) move(s)")

        let generation = stuckGeneration
        // A bar that's out only for an opened icon goes back to hidden afterwards.
        let wasRevealed = menuBar.visibility.isRevealed && !menuBar.isTemporaryReveal
        menuBar.reveal(armAutoHide: false)
        menuBar.isBusy = true
        try? await Task.sleep(for: .milliseconds(350))

        var attempted: [Move] = []
        for move in moves {
            // You started using the mouse or a menu, or locked the screen:
            // stop and try again later.
            if Self.userIsBusy() || Self.screenIsLocked() {
                arrangeAgain = true
                break
            }
            // Counted even when it can't be dragged (off screen, say), so an
            // icon Perch can't reach doesn't make the bar flash every time.
            attempted.append(move)
            guard let divider = menuBar.dividerFrame(),
                  let from = AX.frame(of: move.item.element),
                  MenuBarGeometry.isOnScreen(from, screen: menuBar.screen),
                  let targetX = targetX(for: move.target, divider: divider, in: current)
            else { continue }
            let target = CGPoint(x: targetX, y: from.midY)
            let start = CGPoint(x: from.midX, y: from.midY)
            await Task.detached(priority: .userInitiated) {
                IconMover.drag(from: start, to: target)
            }.value
            try? await Task.sleep(for: .milliseconds(150))
        }

        // Perch's own item, moved the same way as any other icon.
        if let perchMove, !arrangeAgain, let divider = menuBar.dividerFrame(), let from = menuBar.perchFrame(),
           let targetX = targetX(for: perchMove, divider: divider, in: current) {
            let start = CGPoint(x: from.midX, y: from.midY)
            let target = CGPoint(x: targetX, y: from.midY)
            await Task.detached(priority: .userInitiated) {
                IconMover.drag(from: start, to: target)
            }.value
            try? await Task.sleep(for: .milliseconds(150))
        }

        await whileRevealed?()
        menuBar.isBusy = false
        if wasRevealed {
            menuBar.reveal()
        } else {
            menuBar.collapse()
        }
        try? await Task.sleep(for: .milliseconds(300))
        let after = await scan()

        // Only judge the moves if the bar is in a known state and your
        // priorities didn't change while they ran.
        guard menuBar.dividerFrame() != nil, generation == stuckGeneration else { return }
        for move in attempted {
            guard let now = after.first(where: { $0.key == move.item.key }) else { continue }
            if (now.section == .shown) != move.show {
                log.notice("\(move.item.displayName, privacy: .public) didn't move; skipping it for now")
                stuck[move.item.key] = now.frame.minX
            }
        }
    }

    /// Where to drop an icon. macOS puts a ⌘-dragged icon before whichever icon
    /// it's dropped on the left half of, so aim just inside the anchor's left edge.
    private func targetX(for placement: Placement, divider: CGRect, in items: [MenuBarItem]) -> CGFloat? {
        switch placement {
        case .shown: return divider.maxX + 3
        case .hidden, .before(.divider, _): return divider.minX - 3
        case .before(.perch, _): return menuBar.perchFrame().map { $0.minX + 2 }
        case .before(.end, _):
            // Control Center's left half; failing that, past the last icon.
            if let fixed = items.filter(\.isFixed).compactMap({ AX.frame(of: $0.element) }).min(by: { $0.minX < $1.minX }) {
                return fixed.minX + 2
            }
            return items.filter { $0.section == .shown }.map(\.frame.maxX).max().map { $0 - 2 }
        case .before(.icon(let key), _):
            guard let anchor = items.first(where: { $0.key == key }),
                  let frame = AX.frame(of: anchor.element),
                  MenuBarGeometry.isOnScreen(frame, screen: menuBar.screen)
            else {
                // The neighbor is off screen (hidden, or no room): fall back to the side.
                return targetX(for: placement.isShown ? .shown : .hidden, divider: divider, in: items)
            }
            return frame.minX + min(2, frame.width / 4)
        }
    }

    private static func screenIsLocked() -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// A real (not synthetic) mouse button is down, or a menu is open.
    private static func userIsBusy() -> Bool {
        CGEventSource.buttonState(.hidSystemState, button: .left)
            || CGEventSource.buttonState(.hidSystemState, button: .right)
            || MenuBarGeometry.isMenuOpen()
    }

    /// The space macOS leaves between neighboring icons, from the bar itself.
    private func gap(in items: [MenuBarItem]) -> CGFloat {
        let shown = items.filter { $0.section == .shown }.sorted { $0.frame.minX < $1.frame.minX }
        let gaps = zip(shown, shown.dropFirst())
            .map { $1.frame.minX - $0.frame.maxX }
            .filter { $0 >= 0 && $0 < 40 }
            .sorted()
        return gaps.isEmpty ? 8 : gaps[gaps.count / 2]
    }

    /// Works out which icons need to cross the divider.
    private func plan(for items: [MenuBarItem]) -> [Move] {
        guard let screen = menuBar.screen else { return [] }
        let inBar = items.filter { $0.isInMenuBar }
        let movable = inBar.filter { item in
            if !item.isMovable { return false }
            if let x = stuck[item.key], abs(x - item.frame.minX) < 1 { return false }
            return true
        }

        // Room between the notch (or the middle of the screen, where app menus
        // can reach on screens without one) and the clock and Control Center.
        let leftBound = screen.auxiliaryTopRightArea?.minX ?? screen.frame.midX
        let rightBound = inBar.filter(\.isFixed).map(\.frame.minX).min() ?? screen.frame.maxX
        // Icons Perch won't move (the mic indicator, stuck ones) and Perch's
        // own item take up room too.
        let movableKeys = Set(movable.map(\.key))
        let reserved = inBar
            .filter { !movableKeys.contains($0.key) && !$0.isFixed && $0.section == .shown }
            .reduce(0) { $0 + $1.frame.width + gap(in: inBar) }
            + (menuBar.perchFrame().map { $0.width + gap(in: inBar) } ?? 0)
        var room = rightBound - leftBound - reserved - 8

        // Order is priority: the icons nearest the right get the room first,
        // and once one doesn't fit, everything left of it waits in hidden.
        var wantShown = Set<String>()
        let wanted = movable
            .filter { priority(of: $0) == .shown }
            .sorted { $0.frame.minX > $1.frame.minX }
        for item in wanted {
            let cost = item.frame.width + gap(in: inBar)
            guard cost <= room else { break }
            wantShown.insert(item.key)
            room -= cost
        }

        // Spots asked for in Arrange go first; they also settle the icon's side.
        let placed = inBar.filter(\.isMovable).compactMap { item in
            placements[item.key].map { Move(item: item, target: $0) }
        }
        let placedKeys = Set(placed.map(\.item.key))

        let moves = movable.compactMap { item -> Move? in
            guard !placedKeys.contains(item.key) else { return nil }
            let shouldShow = wantShown.contains(item.key)
            let isShown = item.section == .shown
            return shouldShow == isShown ? nil : Move(item: item, target: shouldShow ? .shown : .hidden)
        }
        // Hides first, to make room. Then shows, nearest the divider first, so
        // each one pulls the next hidden icon out from behind the notch.
        let hides = moves.filter { !$0.show }
        let shows = moves.filter(\.show).sorted { $0.item.frame.minX > $1.item.frame.minX }
        return hides + placed + shows
    }

    // MARK: - Triggers

    /// After a display change, wake or unlock, give stuck icons another try.
    private func retry(after delay: TimeInterval) {
        stuckGeneration += 1
        stuck.removeAll()
        scheduleArrange(after: delay)
    }

    private func observeTriggers() {
        menuBar.onReady = { [weak self] in self?.scheduleArrange(after: 1) }

        preferences.$priorities
            .dropFirst()
            .sink { [weak self] _ in
                self?.stuckGeneration += 1
                self?.stuck.removeAll()
                self?.scheduleArrange()
            }
            .store(in: &cancellables)

        // Accessibility granted after launch: list the icons and arrange them.
        permissions.$hasAccessibility
            .removeDuplicates()
            .dropFirst()
            .filter { $0 }
            .sink { [weak self] _ in
                self?.refresh()
                self?.scheduleArrange(after: 1)
            }
            .store(in: &cancellables)

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // This fires for small things too (the Dock, say). Only retry
                // stuck icons when the displays themselves changed.
                let frames = NSScreen.screens.map(\.frame)
                if frames != self.lastScreenFrames {
                    self.lastScreenFrames = frames
                    self.retry(after: 1.5)
                } else {
                    self.scheduleArrange(after: 1.5)
                }
            }
        })

        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.retry(after: 1.5) }
        })

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.retry(after: 3) }
        })
        // A newly opened app adds its icon on the far left (the hidden side).
        // Arrange so an Auto icon gets shown if there's room.
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleArrange(after: 3) }
            })
        }
    }
}
