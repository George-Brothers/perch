import SwiftUI

/// Your menu bar, in order, left to right. Drag an icon to where you want it
/// and Perch moves the real one there. Icons left of the line are hidden.
/// Used in the Arrange panel and in Settings → Icons.
struct ArrangeBar: View {
    @ObservedObject var engine: LayoutEngine
    @ObservedObject var preferences: Preferences
    @ObservedObject var permissions: Permissions
    @ObservedObject var images: IconImages
    var onOpenItem: ((MenuBarItem) -> Void)?
    var maxWidth: CGFloat = 640

    enum Slot: Hashable {
        case icon(String)
        case divider
        case perch
    }

    private struct DragState {
        let key: String
        var location: CGPoint
        /// Where in the icon you grabbed it.
        let grab: CGSize
        /// The bar as it was when the drag started.
        let original: [Slot]
        let frames: [Slot: CGRect]
    }

    @State private var drag: DragState?
    @State private var frames: [Slot: CGRect] = [:]
    @State private var contentWidth: CGFloat = 0
    /// The order you dropped, shown until Perch has moved the real icon.
    @State private var pending: [Slot]?

    var body: some View {
        if !permissions.hasAccessibility {
            PermissionCard(permissions: permissions)
        } else if !engine.hasScanned {
            HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                .frame(height: 60)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                bar
                Text("Drag to reorder. Left of the line is hidden. A dot means it shows when there's room.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !notShowing.isEmpty {
                    Text("Turned off in System Settings → Menu Bar: \(notShowing.map(\.displayName).joined(separator: ", ")).")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - The bar

    private var bar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(slots, id: \.self) { slot in
                    slotView(slot)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: SlotFrames.self, value: [slot: geometry.frame(in: .named("bar"))])
                        })
                }
            }
            .padding(.horizontal, 4)
            .frame(height: 34)
            .background(alignment: .leading) { hiddenZone }
            .overlay(alignment: .topLeading) { floatingIcon }
            .coordinateSpace(name: "bar")
            .animation(.snappy(duration: 0.18), value: slots)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: ContentWidth.self, value: geometry.size.width)
            })
        }
        .frame(width: min(max(contentWidth, 200), maxWidth))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .modifier(MatchIconColors(images: images, active: icons.contains { images.image(for: $0) != nil }))
        .onPreferenceChange(SlotFrames.self) { if drag == nil { frames = $0 } }
        .onPreferenceChange(ContentWidth.self) { contentWidth = $0 }
        .onChange(of: engine.isArranging) { _, arranging in if !arranging { pending = nil } }
        .onChange(of: barSignature) { _, _ in if !engine.isArranging { pending = nil } }
    }

    /// A light tint behind the hidden icons, up to the line.
    @ViewBuilder
    private var hiddenZone: some View {
        if let divider = frames[.divider], drag == nil {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.07))
                .frame(width: max(divider.minX - 2, 0), height: 30)
                .padding(.leading, 2)
        }
    }

    @ViewBuilder
    private func slotView(_ slot: Slot) -> some View {
        switch slot {
        case .divider:
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.secondary.opacity(0.7))
                .frame(width: 1.5, height: 18)
                .padding(.horizontal, 5)
                .help("Icons left of this line are hidden")
        case .perch:
            Image(systemName: preferences.iconStyle.symbolName(revealed: false))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 26)
                .help("Perch")
        case .icon(let key):
            if let item = item(key) {
                BarIcon(item: item, image: images.image(for: item),
                        showsWhenRoom: preferences.priority(for: key) == .auto,
                        clickable: onOpenItem != nil && !engine.isArranging)
                    .opacity(drag?.key == key ? 0 : 1)
                    .onTapGesture { if !engine.isArranging { onOpenItem?(item) } }
                    .gesture(dragGesture(for: key))
                    .contextMenu {
                        Text(item.displayName)
                        Divider()
                        ForEach(IconPriority.allCases) { priority in
                            Button(priority.menuTitle) { engine.setPriority(priority, for: item) }
                                .disabled(preferences.priority(for: key) == priority)
                        }
                    }
            }
        }
    }

    /// The icon you're dragging, under the pointer.
    @ViewBuilder
    private var floatingIcon: some View {
        if let drag, let item = item(drag.key), let frame = drag.frames[.icon(drag.key)] {
            BarIcon(item: item, image: images.image(for: item), showsWhenRoom: false, clickable: false)
                .frame(width: frame.width, height: frame.height)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.regularMaterial))
                .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
                .offset(x: drag.location.x - drag.grab.width, y: frame.minY)
                .allowsHitTesting(false)
        }
    }

    private func dragGesture(for key: String) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("bar"))
            .onChanged { value in
                guard !engine.isArranging else { return }
                if drag == nil, let frame = frames[.icon(key)] {
                    drag = DragState(
                        key: key, location: value.location,
                        grab: CGSize(width: value.startLocation.x - frame.minX, height: 0),
                        original: slots, frames: frames
                    )
                }
                drag?.location = value.location
            }
            .onEnded { _ in commit() }
    }

    // MARK: - Order

    /// What the bar shows: the live order, the order you dropped while Perch
    /// moves the icon, or the order you're dragging into.
    private var slots: [Slot] {
        guard let drag else { return pending ?? liveSlots }
        var others = drag.original.filter { $0 != .icon(drag.key) }
        // Insert before the first slot whose middle is right of the pointer.
        var index = others.firstIndex { slot in
            (drag.frames[slot]?.midX ?? .infinity) > drag.location.x
        } ?? others.count
        // An icon always needs something to its right to be dropped before.
        index = min(index, others.count - 1)
        others.insert(.icon(drag.key), at: index)
        return others
    }

    /// Hidden icons, the line, shown icons, Perch, then anything right of Perch.
    private var liveSlots: [Slot] {
        let perchX = engine.perchMinX ?? .infinity
        let byX = icons.sorted { $0.frame.minX < $1.frame.minX }
        let hidden = byX.filter { $0.section == .hidden }
        let shown = byX.filter { $0.section == .shown }
        return hidden.map { .icon($0.key) } + [.divider]
            + shown.filter { $0.frame.minX < perchX }.map { .icon($0.key) } + [.perch]
            + shown.filter { $0.frame.minX >= perchX }.map { .icon($0.key) }
    }

    private func commit() {
        guard let drag else { return }
        let final = slots
        self.drag = nil
        guard final != drag.original,
              let index = final.firstIndex(of: .icon(drag.key)), index + 1 < final.count,
              let dividerIndex = final.firstIndex(of: .divider),
              let item = item(drag.key)
        else { return }

        let anchor: LayoutEngine.Anchor
        switch final[index + 1] {
        case .icon(let key): anchor = .icon(key)
        case .divider: anchor = .divider
        case .perch: anchor = .perch
        }
        let shown = index > dividerIndex
        // Dropped on the shown side: a hidden icon now always shows; otherwise keep its setting.
        let current = preferences.priority(for: drag.key)
        let priority: IconPriority = shown ? (current == .hide ? .always : current) : .hide
        pending = final
        engine.place(item, .before(anchor, shown: shown), priority: priority)
    }

    // MARK: - Icons

    private var icons: [MenuBarItem] {
        engine.items.filter { $0.section != .notShowing && $0.isMovable }
    }

    private var notShowing: [MenuBarItem] {
        engine.items.filter { $0.section == .notShowing }
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

private struct ContentWidth: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// One icon in the bar: its real picture when Perch has one, else a symbol.
private struct BarIcon: View {
    let item: MenuBarItem
    let image: NSImage?
    let showsWhenRoom: Bool
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
        .overlay(alignment: .bottom) {
            if showsWhenRoom {
                Circle().fill(Color.secondary).frame(width: 3, height: 3).offset(y: 2)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(hovering && clickable ? 0.12 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(item.displayName)
        .accessibilityLabel(item.displayName)
    }
}

extension IconPriority {
    /// The same three names everywhere: shelves, right-click menus, the drawer.
    var menuTitle: String {
        switch self {
        case .always: "Always Show"
        case .auto: "Show When There's Room"
        case .hide: "Hide"
        }
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
