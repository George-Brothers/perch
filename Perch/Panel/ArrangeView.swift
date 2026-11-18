import SwiftUI

/// Arrange: your menu bar in rows that mirror it, left to right.
///
/// - **Menu bar**: the icons in the bar, in their real order. Order is priority:
///   when the bar runs out of room, the leftmost wait in Hidden until there's room.
/// - **Hidden**: icons that show only when you show hidden icons.
/// - **Turned off**: icons turned off in System Settings → Menu Bar.
///
/// Drag an icon to any spot in the bar or Hidden and Perch moves the real one there.
/// Used in the Arrange panel and in Settings → Icons.
struct ArrangeBar: View {
    @ObservedObject var engine: LayoutEngine
    @ObservedObject var preferences: Preferences
    @ObservedObject var permissions: Permissions
    @ObservedObject var images: IconImages
    var onOpenItem: ((MenuBarItem) -> Void)?
    var maxWidth: CGFloat = 640

    enum Row: Int, CaseIterable {
        case bar, hidden, off

        var title: String {
            switch self {
            case .bar: "Menu bar"
            case .hidden: "Hidden"
            case .off: "Turned off"
            }
        }
    }

    enum Slot: Hashable {
        case icon(String)
        case perch
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
    @State private var frames: [Slot: CGRect] = [:]
    @State private var rowFrames: [Row: CGRect] = [:]
    @State private var contentWidth: CGFloat = 0
    /// The rows as you dropped them, shown until Perch has moved the real icon.
    @State private var pending: [Row: [Slot]]?
    @State private var offHint: String?

    private let labelWidth: CGFloat = 70

    var body: some View {
        if !permissions.hasAccessibility {
            PermissionCard(permissions: permissions)
        } else if !engine.hasScanned {
            HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                .frame(height: 60)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Row.allCases, id: \.self) { row in
                        if row != .off || !(rows[.off] ?? []).isEmpty {
                            rowView(row)
                        }
                    }
                }
                .coordinateSpace(name: "arrange")
                .overlay(alignment: .topLeading) { floatingIcon }
                .onPreferenceChange(SlotFrames.self) { if drag == nil { frames = $0 } }
                .onPreferenceChange(RowFrames.self) { if drag == nil { rowFrames = $0 } }
                .onPreferenceChange(ContentWidth.self) { contentWidth = $0 }
                .animation(.snappy(duration: 0.18), value: rows)

