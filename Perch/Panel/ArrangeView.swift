import SwiftUI
import os

private let arrangeLog = Logger(subsystem: "com.georgebrothers.perch", category: "arrange")

/// Arrange: your menu bar as one strip, left to right, the way macOS lays it out.
///
/// Hidden icons sit dimmed left of a line; the icons in the menu bar sit right
/// of it, in their real order. Order is priority: when the bar runs out of
/// room, the leftmost wait in Hidden until there's room.
///
/// Drag an icon to any spot and Perch moves the real one there. Drag the line
/// to hide or show the icons next to it.
struct ArrangeBar: View {
    @ObservedObject var engine: LayoutEngine
    @ObservedObject var preferences: Preferences
    @ObservedObject var permissions: Permissions
    @ObservedObject var images: IconImages
    var onOpenItem: ((MenuBarItem) -> Void)?
    /// The strip's height: Arrange over the menu bar matches the bar's.
    var height: CGFloat = 32
    /// Arrange below the menu bar shows notes under the strip; over the bar,
    /// its toolbar shows them instead.
    var showsNotes = true

    enum Row: Int, CaseIterable {
        case hidden, bar

        var title: String {
            switch self {
            case .bar: "Menu bar"
            case .hidden: "Hidden"
            }
        }
    }

    enum Slot: Hashable {
        case icon(String)
        case perch
        /// The line between Hidden and the menu bar.
        case split
    }

    private struct DragState {
        let slot: Slot
        let from: Row
        var location: CGPoint
        /// Where in the icon you grabbed it.
        let grab: CGSize
        let original: [Row: [Slot]]
        let frames: [Slot: CGRect]
        let rowFrames: [Row: CGRect]
    }

    @State private var drag: DragState?
    /// True while the pointer is down. It also resets when a drag is cancelled,
    /// which `onEnded` doesn't report, so a cancelled drag can't leave an icon stuck.
    @GestureState private var dragging = false
    @State private var frames: [Slot: CGRect] = [:]
    @State private var rowFrames: [Row: CGRect] = [:]
    @State private var stripWidth: CGFloat = 0
    /// This press started on nothing; logged once.
    @State private var ignoredDrag = false

