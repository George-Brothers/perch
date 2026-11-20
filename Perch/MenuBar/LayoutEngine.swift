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
        hasScanned = true
        return items
    }

    // MARK: - Arranging

    private struct Move {
        let item: MenuBarItem
        let show: Bool
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
        guard !moves.isEmpty else { return }
        // Something opened during the scan (an icon from the drawer, say): try later.
        if Self.userIsBusy() || menuBar.isTemporaryReveal {
            deferOrGiveUp()
            return
        }
        deferrals = 0
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
                  MenuBarGeometry.isOnScreen(from, screen: menuBar.screen)
            else { continue }
            let target = CGPoint(x: move.show ? divider.maxX + 3 : divider.minX - 3, y: from.midY)
            let start = CGPoint(x: from.midX, y: from.midY)
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

    /// Works out which icons need to cross the divider.
    private func plan(for items: [MenuBarItem]) -> [Move] {
        guard let perch = menuBar.perchFrame(), let screen = menuBar.screen else { return [] }
        let inBar = items.filter { $0.isInMenuBar }
        let movable = inBar.filter { item in
            if !item.isMovable { return false }
            if let x = stuck[item.key], abs(x - item.frame.minX) < 1 { return false }
            return true
        }

        // Room between the notch (or the middle of the screen, where app menus
        // can reach on screens without one) and the bird.
        let leftBound = screen.auxiliaryTopRightArea?.minX ?? screen.frame.midX
        // Icons Perch won't move (the mic indicator, stuck ones) that already
        // sit between the divider and the bird take up room too.
        let movableKeys = Set(movable.map(\.key))
        let reserved = inBar
            .filter { !movableKeys.contains($0.key) && $0.section == .shown && $0.frame.minX < perch.minX }
            .reduce(0) { $0 + $1.frame.width }
        var room = perch.minX - leftBound - reserved - 24

        var wantShown = Set<String>()
        for item in movable where priority(of: item) == .always {
            wantShown.insert(item.key)
            // Icons right of the bird don't use the room left of it.
            if item.frame.minX < perch.minX { room -= item.frame.width }
        }
        // Auto icons closest to the bird get the room first.
        let autos = movable
            .filter { priority(of: $0) == .auto }
            .sorted { $0.frame.minX > $1.frame.minX }
        for item in autos where item.frame.width <= room {
            wantShown.insert(item.key)
            room -= item.frame.width
        }

        let moves = movable.compactMap { item -> Move? in
            let shouldShow = wantShown.contains(item.key)
            let isShown = item.section == .shown
            return shouldShow == isShown ? nil : Move(item: item, show: shouldShow)
        }
        // Hides first, to make room. Then shows, nearest the divider first, so
        // each one pulls the next hidden icon out from behind the notch.
        let hides = moves.filter { !$0.show }
        let shows = moves.filter(\.show).sorted { $0.item.frame.minX > $1.item.frame.minX }
        return hides + shows
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
