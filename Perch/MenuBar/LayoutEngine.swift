import AppKit
import Combine
import os

/// Keeps the menu bar arranged: as many icons as fit stay right of the divider,
/// in your order, and the rest go left of it (into Perch's bar).
///
/// It never touches the mouse. What fits is settled by moving Perch's own
/// divider. An icon you move in Arrange gets a new saved position, which its
/// app picks up the next time it opens (see `StatusItemPositions`).
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
        if case .before(let anchor, shown: false) = placement {
            setHiddenOrder(item.key, before: anchor)
        }
        placements[item.key] = placement
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
    @Published private(set) var perchWidth: CGFloat?

    /// Rescans so the Arrange list is current. Cheap; runs when the list opens.
    func refresh() {
        Task { await scan() }
    }

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
        perchWidth = menuBar.perchFrame()?.width
        hasScanned = true
        return items
    }

    // MARK: - Arranging

    /// Where an icon goes in the bar.
    enum Placement: Equatable {
        /// Just left of another icon, the divider or Perch, ending up shown or hidden.
        case before(Anchor, shown: Bool)

        var isShown: Bool {
            if case .before(_, let shown) = self { return shown }
            return true
        }
    }

    enum Anchor: Equatable {
        case icon(String)
        /// The left end of the shown icons.
        case divider
        case perch
        /// The right end of the icons, just before the clock and Control Center.
        case end
    }

    /// Room for icons in the bar on this screen, in points, so Arrange can
    /// draw the bar at its real size and end where the screen does.
    @Published private(set) var room: CGFloat?
    /// The room a MacBook's own screen would have, when you're on another
    /// display. Learned the last time Perch saw the built-in screen.
    @Published private(set) var laptopRoom: CGFloat?
    /// The space between icons in the bar.
    @Published private(set) var iconGap: CGFloat = 8

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

    /// One pass. Nothing here touches the mouse or restarts an app:
    /// - spots asked for in Arrange are saved as the icon's position (see `apply`);
    /// - what fits is settled by moving Perch's own divider, which is instant.
    private func arrange() async {
        guard !isArranging else {
            arrangeAgain = true
            return
        }
        // Recreating the divider would close an open menu; wait for it.
        if MenuBarGeometry.isMenuOpen() || menuBar.isTemporaryReveal {
            deferOrGiveUp()
            return
        }
        deferrals = 0
        isArranging = true
        defer {
            isArranging = false
            if arrangeAgain {
                arrangeAgain = false
                scheduleArrange()
            }
        }

        var current = await scan()
        if !placements.isEmpty || perchPlacement != nil {
            let requests = placements
            let perchRequest = perchPlacement
            placements.removeAll()
            perchPlacement = nil
            await apply(requests, perch: perchRequest, in: current)
            current = await scan()
        }
        if placeDivider(in: current) {
            await menuBar.settle()
            // The other icons' frames catch up a little after the divider's.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
        }
        await scan()
    }

    // MARK: Positions

    /// Something in the bar with a position: an icon, or one of Perch's items.
    private struct Entry {
        enum Kind: Equatable { case icon(String), perch, fixed }
        let kind: Kind
        /// For ordering, left to right.
        let x: CGFloat
        let width: CGFloat
        var position: Double?
    }

    /// Everything in the bar left to right with its saved position. Positions
    /// Perch can't read are filled in between their neighbors, which is all
    /// that matters: macOS only compares them.
    private func entries(for items: [MenuBarItem]) -> [Entry] {
        let slots = StatusItemPositions.slots(for: items)
        var list = items.filter { $0.isInMenuBar && !$0.isLiveActivity && $0.identifier != "com.apple.menuextra.clock" }
            .map { item in
                // A waiting move's saved spot isn't where the icon is yet.
                Entry(kind: item.isFixed ? .fixed : .icon(item.key), x: item.frame.midX,
                      width: item.frame.width,
                      position: pendingMoves[item.key] == nil ? slots[item.key]?.value : nil)
            }
        if let perch = menuBar.perchFrame() {
            list.append(Entry(kind: .perch, x: perch.midX, width: perch.width, position: menuBar.perchPosition))
        }
        list.sort { $0.x < $1.x }
        // Fill gaps: halfway between known neighbors, or a step past the last one.
        for index in list.indices where list[index].position == nil {
            let left = list[..<index].last(where: { $0.position != nil })?.position
            let right = list[(index + 1)...].first(where: { $0.position != nil })?.position
            switch (left, right) {
            case let (l?, r?): list[index].position = (l + r) / 2
            case let (l?, nil): list[index].position = l - 1
            case let (nil, r?): list[index].position = r + 20
            default: break
            }
        }
        return list
    }

    /// A position just left of `right` and right of `left` (either may be nil).
    private static func between(left: Double?, right: Double?) -> Double? {
        switch (left, right) {
        case let (l?, r?): return r + min(1, (l - r) / 2)
        case let (nil, r?): return r + 1
        case let (l?, nil): return l - 1
        default: return nil
        }
    }

    // MARK: Spots from Arrange

    /// A move that happens the next time the icon's app opens: macOS reads an
    /// icon's saved spot only then, and Perch never restarts apps.
    struct PendingMove: Codable, Equatable {
        let bundleID: String
        let name: String
        /// Moving into Perch's bar. Until it does, the icon keeps its room in
        /// the menu bar, so the icons left of it don't get hidden with it.
        let hides: Bool
        /// The spot it had before, so moving it back undoes the move exactly.
        let previous: Double?
    }

    private static let pendingKey = "pendingMoves"

    /// Icon key → its waiting move.
    @Published private(set) var pendingMoves: [String: PendingMove] = {
        guard let data = UserDefaults.standard.data(forKey: pendingKey) else { return [:] }
        return (try? JSONDecoder().decode([String: PendingMove].self, from: data)) ?? [:]
    }() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(pendingMoves), forKey: Self.pendingKey) }
    }

    /// Icons in Perch's bar in your order (Perch keeps it, so reordering them
    /// never touches their apps). Icons you haven't ordered follow, in bar order.
    func inHiddenOrder(_ items: [MenuBarItem]) -> [MenuBarItem] {
        let order = preferences.hiddenOrder
        return items.sorted { a, b in
            let ia = order.firstIndex(of: a.key) ?? .max
            let ib = order.firstIndex(of: b.key) ?? .max
            return ia != ib ? ia < ib : a.frame.minX < b.frame.minX
        }
    }

    /// Puts `key` just before `anchor` in Perch's bar (at the end for anything else).
    private func setHiddenOrder(_ key: String, before anchor: Anchor) {
        var order = inHiddenOrder(items.filter { $0.isInMenuBar && $0.key != key && preferences.priority(for: $0.key) == .hidden })
            .map(\.key)
        if case .icon(let next) = anchor, let index = order.firstIndex(of: next) {
            order.insert(key, at: index)
        } else {
            order.append(key)
        }
        preferences.hiddenOrder = order
    }

    /// An icon given a new saved spot, to check once Control Center has restarted.
    private struct Move {
        let key: String
        let shown: Bool
        /// What should end up just right of it (for an icon that's showing).
        let neighbor: Entry.Kind?
        let waiting: PendingMove?
    }

    /// Saves each icon's new spot. Moves that only need the divider happen
    /// without anything else. For the rest, Perch restarts Control Center:
    /// on macOS 26 it draws every app's icons and puts each at its saved spot
    /// when it starts, so they move right away without their apps restarting.
    /// It has no windows; Apple's icons blink for a moment. An icon that
    /// still isn't in its spot moves the next time its app opens.
    private func apply(_ requests: [String: Placement], perch perchRequest: Placement?, in items: [MenuBarItem]) async {
        let slots = StatusItemPositions.slots(for: items)
        let list = entries(for: items)
        var moves: [Move] = []

        for (key, placement) in requests {
            guard case .before(let anchor, let shown) = placement,
                  let item = items.first(where: { $0.key == key }), item.isMovable,
                  let slot = slots[key], let index = list.firstIndex(where: { $0.kind == .icon(key) })
            else {
                log.notice("can't save a spot for \(key, privacy: .public)")
                continue
            }
            let instant = shown ? showsInPlace(at: index, isShown: item.section != .hidden, before: anchor, in: list)
                                : hidesInPlace(at: index, in: list)
            let previous = pendingMoves[key].map(\.previous) ?? slot.value
            let target: Double?
            if instant {
                // The divider does it. Only an earlier move still waiting needs undoing.
                guard let waiting = pendingMoves[key] else { continue }
                pendingMoves[key] = nil
                target = waiting.previous ?? list[index].position
            } else if shown {
                target = position(for: placement, moving: .icon(key), in: items)
            } else {
                target = positionJustHidden(key, in: list)
            }
            guard let target else {
                log.notice("can't save a spot for \(item.displayName, privacy: .public)")
                continue
            }
            if let current = slot.value, abs(current - target) < 0.01 { continue }
            StatusItemPositions.write(target, for: slot)
            log.notice("saved a new spot for \(item.displayName, privacy: .public)")
            guard !instant else { continue }
            let others = list.filter { $0.kind != .icon(key) }
            let app = NSRunningApplication(processIdentifier: item.pid)
            moves.append(Move(
                key: key, shown: shown,
                neighbor: anchorIndex(anchor, in: others).map { others[$0].kind },
                waiting: app?.bundleIdentifier.map {
                    PendingMove(bundleID: $0, name: app?.localizedName ?? item.displayName, hides: !shown, previous: previous)
                }
            ))
        }

        if let perchRequest, let position = position(for: perchRequest, moving: .perch, in: items) {
            menuBar.movePerch(to: position)
        }
        guard !moves.isEmpty else { return }

        await AppRestarter.restartControlCenter()
        await menuBar.settle()
        let after = await scan()
        // Control Center put every icon at its saved spot, including any
        // earlier moves that were waiting.
        let landed = entries(for: after)
        let dividerX = menuBar.dividerFrame()?.maxX ?? -.infinity
        var stillWaiting: [String: PendingMove] = [:]
        for move in moves {
            guard let index = landed.firstIndex(where: { $0.kind == .icon(move.key) }) else { continue }
            let inPlace = move.shown
                ? index + 1 < landed.count && landed[index + 1].kind == move.neighbor
                : landed[index].x < dividerX
            if !inPlace, let waiting = move.waiting { stillWaiting[move.key] = waiting }
        }
        if pendingMoves != stillWaiting { pendingMoves = stillWaiting }
        log.notice("restarted Control Center: \(moves.count - stillWaiting.count, privacy: .public) of \(moves.count, privacy: .public) icons moved")
    }

    /// Whether the icon at `index` hides with just the divider: no icon meant
    /// to show is left of it. Goes by what you asked for, not what's on screen
    /// now: an icon can be hidden today only because one next to it is, or
    /// because there's no room, and moving the divider would take those along.
    private func hidesInPlace(at index: Int, in list: [Entry]) -> Bool {
        !list[..<index].contains { entry in
            guard case .icon(let key) = entry.kind else { return false }
            return preferences.priority(for: key) == .shown
        }
    }

    /// Whether the icon at `index` shows at `anchor` with just the divider: it's
    /// already showing and you didn't pick a spot, or it's already next to the
    /// anchor and nothing right of it stays hidden.
    private func showsInPlace(at index: Int, isShown: Bool, before anchor: Anchor, in list: [Entry]) -> Bool {
        if isShown && anchor == .divider { return true }
        let others = list.filter { $0.kind != list[index].kind }
        guard let anchorIndex = anchorIndex(anchor, in: others),
              index < list.count - 1, list[index + 1].kind == others[anchorIndex].kind
        else { return false }
        return !list[(index + 1)...].contains { entry in
            guard case .icon(let key) = entry.kind else { return false }
            return preferences.priority(for: key) == .hidden && pendingMoves[key]?.hides != true
        }
    }

    /// A spot left of every icon meant to show (and Perch's own item), so the
    /// icon ends up hidden without taking any of them along. Where it sits
    /// among the hidden icons doesn't matter: Perch's bar keeps its own order.
    private func positionJustHidden(_ key: String, in list: [Entry]) -> Double? {
        let others = list.filter { $0.kind != .icon(key) }
        guard let first = others.firstIndex(where: { entry in
            if case .icon(let other) = entry.kind { return preferences.priority(for: other) == .shown }
            return true // Perch's item, or the clock and Control Center
        }) else { return nil }
        return Self.between(left: first > 0 ? others[first - 1].position : nil, right: others[first].position)
    }

    private func anchorIndex(_ anchor: Anchor, in list: [Entry]) -> Int? {
        switch anchor {
        case .icon(let key): return list.firstIndex { $0.kind == .icon(key) }
        case .perch: return list.firstIndex { $0.kind == .perch }
        case .end: return list.firstIndex { $0.kind == .fixed }
        case .divider:
            // The leftmost shown thing: the first entry right of the divider.
            let dividerX = menuBar.dividerFrame()?.maxX ?? -.infinity
            return list.firstIndex { $0.x > dividerX }
        }
    }

    /// The saved position that puts `moving` just left of the placement's anchor.
    private func position(for placement: Placement, moving: Entry.Kind, in items: [MenuBarItem]) -> Double? {
        guard case .before(let anchor, _) = placement else { return nil }
        let list = entries(for: items).filter { $0.kind != moving }
        guard let index = anchorIndex(anchor, in: list) else { return nil }
        let left = index > 0 ? list[index - 1].position : nil
        return Self.between(left: left, right: list[index].position)
    }

    // MARK: What fits

    /// Puts the divider where the room runs out. Order is priority: icons
    /// nearest the right get the room first, and once one doesn't fit (or you
    /// want it hidden), it and everything left of it go to the hidden side.
    /// True if it moved the divider or Perch's item.
    @discardableResult
    private func placeDivider(in items: [MenuBarItem]) -> Bool {
        guard let screen = menuBar.screen else { return false }
        let inBar = items.filter(\.isInMenuBar)
        let list = entries(for: items)
        let gap = gap(in: inBar)

        // Room between the notch (or the middle of the screen, where app menus
        // can reach on screens without one) and the clock and Control Center.
        let leftBound = screen.auxiliaryTopRightArea?.minX ?? screen.frame.midX
        let rightBound = inBar.filter(\.isFixed).map(\.frame.minX).min() ?? screen.frame.maxX
        // Icons macOS places itself (the mic indicator) take room too.
        let reserved = inBar
            .filter { !$0.isMovable && !$0.isFixed && $0.section == .shown }
            .reduce(0) { $0 + $1.frame.width + gap }
        var room = rightBound - leftBound - reserved - 8
        publishRoom(room, screen: screen, rightBound: rightBound, reserved: reserved, gap: gap)

        // Walk right to left; `cut` ends up at the leftmost entry that stays shown.
        let movable = list.filter { $0.kind != .fixed }
        var cut = list.firstIndex { $0.kind == .fixed } ?? list.endIndex
        for entry in movable.reversed() {
            let cost = entry.width + gap
            if case .icon(let key) = entry.kind {
                // An icon waiting to move into Perch's bar still takes its room.
                let hides = preferences.priority(for: key) == .hidden && pendingMoves[key]?.hides != true
                guard !hides, cost <= room else { break }
            } else if cost > room {
                break
            }
            room -= cost
            cut = list.firstIndex { $0.kind == entry.kind } ?? cut
        }

        // Perch's own item always stays shown: if the cut fell right of it, move it over.
        if let perchIndex = list.firstIndex(where: { $0.kind == .perch }), perchIndex < cut,
           let position = Self.between(left: cut > 0 ? list[cut - 1].position : nil,
                                       right: cut < list.count ? list[cut].position : nil) {
            menuBar.movePerch(to: position)
            return true // Perch moved; the next scan places the divider.
        }

        let leftOfCut = cut > 0 ? list[cut - 1] : nil
        let rightOfCut = cut < list.count ? list[cut] : nil
        // Already there: the divider sits between those two.
        if let divider = menuBar.dividerFrame() {
            let afterLeft = leftOfCut.map { $0.x < divider.maxX } ?? true
            let beforeRight = rightOfCut.map { divider.maxX < $0.x } ?? true
            if afterLeft && beforeRight { return false }
        }
        guard let position = Self.between(left: leftOfCut?.position, right: rightOfCut?.position) else { return false }
        let shownCount = list[cut...].filter { $0.kind != .fixed }.count
        log.notice("moving the divider so \(shownCount, privacy: .public) icons show")
        menuBar.moveDivider(to: position)
        return true
    }

    private static let laptopWidthKey = "laptopBarWidth"

    /// Publishes the room on this screen and, on another display, the room
    /// a MacBook's screen would have (the part right of its notch, minus the
    /// same clock and Control Center).
    private func publishRoom(_ room: CGFloat, screen: NSScreen, rightBound: CGFloat, reserved: CGFloat, gap: CGFloat) {
        if self.room != room { self.room = room }
        if iconGap != gap { iconGap = gap }
        let defaults = UserDefaults.standard
        if let builtIn = NSScreen.screens.first(where: \.isBuiltIn) {
            let left = builtIn.auxiliaryTopRightArea?.minX ?? builtIn.frame.midX
            defaults.set(Double(builtIn.frame.maxX - left), forKey: Self.laptopWidthKey)
        }
        var laptop: CGFloat?
        if !screen.isBuiltIn, let width = defaults.object(forKey: Self.laptopWidthKey) as? Double {
            laptop = CGFloat(width) - (screen.frame.maxX - rightBound) - reserved - 8
        }
        if laptopRoom != laptop { laptopRoom = laptop }
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

    // MARK: - Triggers

    private func retry(after delay: TimeInterval) {
        scheduleArrange(after: delay)
    }

    private func observeTriggers() {
        menuBar.onReady = { [weak self] in self?.scheduleArrange(after: 1) }

        preferences.$priorities
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleArrange() }
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
                // This fires for small things too (the Dock, say).
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
        // Icons come and go with their apps, which changes what fits.
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    // An app with a waiting move opened: its icons are in their new spots.
                    if name == NSWorkspace.didLaunchApplicationNotification,
                       let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                       let bundleID = app.bundleIdentifier, let self {
                        let moved = self.pendingMoves.filter { $0.value.bundleID == bundleID }.map(\.key)
                        for key in moved { self.pendingMoves[key] = nil }
                    }
                    self?.scheduleArrange(after: 3)
                }
            })
        }
    }
}

extension NSScreen {
    /// A MacBook's own screen.
    var isBuiltIn: Bool {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        return CGDisplayIsBuiltin(number.uint32Value) != 0
    }
}