    var body: some View {
        if !permissions.hasAccessibility {
            PermissionCard(permissions: permissions)
        } else if !engine.hasScanned {
            HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                .frame(width: 200, height: height)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                strip
                if showsNotes, let note = ArrangeNotes.text(engine) {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: max(stripWidth - 12, 220), alignment: .leading)
                        .padding(.horizontal, 6)
                }
            }
        }
    }

    // MARK: - Strip

    private var strip: some View {
        HStack(spacing: 0) {
            if engine.isArranging {
                ProgressView().controlSize(.mini).padding(.leading, 6)
            }
            zone(.hidden)
            splitLine
            zone(.bar)
        }
        .coordinateSpace(name: "arrange")
        // On the strip, not on each icon: an icon dragged into the other side
        // is a new view, and a gesture on the old one never ends.
        .simultaneousGesture(dragGesture)
        .onChange(of: dragging) { _, down in
            guard !down else { return }
            ignoredDrag = false
            // After onEnded has had its chance to drop the icon.
            DispatchQueue.main.async { drag = nil }
        }
        .overlay(alignment: .topLeading) { floatingIcon }
        // Always current: a drag snapshots these when it starts.
        .onPreferenceChange(SlotFrames.self) { frames = $0 }
        .onPreferenceChange(RowFrames.self) { rowFrames = $0 }
        .background(GeometryReader { geometry in
            Color.clear.preference(key: ArrangeStripWidth.self, value: geometry.size.width)
        })
        .onPreferenceChange(ArrangeStripWidth.self) { stripWidth = $0 }
        .animation(.snappy(duration: 0.18), value: rows)
    }

    private func zone(_ row: Row) -> some View {
        let slots = rows[row] ?? []
        let targeted = drag != nil && drag?.slot != .split && targetRow == row && drag?.from != row
        return HStack(spacing: engine.iconGap) {
            if row == .bar {
                ForEach(pinned) { item in pinnedView(item) }
            }
            ForEach(slots, id: \.self) { slot in
                slotView(slot, in: row)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: SlotFrames.self, value: [slot: geometry.frame(in: .named("arrange"))])
                    })
            }
        }
        .padding(.horizontal, 6)
        .frame(minWidth: row == .hidden ? 64 : 40, minHeight: height, maxHeight: height, alignment: .trailing)
        .overlay {
            // An empty Hidden still shows where to drop.
            if row == .hidden && slots.isEmpty {
                Text("Hidden")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .allowsHitTesting(false)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(targeted ? 0.08 : 0))
        )
        .overlay(alignment: .trailing) { if row == .bar { laptopEdge } }
        .background(GeometryReader { geometry in
            Color.clear.preference(key: RowFrames.self, value: [row: geometry.frame(in: .named("arrange"))])
        })
    }

    private var splitLine: some View {
        let active = drag?.slot == .split
        return Capsule()
            .fill(Color.white.opacity(active ? 0.95 : 0.5))
            .frame(width: active ? 3 : 2, height: min(20, height - 8))
            .frame(width: 14, height: height)
            .contentShape(Rectangle())
            // Not NSCursor push/pop: Arrange can close with the pointer
            // still on the line, and the pop would never come.
            .pointerStyle(.columnResize)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: SlotFrames.self, value: [.split: geometry.frame(in: .named("arrange"))])
            })
            .help("Icons left of the line are hidden. Drag it to hide or show the icons next to it.")
            .accessibilityLabel("Hidden icons end here")
    }

    /// On another display: where a MacBook's screen would cut the bar off.
    @ViewBuilder
    private var laptopEdge: some View {
        if let laptop = engine.laptopRoom, laptop > 0, laptop + 8 < (rowFrames[.bar]?.width ?? 0) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: height, alignment: .top)
                .overlay(alignment: .bottom) {
                    Capsule().fill(Color.secondary.opacity(0.6)).frame(width: 1.5, height: max(height - 16, 8))
                }
                .padding(.trailing, laptop + 6 - 9)
                .allowsHitTesting(false)
                .help("A MacBook's screen ends here")
        }
    }

    @ViewBuilder
    private func slotView(_ slot: Slot, in row: Row) -> some View {
        switch slot {
        case .perch:
            PerchMark(preferences: preferences, width: engine.perchWidth)
                .opacity(drag?.slot == .perch ? 0 : 1)
        case .split:
            EmptyView()
        case .icon(let key):
            if let item = item(key) {
                BarIcon(item: item, image: images.image(for: item), invert: !images.isLight(item),
                        width: item.frame.width, maxHeight: height,
                        waiting: engine.isArranging ? nil : waitingNote(for: item, in: row),
                        clickable: onOpenItem != nil && !engine.isArranging)
                    .opacity(drag?.slot == slot ? 0 : (row == .hidden ? 0.5 : 1))
                    .onTapGesture { if !engine.isArranging { onOpenItem?(item) } }
                    .contextMenu { contextMenu(for: item, in: row) }
            }
        }
    }

    /// A Live Activity or the mic and camera dot: macOS puts these at the left
    /// end of the menu bar itself, so they're shown there and can't be dragged.
    private func pinnedView(_ item: MenuBarItem) -> some View {
        BarIcon(item: item, image: images.image(for: item), invert: !images.isLight(item),
                width: item.frame.width, maxHeight: height, waiting: nil, clickable: false,
                tooltip: item.isLiveActivity
                    ? "\(item.displayName) Live Activity. macOS always puts these at the left end of the menu bar, so Perch makes room for them. It goes away when the app ends it."
                    : "\(item.displayName). macOS places this one itself.")
            .opacity(0.75)
    }

    @ViewBuilder
    private func contextMenu(for item: MenuBarItem, in row: Row) -> some View {
        Text(item.displayName)
        Divider()
        switch row {
        case .bar: Button("Hide") { engine.place(item, .before(.divider, shown: false)) }
        case .hidden: Button("Show in Menu Bar") { engine.place(item, .before(.divider, shown: true)) }
        }
    }

    /// The icon you're dragging, under the pointer.
    @ViewBuilder
    private var floatingIcon: some View {
        if let drag, drag.slot != .split, let frame = drag.frames[drag.slot] {
            Group {
                switch drag.slot {
                case .perch:
                    PerchMark(preferences: preferences, width: engine.perchWidth)
                case .icon(let key):
                    if let item = item(key) {
                        BarIcon(item: item, image: images.image(for: item), invert: !images.isLight(item),
                                width: nil, maxHeight: height, waiting: nil, clickable: false)
                    }
                case .split:
                    EmptyView()
                }
            }
            .frame(width: frame.width, height: frame.height)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(white: 0.24)))
            .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
            .offset(x: drag.location.x - drag.grab.width, y: drag.location.y - drag.grab.height)
            .allowsHitTesting(false)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("arrange"))
            .updating($dragging) { _, down, _ in down = true }
            .onChanged { value in
                if drag == nil, let (slot, frame) = frames.first(where: { $0.value.contains(value.startLocation) }),
                   let row = slot == .split ? .bar : rows.first(where: { $0.value.contains(slot) })?.key {
                    drag = DragState(
                        slot: slot, from: row, location: value.location,
                        grab: CGSize(width: value.startLocation.x - frame.minX, height: value.startLocation.y - frame.minY),
                        original: rows, frames: frames, rowFrames: rowFrames
                    )
                    arrangeLog.debug("drag started from \(slot == .split ? "the line" : row.title, privacy: .public)")
                } else if drag == nil, !ignoredDrag {
                    ignoredDrag = true
                    arrangeLog.debug("drag ignored: nothing under the pointer")
                }
                drag?.location = value.location
            }
            .onEnded { value in
                // Let go well away from the strip: you changed your mind.
                let p = value.location
                guard p.y > -height, p.y < height * 2, p.x > -40, p.x < stripWidth + 40 else {
                    arrangeLog.debug("dropped outside Arrange; nothing moves")
                    return
                }
                commit()
            }
    }

    // MARK: - Order

    /// The side of the line under the pointer while dragging. Perch's own item stays in the bar.
    private var targetRow: Row? {
        guard let drag else { return nil }
        if drag.slot == .perch || drag.slot == .split { return .bar }
        guard let bar = drag.rowFrames[.bar] else { return .bar }
        // The line sits between the two sides; its middle is the boundary.
        return drag.location.x < bar.minX - 7 ? .hidden : .bar
    }

    /// What each side shows: the live layout (which already includes any move
    /// you dropped), or the layout you're dragging into.
    private var rows: [Row: [Slot]] {
        guard let drag else { return liveRows }
        if drag.slot == .split { return splitRows(drag) }
        var result = drag.original.mapValues { $0.filter { $0 != drag.slot } }
        guard let row = targetRow else { return drag.original }
        let others = result[row] ?? []
        let index = others.firstIndex { (drag.frames[$0]?.midX ?? .infinity) > drag.location.x } ?? others.count
        result[row, default: []].insert(drag.slot, at: index)
        return result
    }

    /// While you drag the line: every icon left of the pointer is hidden.
    /// Perch's own item stays in the bar, next to the icon it was next to.
    private func splitRows(_ drag: DragState) -> [Row: [Slot]] {
        let hidden = drag.original[.hidden] ?? []
        let bar = drag.original[.bar] ?? []
        let icons = hidden + bar.filter { $0 != .perch }
        let count = icons.filter { (drag.frames[$0]?.midX ?? .infinity) < drag.location.x }.count
        var newBar = Array(icons.dropFirst(count))
        if let perch = bar.firstIndex(of: .perch) {
            let after = bar.dropFirst(perch + 1).first
            let index = after.flatMap { newBar.firstIndex(of: $0) } ?? (after == nil ? newBar.count : 0)
            newBar.insert(.perch, at: index)
        }
        return [.hidden: Array(icons.prefix(count)), .bar: newBar]
    }

    private var liveRows: [Row: [Slot]] {
        let byX = icons.sorted { $0.frame.minX < $1.frame.minX }
        // Moves waiting for Arrange to close: show the order you set.
        if let queued = engine.queuedBar {
            let present = Set(byX.map(\.key))
            var bar = queued.compactMap { spot -> Slot? in
                switch spot {
                case .icon(let key): return present.contains(key) ? .icon(key) : nil
                case .perch: return engine.perchMinX == nil ? nil : .perch
                }
            }
            // Icons that appeared since stay where they are until you move one.
            func minX(_ slot: Slot) -> CGFloat? {
                switch slot {
                case .icon(let key): return byX.first { $0.key == key }?.frame.minX
                case .perch: return engine.perchMinX
                case .split: return nil
                }
            }
            for item in byX where !engine.queuedFrom.contains(item.key)
                && preferences.priority(for: item.key) == .shown {
                let index = bar.firstIndex { (minX($0) ?? -.infinity) > item.frame.minX } ?? bar.count
                bar.insert(.icon(item.key), at: index)
            }
            let hidden = engine.inHiddenOrder(byX.filter { !bar.contains(.icon($0.key)) })
                .map { Slot.icon($0.key) }
            return [.bar: bar, .hidden: hidden]
        }
        let shown = byX.filter { preferences.priority(for: $0.key) == .shown }
        var bar = shown.map { Slot.icon($0.key) }
        if let perchX = engine.perchMinX {
            bar.insert(.perch, at: shown.firstIndex { $0.frame.minX > perchX } ?? bar.count)
        }
        let hidden = engine.inHiddenOrder(byX.filter { preferences.priority(for: $0.key) == .hidden })
            .map { Slot.icon($0.key) }
        return [.bar: bar, .hidden: hidden]
    }

    private func commit() {
        guard let drag else { return }
        let final = rows
        let row = targetRow
        self.drag = nil
        if drag.slot == .split {
            commitSplit(from: drag.original, to: final)
            return
        }
        guard let row, final != drag.original,
              let index = final[row]?.firstIndex(of: drag.slot)
        else {
            arrangeLog.debug("drop ignored: \(row == nil ? "no side" : "same spot", privacy: .public) (from \(drag.from.title, privacy: .public) at \(Int(drag.location.x), privacy: .public),\(Int(drag.location.y), privacy: .public))")
            return
        }

        let slots = final[row] ?? []
        let next = index + 1 < slots.count ? slots[index + 1] : nil
        let shown = row == .bar
        let anchor: LayoutEngine.Anchor
        switch next {
        case .icon(let key)?: anchor = .icon(key)
        case .perch?: anchor = .perch
        case .split?, nil: anchor = shown ? .end : .divider
        }
        switch drag.slot {
        case .perch:
            _ = engine.placePerch(.before(anchor, shown: true))
        case .icon(let key):
            guard let item = item(key) else { break }
            arrangeLog.debug("dropped \(item.displayName, privacy: .public) in \(row.title, privacy: .public)")
            // Accepted: Arrange draws the engine's order from here. Refused: back where it was.
            _ = engine.place(item, .before(anchor, shown: shown))
        case .split:
            break
        }
    }

    /// The line moved: the icons it passed change sides, one move each, so
    /// they keep their order.
    private func commitSplit(from original: [Row: [Slot]], to final: [Row: [Slot]]) {
        let before = original[.hidden] ?? []
        let after = final[.hidden] ?? []
        guard before.count != after.count else { return }
        arrangeLog.debug("line moved by \(after.count - before.count, privacy: .public)")
        if after.count < before.count {
            // Shown at the left end of the bar, nearest the line first.
            var anchor: LayoutEngine.Anchor
            switch (original[.bar] ?? []).first {
            case .icon(let key)?: anchor = .icon(key)
            case .perch?: anchor = .perch
            case .split?, nil: anchor = .end
            }
            for slot in before[after.count...].reversed() {
                guard case .icon(let key) = slot, let item = item(key) else { continue }
                guard engine.place(item, .before(anchor, shown: true)) else { break }
                anchor = .icon(key)
            }
        } else {
            // Hidden at the right end of Hidden, in order.
            for slot in after[before.count...] {
                guard case .icon(let key) = slot, let item = item(key) else { continue }
                guard engine.place(item, .before(.divider, shown: false)) else { break }
            }
        }
    }

    // MARK: - Icons

    /// Icons in the menu bar that Perch can move. (Icons turned off in System
    /// Settings aren't in the bar, so Arrange leaves them out.)
    private var icons: [MenuBarItem] {
        engine.items.filter { $0.isMovable && $0.isInMenuBar }
    }

    /// Showing icons macOS places itself, left of the clock and Control Center.
    private var pinned: [MenuBarItem] {
        engine.items
            .filter { !$0.isMovable && !$0.isFixed && $0.isInMenuBar && $0.section == .shown }
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Why an icon is drawn faded: it isn't where its side says yet.
    private func waitingNote(for item: MenuBarItem, in row: Row) -> String? {
        if engine.hasQueuedMoves { return nil }
        return row == .bar && item.section == .hidden ? "no room right now" : nil
    }

    private func item(_ key: String) -> MenuBarItem? {
        engine.items.first { $0.key == key }
    }
}