                Text(offHint ?? "Drag icons to reorder them or move them between rows. When the bar is full, icons on the left wait in Hidden.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: rowWidth + labelWidth, alignment: .leading)
            }
            .onChange(of: engine.isArranging) { _, arranging in if !arranging { pending = nil } }
            .onChange(of: barSignature) { _, _ in if !engine.isArranging { pending = nil } }
        }
    }

    // MARK: - Rows

    private var rowWidth: CGFloat {
        min(max(contentWidth + 12, 260), maxWidth - labelWidth)
    }

    private func rowView(_ row: Row) -> some View {
        HStack(spacing: 0) {
            Text(row.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            HStack(spacing: 2) {
                let slots = rows[row] ?? []
                if slots.isEmpty {
                    Text(row == .hidden ? "Drag icons here to hide them" : "Drag icons here")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                }
                ForEach(slots, id: \.self) { slot in
                    slotView(slot, in: row)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: SlotFrames.self, value: [slot: geometry.frame(in: .named("arrange"))])
                        })
                }
            }
            .padding(.horizontal, 4)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: ContentWidth.self, value: geometry.size.width)
            })
            .frame(width: rowWidth, height: 32, alignment: .trailing)
            .clipped()
            .background(rowBackground(row))
            .background(GeometryReader { geometry in
                Color.clear.preference(key: RowFrames.self, value: [row: geometry.frame(in: .named("arrange"))])
            })
            .modifier(MatchIconColors(images: images, active: row != .off && hasPictures))
        }
    }

    @ViewBuilder
    private func rowBackground(_ row: Row) -> some View {
        let targeted = drag != nil && targetRow == row && row != .off
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        ZStack {
            if row == .bar {
                shape.fill(.regularMaterial)
            } else {
                shape.fill(Color.primary.opacity(0.05))
            }
            shape.strokeBorder(targeted ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08),
                               lineWidth: targeted ? 1.5 : 0.5)
        }
    }

    @ViewBuilder
    private func slotView(_ slot: Slot, in row: Row) -> some View {
        switch slot {
        case .perch:
            PerchMark(preferences: preferences)
                .opacity(drag?.slot == .perch ? 0 : 1)
                .gesture(dragGesture(for: .perch, from: row))
        case .icon(let key):
            if let item = item(key) {
                BarIcon(item: item, image: images.image(for: item),
                        waiting: row == .bar && item.section == .hidden && !engine.isArranging,
                        clickable: onOpenItem != nil && row != .off && !engine.isArranging)
                    .opacity(drag?.slot == slot ? 0 : (row == .off ? 0.5 : 1))
                    .onTapGesture {
                        if row == .off { explainOff(item) } else if !engine.isArranging { onOpenItem?(item) }
                    }
                    .gesture(dragGesture(for: slot, from: row))
                    .contextMenu { contextMenu(for: item, in: row) }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for item: MenuBarItem, in row: Row) -> some View {
        Text(item.displayName)
        Divider()
        switch row {
        case .bar: Button("Hide") { engine.setPriority(.hidden, for: item) }
        case .hidden: Button("Show in Menu Bar") { engine.setPriority(.shown, for: item) }
        case .off: Button("Turn On in System Settings…") { explainOff(item) }
        }
    }

    /// The icon you're dragging, under the pointer.
    @ViewBuilder
    private var floatingIcon: some View {
        if let drag, let frame = drag.frames[drag.slot] {
            Group {
                switch drag.slot {
                case .perch:
                    PerchMark(preferences: preferences)
                case .icon(let key):
                    if let item = item(key) {
                        BarIcon(item: item, image: images.image(for: item), waiting: false, clickable: false)
                    }
                }
            }
            .frame(width: frame.width, height: frame.height)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.regularMaterial))
            .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
            .offset(x: drag.location.x - drag.grab.width, y: drag.location.y - drag.grab.height)
            .allowsHitTesting(false)
        }
    }

    private func dragGesture(for slot: Slot, from row: Row) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("arrange"))
            .onChanged { value in
                guard !engine.isArranging else { return }
                if drag == nil, let frame = frames[slot] {
                    drag = DragState(
                        slot: slot, from: row, location: value.location,
                        grab: CGSize(width: value.startLocation.x - frame.minX, height: value.startLocation.y - frame.minY),
                        original: rows, frames: frames, rowFrames: rowFrames
                    )
                }
                drag?.location = value.location
            }
            .onEnded { _ in commit() }
    }

    // MARK: - Order

    /// The row under the pointer while dragging. Perch's own item stays in the bar.
    private var targetRow: Row? {
        guard let drag else { return nil }
        if drag.slot == .perch { return .bar }
        let rows = drag.rowFrames.filter { $0.key != .off }
        let hit = rows.first { $0.value.insetBy(dx: -40, dy: -4).contains(drag.location) }?.key
        return hit ?? rows.min { abs($0.value.midY - drag.location.y) < abs($1.value.midY - drag.location.y) }?.key
    }

    /// What each row shows: the live layout, the layout you dropped while Perch
    /// moves the icon, or the layout you're dragging into.
    private var rows: [Row: [Slot]] {
        guard let drag else { return pending ?? liveRows }
        var result = drag.original.mapValues { $0.filter { $0 != drag.slot } }
        // From Turned off, icons can't be placed: show them back where they were.
        guard drag.from != .off, let row = targetRow else { return drag.original }
        let others = result[row] ?? []
        let index = others.firstIndex { (drag.frames[$0]?.midX ?? .infinity) > drag.location.x } ?? others.count
        result[row, default: []].insert(drag.slot, at: index)
        return result
    }

    private var liveRows: [Row: [Slot]] {
        let byX = icons.sorted { $0.frame.minX < $1.frame.minX }
        var bar = byX.filter { $0.isInMenuBar && preferences.priority(for: $0.key) == .shown }.map { Slot.icon($0.key) }
        if let perchX = engine.perchMinX {
            let index = byX.filter { $0.isInMenuBar && preferences.priority(for: $0.key) == .shown }
                .firstIndex { $0.frame.minX > perchX } ?? bar.count
            bar.insert(.perch, at: index)
        }
        let hidden = byX.filter { $0.isInMenuBar && preferences.priority(for: $0.key) == .hidden }.map { Slot.icon($0.key) }
        let off = byX.filter { !$0.isInMenuBar }.map { Slot.icon($0.key) }
        return [.bar: bar, .hidden: hidden, .off: off]
    }

    private func commit() {
        guard let drag else { return }
        let final = rows
        let row = targetRow
        self.drag = nil
        if drag.from == .off, case .icon(let key) = drag.slot, let item = item(key), row != nil {
            explainOff(item)
            return
        }
        guard let row, final != drag.original,
              let index = final[row]?.firstIndex(of: drag.slot)
        else { return }

        let slots = final[row] ?? []
        let next = index + 1 < slots.count ? slots[index + 1] : nil
        let shown = row == .bar
        let anchor: LayoutEngine.Anchor
        switch next {
        case .icon(let key)?: anchor = .icon(key)
        case .perch?: anchor = .perch
        case nil: anchor = shown ? .end : .divider
        }
        pending = final
        offHint = nil
        switch drag.slot {
        case .perch:
            engine.placePerch(.before(anchor, shown: true))
        case .icon(let key):
            guard let item = item(key) else { return }
            engine.place(item, .before(anchor, shown: shown), priority: shown ? .shown : .hidden)
        }
    }

    /// Perch can't turn another app's icon back on; System Settings can.
    private func explainOff(_ item: MenuBarItem) {
        offHint = "Turn on \(item.displayName) under Allow in the Menu Bar, then it will show up here."
        if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Icons

    private var icons: [MenuBarItem] {
        engine.items.filter { $0.isMovable || !$0.isInMenuBar }.filter { !$0.isFixed }
    }

    private var hasPictures: Bool {
        icons.contains { images.image(for: $0) != nil }
    }

    private func item(_ key: String) -> MenuBarItem? {
        engine.items.first { $0.key == key }
    }

    /// Changes whenever an icon appears, goes or moves.
    private var barSignature: [String] {
        icons.map { "\($0.key)@\(Int($0.frame.minX))" }
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

private struct ContentWidth: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Perch's own item, as it looks in the bar.
private struct PerchMark: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        Image(systemName: preferences.iconStyle.symbolName(revealed: false))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 26)
            .contentShape(Rectangle())
            .help("Perch")
    }
}

