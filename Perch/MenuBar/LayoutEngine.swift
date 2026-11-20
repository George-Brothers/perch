import AppKit
import Combine
import os

/// Keeps the menu bar arranged: as many icons as fit stay right of the divider,
/// in your order, and the rest go left of it (into Perch's bar).
///
/// It never touches the mouse. What fits is settled by moving Perch's own
/// divider. Other moves save new positions for the icons that have to move
/// and restart Control Center once, which places them (see `commit`).
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
        // Moves no longer wait for an app's next launch; drop what older versions saved.
        UserDefaults.standard.removeObject(forKey: "pendingMoves")
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

    /// Something in the shown part of the bar that Arrange can place.
    enum Spot: Hashable {
        case icon(String)
        case perch
    }

    /// The order you set in Arrange, until the bar matches it: what shows,
    /// left to right. Movable icons not in it go to the hidden side.
    private var queued: [Spot]? {
        didSet { if queued != oldValue { queuedBar = queued } }
    }
    /// What's waiting, for Arrange to draw instead of the bar as it is.
    @Published private(set) var queuedBar: [Spot]?

    /// The icons in the bar when the current order was started. An icon
    /// that shows up later (an app that just opened) isn't part of it: it
    /// stays where macOS put it, with its own priority.
    private(set) var queuedFrom: Set<String> = []
    /// Goes up with every accepted drop, so a pass clears only the batch it applied.
    private var queuedRevision = 0

    /// What can hold moves: Arrange and Settings → Icons, while they're open.
    enum Holder { case arrange, settings }

    /// While Arrange (or Settings → Icons) is open, moves that need the bar to
    /// reset wait until it closes: one reset however many icons you move.
    /// (Each reset makes macOS redraw its own icons, and Focus shows its name
    /// again.) Moves that only need the divider still happen right away.
    func hold(_ on: Bool, for holder: Holder) {
        let wasHolding = holdsMoves
        if on { holders.insert(holder) } else { holders.remove(holder) }
        if wasHolding, !holdsMoves, queued != nil { scheduleArrange(after: 0.05) }
    }
    private var holders: Set<Holder> = []
    private var holdsMoves: Bool { !holders.isEmpty }
    /// Moves are waiting for Arrange to close.
    @Published private(set) var waitsForClose = false

    /// Something to tell you in Arrange about the last move, if it didn't work.
    @Published private(set) var notice: String?

    /// Moves an icon to a spot, from Arrange or Perch's bar. False if Perch
    /// can't put it there (next to an app whose icons Perch can't move, say).
    @discardableResult
    func place(_ item: MenuBarItem, _ placement: Placement) -> Bool {
        guard case .before(let anchor, let shown) = placement else { return false }
        guard !MenuBarSpacing.isApplying else {
            notice = "Perch is restarting to apply the new spacing. Try again in a moment."
            return false
        }
        // The order and the icons it covers change together, and only if the drop is accepted.
        var members = queued == nil ? Set(items.filter { $0.isInMenuBar && $0.isMovable }.map(\.key)) : queuedFrom
        var order = queued.map { withNewcomers($0, into: &members) } ?? shownOrder(in: items)
        members.insert(item.key)
        order.removeAll { $0 == .icon(item.key) }
        if shown { order.insert(.icon(item.key), at: insertionIndex(for: anchor, in: order)) }
        guard plan(order, in: items, members: members) != nil else {
            log.notice("can't put \(item.displayName, privacy: .public) there")
            notice = "Perch can't put \(item.displayName) there. ⌘-drag it in the menu bar instead."
            return false
        }
        if !shown { setHiddenOrder(item.key, before: anchor, shown: order) }
        notice = nil
        queuedFrom = members
        queuedRevision += 1
        queued = order
        // Right away: you just dropped it.
        scheduleArrange(after: 0.02)
        return true
    }

    /// Where to put Perch's own item (its line or icon), from Arrange. False
    /// if Perch can't put it there.
    @discardableResult
    func placePerch(_ placement: Placement) -> Bool {
        guard case .before(let anchor, _) = placement else { return false }
        guard !MenuBarSpacing.isApplying else {
            notice = "Perch is restarting to apply the new spacing. Try again in a moment."
            return false
        }
        var members = queued == nil ? Set(items.filter { $0.isInMenuBar && $0.isMovable }.map(\.key)) : queuedFrom
        var order = queued.map { withNewcomers($0, into: &members) } ?? shownOrder(in: items)
        order.removeAll { $0 == .perch }
        order.insert(.perch, at: insertionIndex(for: anchor, in: order))
        guard plan(order, in: items, members: members) != nil else {
            notice = "Perch can't put its item there."
            return false
        }
        notice = nil
        queuedFrom = members
        queuedRevision += 1
        queued = order
        scheduleArrange(after: 0.02)
        return true
    }

    /// What's meant to show now, left to right.
    private func shownOrder(in items: [MenuBarItem]) -> [Spot] {
        entries(for: items).compactMap { entry in
            switch entry.kind {
            case .perch: return .perch
            case .fixed: return nil
            case .icon(let key):
                guard items.first(where: { $0.key == key })?.isMovable == true,
                      preferences.priority(for: key) == .shown else { return nil }
                return .icon(key)
            }
        }
    }

    /// Adds icons that appeared since the moves were queued, where they are
    /// now (as Arrange shows them), so a drop next to one lands there.
    private func withNewcomers(_ order: [Spot], into members: inout Set<String>) -> [Spot] {
        var order = order
        func minX(_ spot: Spot) -> CGFloat? {
            switch spot {
            case .icon(let key): return items.first { $0.key == key }?.frame.minX
            case .perch: return perchMinX
            }
        }
        for item in items.sorted(by: { $0.frame.minX < $1.frame.minX })
        where item.isInMenuBar && item.isMovable && !members.contains(item.key)
            && preferences.priority(for: item.key) == .shown {
            let index = order.firstIndex { (minX($0) ?? -.infinity) > item.frame.minX } ?? order.count
            order.insert(.icon(item.key), at: index)
            members.insert(item.key)
        }
        return order
    }

    private func insertionIndex(for anchor: Anchor, in order: [Spot]) -> Int {
        switch anchor {
        case .icon(let key): return order.firstIndex(of: .icon(key)) ?? order.count
        case .perch: return order.firstIndex(of: .perch) ?? order.count
        case .end: return order.count
        case .divider: return 0
        }
    }

    /// Perch's own x position, so Arrange can show where it sits among the icons.
    @Published private(set) var perchMinX: CGFloat?
    @Published private(set) var perchWidth: CGFloat?

    /// Rescans so the Arrange list is current. Cheap; runs when the list opens.
    func refresh() {
        // A pass in progress publishes its own scan once the bar has settled.
        guard !isArranging else { return }
        Task { await scan() }
    }

    /// Rescans and returns the icons, for callers that need them right away.
    func rescan() async -> [MenuBarItem] {
        isArranging ? items : await scan()
    }

    /// Moves asked for in Arrange that no pass has picked up yet.
    var hasQueuedMoves: Bool { queued != nil }

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

    /// Each icon's saved spot, read with the last scan.
    private var slots: [String: StatusItemPositions.Slot] = [:]

    @discardableResult
    private func scan(publish: Bool = true) async -> [MenuBarItem] {
        permissions.refresh()
        guard permissions.hasAccessibility else {
            items = []
            return []
        }
        let found = await MenuBarScanner.scan()
        // Reading saved spots talks to other processes; never on the main thread.
        slots = await Task.detached(priority: .userInitiated) { StatusItemPositions.slots(for: found) }.value
        let dividerMidX = menuBar.dividerFrame()?.midX
        let classified = found.map { item in
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
        guard publish else { return classified }
        items = classified
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
    /// Moves you made in Arrange keep waiting as long as it takes: applying
    /// them later, on some unrelated trigger, would surprise you.
    private func deferOrGiveUp() {
        deferrals += 1
        if deferrals <= 5 || queued != nil {
            scheduleArrange(after: 2)
        } else {
            log.notice("a menu stayed open; skipping this pass")
            deferrals = 0
        }
    }

    /// One pass. Nothing here touches the mouse or restarts an app:
    /// - the order set in Arrange is saved as icon positions (see `plan`),
    ///   once Arrange closes if the bar has to reset;
    /// - what fits is settled by moving Perch's own divider, which is instant.
    /// False if it didn't get to look at the bar (a menu was open, say).
    @discardableResult
    private func arrange() async -> Bool {
        guard !isArranging else {
            arrangeAgain = true
            return false
        }
        // While the screen is locked the bar isn't drawn; try again later.
        if AppRestarter.screenIsLocked {
            if queued != nil { scheduleArrange(after: 5) }
            return false
        }
        // Recreating the divider would close an open menu; wait for it.
        if MenuBarGeometry.isMenuOpen() || menuBar.isTemporaryReveal {
            // Queued moves retry every 2 s for as long as it takes; say so once.
            if deferrals == 0 { log.notice("waiting: a menu is open") } else { log.debug("still waiting: a menu is open") }
            deferOrGiveUp()
            return false
        }
        deferrals = 0
        isArranging = true
        defer {
            isArranging = false
            if arrangeAgain {
                arrangeAgain = false
                // Another drop came in during this pass: do it right away.
                scheduleArrange(after: hasQueuedMoves ? 0.02 : 0.4)
            }
        }

        var current = await scan()
        // Without Accessibility the scan is empty, and the divider would hide
        // every icon. Moves wait until the permission is back.
        guard permissions.hasAccessibility else { return false }
        if let order = queued {
            // A drop during this pass replaces the batch; keep the new one.
            let members = queuedFrom, revision = queuedRevision
            func done() { if queuedRevision == revision { queued = nil } }
            if let plan = plan(order, in: current, members: members) {
                if plan.writes.isEmpty {
                    // Only the divider and Perch's own items move: right away.
                    if let position = plan.perch {
                        menuBar.movePerch(to: position)
                        await menuBar.settle()
                        current = await scan()
                    }
                    setPriorities(order, in: current, members: members)
                    done()
                } else if holdsMoves {
                    log.notice("\(plan.writes.count, privacy: .public) icons move when Arrange closes")
                    waitsForClose = true
                    // The divider waits too: it goes by the order you set.
                    return true
                } else {
                    await commit(plan, order, members: members, in: current)
                    done()
                    current = await scan()
                    // Accessibility can go while Control Center restarts.
                    guard permissions.hasAccessibility else { return false }
                }
            } else {
                log.notice("the order from Arrange no longer fits the bar")
                done()
            }
            waitsForClose = queued != nil && holdsMoves
        }
        // Usually once; twice if Perch's item had to move to the cut first.
        var moved = false
        for _ in 0..<3 {
            guard placeDivider(in: current) else { break }
            moved = true
            await menuBar.settle()
            current = await settledScan()
        }
        if !moved { await scan() }
        return true
    }

    /// Scans until two scans in a row agree (up to about 1.5 s), then
    /// publishes. Right after a move macOS is still laying out the bar, and a
    /// scan then can see hidden icons nowhere and file them as turned off.
    @discardableResult
    private func settledScan() async -> [MenuBarItem] {
        var previous = await scan(publish: false)
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(100))
            let next = await scan(publish: false)
            if Self.layout(of: next) == Self.layout(of: previous) { break }
            previous = next
        }
        return await scan()
    }

    private static func layout(of items: [MenuBarItem]) -> [String] {
        items.map { "\($0.key) \($0.section) \(Int($0.frame.minX))" }
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
        /// Perch couldn't read this position (a sandboxed app's, say) and
        /// filled it in from its neighbors; the real one is somewhere between them.
        var isGuess = false
    }

    /// Everything in the bar left to right with its saved position. Positions
    /// Perch can't read are filled in between their neighbors, which is all
    /// that matters: macOS only compares them.
    private func entries(for items: [MenuBarItem]) -> [Entry] {
        var list = items.filter { $0.isInMenuBar && !$0.isLiveActivity && $0.identifier != "com.apple.menuextra.clock" }
            .map { item in
                // A waiting move's saved spot isn't where the icon is yet.
                Entry(kind: item.isFixed ? .fixed : .icon(item.key), x: item.frame.midX,
                      width: item.frame.width,
                      position: slots[item.key]?.value)
            }
        if let perch = menuBar.perchFrame() {
            list.append(Entry(kind: .perch, x: perch.midX, width: perch.width, position: menuBar.perchPosition))
        }
        list.sort { $0.x < $1.x }
        // Fill gaps: halfway between known neighbors, or a step past the last one.
        for index in list.indices where list[index].position == nil {
            list[index].isGuess = true
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
    /// Next to a guessed position, it hugs the neighbor Perch knows: the real
    /// position could be anywhere on the guessed side.
    private static func between(_ leftEntry: Entry?, _ rightEntry: Entry?) -> Double? {
        let left = leftEntry?.position
        let right = rightEntry?.position
        switch (left, right) {
        case let (l?, r?) where leftEntry?.isGuess == true && rightEntry?.isGuess != true:
            return r + min(0.05, (l - r) / 2)
        case let (l?, r?) where rightEntry?.isGuess == true && leftEntry?.isGuess != true:
            return l - min(0.05, (l - r) / 2)
        case let (l?, r?): return r + min(1, (l - r) / 2)
        case let (nil, r?): return r + 1
        case let (l?, nil): return l - 1
        default: return nil
        }
    }

    // MARK: Spots from Arrange

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

    /// Puts `key` just before `anchor` in Perch's bar (at the end for anything
    /// else), among the icons not in `shown`.
    private func setHiddenOrder(_ key: String, before anchor: Anchor, shown: [Spot]) {
        let showing = Set(shown)
        var order = inHiddenOrder(items.filter {
            $0.isInMenuBar && $0.isMovable && $0.key != key && !showing.contains(.icon($0.key))
        }).map(\.key)
        if case .icon(let next) = anchor, let index = order.firstIndex(of: next) {
            order.insert(key, at: index)
        } else {
            order.append(key)
        }
        preferences.hiddenOrder = order
    }

    /// New saved spots that put the bar in an order, and where Perch's item goes.
    private struct Plan {
        struct Write {
            let key: String
            /// The icon's saved spot as it was, to put back if the move fails.
            let slot: StatusItemPositions.Slot
            let value: Double
            let name: String
        }
        var writes: [Write] = []
        var perch: Double?
    }

    /// The new spots that make the bar: hidden icons, then `order`, then the
    /// clock and Control Center. Nil if that can't be done.
    ///
    /// Icons Perch can't move (a sandboxed app's, whose settings macOS guards)
    /// stay put, and so do as many others as possible: the longest run that's
    /// already in order. Everything else gets a spot between the two that stay
    /// on either side of it. A spot Perch can't read is somewhere between its
    /// neighbors' spots, so next to one the new spots hug the known side.
    private func plan(_ order: [Spot], in items: [MenuBarItem], members: Set<String>? = nil) -> Plan? {
        let members = members ?? queuedFrom
        let list = entries(for: items)
        let byKey = Dictionary(items.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var index: [Spot: Int] = [:]
        for (i, entry) in list.enumerated() {
            switch entry.kind {
            case .icon(let key): index[.icon(key)] = i
            case .perch: index[.perch] = i
            case .fixed: break
            }
        }
        let shown = Set(order)
        let hidden = list.indices.filter { i in
            guard case .icon(let key) = list[i].kind else { return false }
            return byKey[key]?.isMovable == true && !shown.contains(.icon(key)) && members.contains(key)
        }
        // Indices into `list`, in the order they should end up.
        let sequence = hidden + order.compactMap { index[$0] } + list.indices.filter { list[$0].kind == .fixed }

        func movable(_ i: Int) -> Bool {
            switch list[i].kind {
            case .perch: return true
            case .fixed: return false
            case .icon(let key): return slots[key].map { !$0.isPrivate } ?? false
            }
        }
        func known(_ i: Int) -> Double? { list[i].isGuess ? nil : list[i].position }

        // The longest run already in order that keeps every icon Perch can't move.
        let weights = sequence.map { i -> Int? in movable(i) ? (known(i) == nil ? nil : 1) : 1000 }
        var best = [Int](repeating: 0, count: sequence.count)
        var previous = [Int?](repeating: nil, count: sequence.count)
        // The last saved spot Perch knows along each run, past ones it can't read.
        var lastKnown = [Double?](repeating: nil, count: sequence.count)
        for s in sequence.indices {
            guard let weight = weights[s] else { continue }
            best[s] = weight
            lastKnown[s] = known(sequence[s])
            for t in 0..<s where weights[t] != nil && sequence[t] < sequence[s] && best[t] + weight > best[s] {
                // Ones that stay must also have saved spots in order, or nothing fits between them.
                if let a = lastKnown[t], let b = known(sequence[s]), a <= b { continue }
                best[s] = best[t] + weight
                previous[s] = t
                lastKnown[s] = known(sequence[s]) ?? lastKnown[t]
            }
        }
        var stay: [Int] = []
        var link = sequence.indices.max { best[$0] < best[$1] }.flatMap { best[$0] > 0 ? $0 : nil }
        while let s = link {
            stay.insert(s, at: 0)
            link = previous[s]
        }
        let fixedCount = sequence.filter { !movable($0) }.count
        guard stay.filter({ !movable(sequence[$0]) }).count == fixedCount else {
            log.notice("icons Perch can't move would have to change order")
            return nil
        }

        var result = Plan()
        let largest = list.indices.compactMap(known).max() ?? 0
        let ends: [Int?] = [nil] + stay.map { Optional($0) } + [nil]
        for (a, b) in zip(ends, ends.dropFirst()) {
            let movers = Array(sequence[(a.map { $0 + 1 } ?? 0)..<(b ?? sequence.count)])
            guard !movers.isEmpty else { continue }
            let left = a.map { sequence[$0] }, right = b.map { sequence[$0] }
            // Known spots in the bar now between the two that stay.
            let lo = left.map { $0 + 1 } ?? 0, hi = right ?? list.count
            let inside = lo < hi ? list.indices[lo..<hi].filter { known($0) != nil } : []
            var upper = left.flatMap { known($0) ?? inside.first.flatMap(known) }
            var lower = right.flatMap { known($0) ?? inside.last.flatMap(known) }
            let count = Double(movers.count)
            // Next to an icon whose spot Perch can't read, hug the known side:
            // within 0.05, and never past half the way to the next known spot
            // beyond that icon.
            func hugAbove(_ l: Double, beyond i: Int) -> Double {
                let outer = list[..<i].last { !$0.isGuess && $0.position != nil }?.position
                return l + min(0.05, ((outer ?? l + 0.1) - l) / 2)
            }
            func hugBelow(_ u: Double, beyond i: Int) -> Double {
                let outer = list[(i + 1)...].first { !$0.isGuess && $0.position != nil }
                return u - min(0.05, (u - (outer?.position ?? u - 0.1)) / 2)
            }
            switch (upper, lower) {
            case let (u?, l?) where u > l:
                break
            case let (u?, l?):
                if let left, known(left) == nil { upper = hugAbove(l, beyond: left) }
                else if let right, known(right) == nil { lower = hugBelow(u, beyond: right) }
                else { return nil }
            case let (nil, l?):
                upper = left.map { hugAbove(l, beyond: $0) } ?? l + count + 1
            case let (u?, nil):
                lower = right.map { hugBelow(u, beyond: $0) } ?? u - count - 1
            case (nil, nil):
                // Left of an icon whose spot nobody knows: well past every known spot.
                guard left == nil else { return nil }
                lower = largest + 1000
                upper = largest + 1000 + count + 1
            }
            // No room between them (equal saved spots, say): nothing fits there.
            guard let u = upper, let l = lower, u > l else { return nil }
            for (n, i) in movers.enumerated() {
                let value = u - (u - l) * Double(n + 1) / (count + 1)
                switch list[i].kind {
                case .perch:
                    result.perch = value
                case .icon(let key):
                    guard let slot = slots[key], !slot.isPrivate else { return nil }
                    result.writes.append(.init(key: key, slot: slot, value: value, name: byKey[key]?.displayName ?? key))
                case .fixed:
                    return nil
                }
            }
        }
        return result
    }

    /// Saves the new spots and restarts Control Center once: on macOS 26 it
    /// draws every app's icons and puts each at its saved spot when it starts,
    /// so they move without their apps restarting. Then checks they landed.
    private func commit(_ plan: Plan, _ order: [Spot], members: Set<String>, in items: [MenuBarItem]) async {
        // All or nothing: if one spot can't be saved, put back the ones that
        // were, so the next restart (or login) doesn't apply half a move.
        var saved: [Plan.Write] = []
        for write in plan.writes {
            guard await StatusItemPositions.write(write.value, for: write.slot, within: 1) else {
                log.notice("couldn't save a spot for \(write.name, privacy: .public); undoing")
                // This one too: it may still be saved late. The undo runs after it.
                var stuck: [String] = []
                for done in saved + [write] where !(await StatusItemPositions.restore(done.slot)) {
                    stuck.append(done.name)
                }
                if stuck.isEmpty {
                    notice = "Perch couldn't save a new spot for \(write.name). Nothing moved."
                } else {
                    log.error("couldn't undo \(stuck.count, privacy: .public) spots")
                    notice = "Perch couldn't save a new spot for \(write.name), and couldn't put back \(stuck.joined(separator: ", ")). Those may move the next time the menu bar resets."
                }
                return
            }
            saved.append(write)
        }
        log.notice("saved \(saved.count, privacy: .public) new spots")
        if let position = plan.perch { menuBar.movePerch(to: position) }
        let before = items.filter(\.isInMenuBar).count
        await AppRestarter.restartControlCenter()
        await menuBar.settle()
        var after = await settledScan()
        // Control Center can take a few seconds to come back; check once it
        // has, and the moved icons themselves are back.
        let movedKeys = Set(saved.map(\.key))
        func back(_ items: [MenuBarItem]) -> Bool {
            items.filter(\.isInMenuBar).count >= before - 1
                && movedKeys.isSubset(of: Set(items.filter(\.isInMenuBar).map(\.key)))
        }
        for _ in 0..<16 where !back(after) {
            try? await Task.sleep(for: .milliseconds(500))
            after = await settledScan()
        }
        let previous = Dictionary(uniqueKeysWithValues: members.map { ($0, preferences.priority(for: $0)) })
        setPriorities(order, in: after, members: members)
        // One that never came back can't be checked: treat it as out of place.
        let missing = saved.map(\.key).filter { key in !after.contains { $0.key == key && $0.isInMenuBar } }
        let wrong = missing + misplaced(order, in: after, moved: movedKeys, members: members)
        var stuck: [String] = []
        for key in wrong {
            // Undo its saved spot, so a later restart doesn't move it by surprise.
            if let write = saved.first(where: { $0.key == key }), !(await StatusItemPositions.restore(write.slot)) {
                log.error("couldn't put back the spot for \(write.name, privacy: .public)")
                stuck.append(write.name)
            }
            if !order.contains(.icon(key)) {
                // An icon marked hidden among the shown ones would take its neighbors along.
                preferences.setPriority(.shown, for: key)
            } else if let was = previous[key], preferences.priority(for: key) != was {
                // Its old spot is back, so its old priority goes with it.
                preferences.setPriority(was, for: key)
            }
        }
        if let key = wrong.first {
            let name = after.first { $0.key == key }?.displayName ?? saved.first { $0.key == key }?.name ?? key
            notice = "Perch couldn't move \(name) there. ⌘-drag it in the menu bar instead."
            if !stuck.isEmpty {
                notice! += " Perch couldn't put back \(stuck.joined(separator: ", ")) either; those may move the next time the menu bar resets."
            }
        }
        log.notice("restarted Control Center: \(wrong.count, privacy: .public) icons out of place")
    }

    /// Marks what's in `order` shown and the other icons that were part of it hidden.
    private func setPriorities(_ order: [Spot], in items: [MenuBarItem], members: Set<String>? = nil) {
        let members = members ?? queuedFrom
        for item in items where item.isInMenuBar && item.isMovable && members.contains(item.key) {
            let priority: IconPriority = order.contains(.icon(item.key)) ? .shown : .hidden
            if preferences.priority(for: item.key) != priority { preferences.setPriority(priority, for: item.key) }
        }
    }

    /// Icons that didn't end up where `order` says. `moved` are the ones given
    /// new spots: when it's unclear which icons are out of place, blame those,
    /// not ones Perch left alone.
    private func misplaced(_ order: [Spot], in items: [MenuBarItem], moved: Set<String>, members: Set<String>) -> [String] {
        let shown = Set(order)
        // Left to right: what should show, and the icons that should be hidden.
        let seen = entries(for: items).compactMap { entry -> (spot: Spot, shows: Bool)? in
            switch entry.kind {
            case .perch: return shown.contains(.perch) ? (.perch, true) : nil
            case .fixed: return nil
            case .icon(let key):
                if shown.contains(.icon(key)) { return (.icon(key), true) }
                guard members.contains(key), items.first(where: { $0.key == key })?.isMovable == true else { return nil }
                return (.icon(key), false)
            }
        }
        func weight(_ spot: Spot) -> Int {
            if case .icon(let key) = spot, moved.contains(key) { return 1 }
            return 1000
        }
        // Shown spots in `landed` that are in order with `order`, and their
        // weight: the longest such run, so one icon out of place doesn't make
        // every icon after it look wrong too.
        func inOrder(_ landed: [Spot]) -> (Set<Spot>, Int) {
            let wanted = order.filter(landed.contains)
            let n = wanted.count, m = landed.count
            var best = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    best[i][j] = wanted[i] == landed[j]
                        ? best[i + 1][j + 1] + weight(wanted[i])
                        : max(best[i + 1][j], best[i][j + 1])
                }
            }
            var kept = Set<Spot>()
            var i = 0, j = 0
            while i < n, j < m {
                if wanted[i] == landed[j], best[i][j] == best[i + 1][j + 1] + weight(wanted[i]) {
                    kept.insert(wanted[i]); i += 1; j += 1
                } else if best[i + 1][j] >= best[i][j + 1] {
                    i += 1
                } else {
                    j += 1
                }
            }
            return (kept, best[0][0])
        }

        // Hidden icons belong left of everything that shows. Try every line
        // between the two and keep the one that, with the shown order after
        // it, blames the fewest icons Perch left alone.
        var bestSplit = 0, bestCost = Int.max, bestKept = Set<Spot>()
        for split in 0...seen.count {
            var cost = 0
            for (k, entry) in seen.enumerated() where (k < split) == entry.shows { cost += weight(entry.spot) }
            let shownAfter = seen[split...].filter(\.shows).map(\.spot)
            let (kept, keptWeight) = inOrder(shownAfter)
            cost += shownAfter.reduce(0) { $0 + weight($1) } - keptWeight
            if cost < bestCost { bestSplit = split; bestCost = cost; bestKept = kept }
        }
        var result: [String] = []
        for (k, entry) in seen.enumerated() {
            let wrongSide = (k < bestSplit) == entry.shows
            let outOfOrder = k >= bestSplit && entry.shows && !bestKept.contains(entry.spot)
            if wrongSide || outOfOrder, case .icon(let key) = entry.spot { result.append(key) }
        }
        return result
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

        // Perch's own item always stays shown, so its room comes first.
        let perchIndex = list.firstIndex { $0.kind == .perch }
        if let perchIndex { room -= list[perchIndex].width + gap }

        // Walk right to left; `cut` ends up at the leftmost entry that stays shown.
        let movable = list.filter { $0.kind != .fixed }
        var cut = list.firstIndex { $0.kind == .fixed } ?? list.endIndex
        for entry in movable.reversed() {
            guard case .icon(let key) = entry.kind else { continue }
            // Icons macOS places itself are already counted in `reserved`. One
            // right next to the shown ones counts as shown, so Perch's item can
            // join the cut past it instead of chasing a spot macOS won't give.
            guard items.first(where: { $0.key == key })?.isMovable == true else {
                if let i = list.firstIndex(where: { $0.kind == entry.kind }), i == cut - 1 { cut = i }
                continue
            }
            let cost = entry.width + gap
            guard preferences.priority(for: key) != .hidden, cost <= room else { break }
            room -= cost
            cut = list.firstIndex { $0.kind == entry.kind } ?? cut
        }

        // If the cut fell right of Perch's item, move Perch to the cut; the
        // caller then places the divider left of it.
        if let perchIndex, perchIndex < cut {
            if perchIndex == cut - 1 {
                cut = perchIndex
            } else if let position = Self.between(cut > 0 ? list[cut - 1] : nil, cut < list.count ? list[cut] : nil),
                      menuBar.movePerch(to: position) {
                return true
            }
        }

        let leftOfCut = cut > 0 ? list[cut - 1] : nil
        let rightOfCut = cut < list.count ? list[cut] : nil
        // Already there: the divider sits between those two.
        if let divider = menuBar.dividerFrame() {
            let afterLeft = leftOfCut.map { $0.x < divider.maxX } ?? true
            let beforeRight = rightOfCut.map { divider.maxX < $0.x } ?? true
            if afterLeft && beforeRight { return false }
        }
        guard let position = Self.between(leftOfCut, rightOfCut) else { return false }
        guard menuBar.moveDivider(to: position) else { return false }
        let shownCount = list[cut...].filter { $0.kind != .fixed }.count
        log.notice("moving the divider so \(shownCount, privacy: .public) icons show")
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
        // The first hide waits for a real pass, so it hides only what doesn't fit.
        menuBar.placeFirst = { [weak self] in await self?.arrange() ?? true }
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