/// What Arrange has to tell you, if anything.
enum ArrangeNotes {
    @MainActor
    static func text(_ engine: LayoutEngine) -> String? {
        if let notice = engine.notice { return notice }
        if engine.waitsForClose { return "The menu bar updates when you close Arrange." }
        return nil
    }
}

private struct SlotFrames: PreferenceKey {
    static let defaultValue: [ArrangeBar.Slot: CGRect] = [:]
    static func reduce(value: inout [ArrangeBar.Slot: CGRect], nextValue: () -> [ArrangeBar.Slot: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct RowFrames: PreferenceKey {
    static let defaultValue: [ArrangeBar.Row: CGRect] = [:]
    static func reduce(value: inout [ArrangeBar.Row: CGRect], nextValue: () -> [ArrangeBar.Row: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// How wide Arrange's strip is, so the panel around it can fit it.
struct ArrangeStripWidth: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Perch's own item, as it looks in the bar.
private struct PerchMark: View {
    @ObservedObject var preferences: Preferences
    var width: CGFloat?

    var body: some View {
        Group {
            if preferences.barItem == .line {
                Capsule().fill(.secondary).frame(width: 2, height: 14)
            } else {
                Image(systemName: preferences.iconStyle.symbolName(revealed: false))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
            .frame(width: width ?? 22, height: 26)
            .contentShape(Rectangle())
            .help("Perch")
    }
}

/// One icon: its real picture when Perch has one, else a symbol.
private struct BarIcon: View {
    let item: MenuBarItem
    let image: NSImage?
    /// The picture was taken on a light menu bar; Arrange is dark.
    let invert: Bool
    /// The icon's real width in the bar, so the strip is drawn to scale.
    let width: CGFloat?
    /// Pictures are drawn at their real size, up to the strip's height.
    let maxHeight: CGFloat
    /// Why it's drawn faded: it's on the menu bar side but there's no room for it.
    let waiting: String?
    let clickable: Bool
    var tooltip: String?
    @State private var hovering = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .modifier(LightOnDark(active: invert))
                    .frame(height: min(image.size.height, maxHeight))
                    .frame(minWidth: width == nil ? 22 : nil)
            } else {
                ItemIcon(item: item)
                    .frame(width: 16, height: 16)
                    .padding(.horizontal, width == nil ? 5 : 0)
                    .frame(height: 26)
            }
        }
        .frame(width: width.flatMap { $0 > 4 ? $0 : nil })
        .opacity(waiting == nil ? 1 : 0.4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(hovering && clickable ? 0.12 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(tooltip ?? waiting.map { "\(item.displayName): \($0)" } ?? item.displayName)
        .accessibilityLabel(item.displayName)
    }
}

struct ItemIcon: View {
    let item: MenuBarItem

    var body: some View {
        if let symbol = item.systemSymbol {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
        } else if let icon = item.appIcon {
            Image(nsImage: icon).resizable().interpolation(.high)
        } else {
            Image(systemName: "app.dashed").foregroundStyle(.secondary)
        }
    }
}

struct PermissionCard: View {
    @ObservedObject var permissions: Permissions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Let Perch arrange your menu bar")
                .font(.headline)
            Text("Perch needs Accessibility access to see your icons and move them. It uses it for nothing else.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Allow Access…") { permissions.requestAccessibility() }
                .buttonStyle(.borderedProminent)
        }
        .padding(6)
    }
}

/// Where Arrange over the menu bar goes, in points from the screen's left edge.
struct OverBarGeometry: Equatable {
    /// The screen's width; the panel spans it.
    let width: CGFloat
    let barHeight: CGFloat
    /// Where the band starts: the screen's left edge, or right of the notch.
    let bandStart: CGFloat
    /// Where it ends: just left of the clock and Control Center, which stay visible.
    let bandEnd: CGFloat
}

/// The Arrange panel: the strip under the menu bar, or over it.
struct ArrangePanelView: View {
    @ObservedObject var engine: LayoutEngine
    @ObservedObject var preferences: Preferences
    let permissions: Permissions
    let images: IconImages
    /// Where the menu bar is, for Arrange over it. Read each time it draws.
    let overBar: () -> OverBarGeometry?
    let onOpenItem: (MenuBarItem) -> Void
    let onOpenSettings: () -> Void
    let onDone: () -> Void

    @State private var stripWidth: CGFloat = 0

    var body: some View {
        Group {
            if preferences.arrangeStyle == .over, let geometry = overBar() {
                over(geometry)
            } else {
                below
            }
        }
        .environment(\.colorScheme, .dark)
        .onPreferenceChange(ArrangeStripWidth.self) { stripWidth = $0 }
        .contextMenu {
            Button("Settings…", action: onOpenSettings)
            Divider()
            Button("Quit Perch") { NSApp.terminate(nil) }
        }
        .background {
            Button("Settings…", action: onOpenSettings)
                .keyboardShortcut(",", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
        }
    }

    private func strip(height: CGFloat = 32, notes: Bool = true) -> some View {
        ArrangeBar(engine: engine, preferences: preferences, permissions: permissions,
                   images: images, onOpenItem: onOpenItem, height: height, showsNotes: notes)
    }

    /// One dark bar under the menu bar: the gear, then the strip.
    private var below: some View {
        // With a lot of icons the strip can be wider than the screen: then it
        // scrolls, starting at the right end, and the gear stays put.
        let room = (NSScreen.main?.visibleFrame.width ?? 1400) - 80
        return HStack(alignment: .top, spacing: 2) {
            SettingsGear(action: onOpenSettings)
                .frame(height: 32)
            if stripWidth > room {
                ScrollView(.horizontal, showsIndicators: false) { strip() }
                    .defaultScrollAnchor(.trailing)
                    .frame(width: room)
            } else {
                strip()
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .fixedSize()
        .perchSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// The menu bar turns into the strip, with a small toolbar under it. If
    /// the strip doesn't fit (beside a notch), it's the bar under the menu bar instead.
    @ViewBuilder
    private func over(_ geometry: OverBarGeometry) -> some View {
        let band = max(0, geometry.bandEnd - geometry.bandStart)
        // Before Accessibility (or the first scan), Arrange is a card that
        // can't squeeze into the menu bar's height.
        let ready = permissions.hasAccessibility && engine.hasScanned
        let fits = ready && (stripWidth == 0 || stripWidth + 12 <= band)
        VStack(alignment: .leading, spacing: 6) {
            if fits {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    strip(height: geometry.barHeight, notes: false)
                }
                .padding(.trailing, 4)
                .frame(width: band, height: geometry.barHeight)
                .background(Color(white: 0.07))
                .padding(.leading, geometry.bandStart)
                toolbar
                    .frame(width: geometry.bandEnd, alignment: .trailing)
            } else {
                Color.clear.frame(height: geometry.barHeight)
                below
                    .frame(width: geometry.bandEnd, alignment: .trailing)
            }
        }
        .frame(width: geometry.width, alignment: .topLeading)
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Text(ArrangeNotes.text(engine) ?? "Drag icons to rearrange. Hidden icons are left of the line.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: 360, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Divider().frame(height: 16)
            SettingsGear(action: onOpenSettings)
            Button("Done", action: onDone)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .fixedSize()
        .perchSurface(Capsule(style: .continuous))
    }
}

private struct SettingsGear: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: 13))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Settings")
        .accessibilityLabel("Settings")
    }
}