/// One icon: its real picture when Perch has one, else a symbol.
private struct BarIcon: View {
    let item: MenuBarItem
    let image: NSImage?
    /// In the bar's order but waiting in Hidden because there's no room.
    let waiting: Bool
    let clickable: Bool
    @State private var hovering = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(height: min(image.size.height, 24))
                    .frame(minWidth: 22)
            } else {
                ItemIcon(item: item)
                    .frame(width: 16, height: 16)
                    .padding(.horizontal, 5)
                    .frame(height: 26)
            }
        }
        .opacity(waiting ? 0.4 : 1)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(hovering && clickable ? 0.12 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(waiting ? "\(item.displayName): no room right now" : item.displayName)
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

/// The Arrange panel under Perch's icon.
struct ArrangePanelView: View {
    @ObservedObject var engine: LayoutEngine
    let preferences: Preferences
    let permissions: Permissions
    let images: IconImages
    let maxWidth: CGFloat
    let onOpenItem: (MenuBarItem) -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Arrange")
                    .font(.system(size: 13, weight: .semibold))
                if engine.isArranging {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                Menu {
                    Button("Settings…", action: onOpenSettings)
                    Divider()
                    Button("Quit Perch") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 13))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Settings and Quit")
            }

            ArrangeBar(engine: engine, preferences: preferences, permissions: permissions,
                       images: images, onOpenItem: onOpenItem, maxWidth: maxWidth)
        }
        .padding(14)
        .frame(minWidth: 320, alignment: .leading)
        .fixedSize()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
    }
}
