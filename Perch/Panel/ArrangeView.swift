import SwiftUI
import UniformTypeIdentifiers

/// Your menu bar as three shelves. Drag an icon to the shelf you want.
/// Used in the dropdown and in Settings → Icons.
struct ArrangeShelves: View {
    @ObservedObject var engine: LayoutEngine
    @ObservedObject var preferences: Preferences
    @ObservedObject var permissions: Permissions
    @ObservedObject var images: IconImages
    var onOpenItem: ((MenuBarItem) -> Void)?

    var body: some View {
        if !permissions.hasAccessibility {
            PermissionCard(permissions: permissions)
        } else if !engine.hasScanned {
            HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                .frame(height: 180)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(IconPriority.allCases) { priority in
                    Shelf(
                        priority: priority,
                        items: items(for: priority),
                        images: images,
                        isArranging: engine.isArranging,
                        onOpen: onOpenItem,
                        onMove: { key, target in move(key, to: target) }
                    )
                }
                if !notShowing.isEmpty {
                    Text("Turned off in System Settings → Menu Bar: \(notShowing.map(\.displayName).joined(separator: ", ")).")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Icons in menu bar order, left to right, like the bar itself.
    private func items(for priority: IconPriority) -> [MenuBarItem] {
        engine.items
            .filter { $0.section != .notShowing && $0.isMovable && preferences.priority(for: $0.key) == priority }
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    private var notShowing: [MenuBarItem] {
        engine.items.filter { $0.section == .notShowing }
    }

    private func move(_ key: String, to priority: IconPriority) {
        guard let item = engine.items.first(where: { $0.key == key }) else { return }
        withAnimation(.snappy(duration: 0.2)) {
            engine.setPriority(priority, for: item)
        }
    }
}

private extension IconPriority {
    var shelfTitle: String {
        switch self {
        case .always: "Always in the menu bar"
        case .auto: "When there's room"
        case .hide: "Hidden"
        }
    }

    var shelfSymbol: String {
        switch self {
        case .always: "pin.fill"
        case .auto: "arrow.left.and.right"
        case .hide: "eye.slash"
        }
    }
}

private struct Shelf: View {
    let priority: IconPriority
    let items: [MenuBarItem]
    @ObservedObject var images: IconImages
    let isArranging: Bool
    let onOpen: ((MenuBarItem) -> Void)?
    let onMove: (String, IconPriority) -> Void
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(priority.shelfTitle, systemImage: priority.shelfSymbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .labelStyle(ShelfLabelStyle())

            HStack(spacing: 2) {
                ForEach(items) { item in
                    ShelfIcon(item: item, image: images.image(for: item), disabled: isArranging, onOpen: onOpen)
                        .draggable(item.key) {
                            ShelfIcon(item: item, image: images.image(for: item), disabled: true, onOpen: nil)
                        }
                        .contextMenu {
                            Text(item.displayName)
                            Divider()
                            ForEach(IconPriority.allCases.filter { $0 != priority }) { target in
                                Button("Move to \(target.shelfTitle)") { onMove(item.key, target) }
                            }
                        }
                }
                if items.isEmpty {
                    Text("Drag icons here")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                }
                Spacer(minLength: 0)
            }
            .padding(4)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(isTargeted ? 0.1 : 0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isTargeted ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.06),
                                  lineWidth: isTargeted ? 1.5 : 0.5)
            )
            .environment(\.colorScheme, images.iconsAreLight ? .dark : .light)
            .dropDestination(for: String.self) { keys, _ in
                for key in keys { onMove(key, priority) }
                return !keys.isEmpty
            } isTargeted: { isTargeted = $0 }
        }
    }
}

private struct ShelfLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 9, weight: .semibold))
            configuration.title
        }
    }
}

/// One icon on a shelf: the real picture when Perch has one, else a symbol.
private struct ShelfIcon: View {
    let item: MenuBarItem
    let image: NSImage?
    let disabled: Bool
    let onOpen: ((MenuBarItem) -> Void)?
    @State private var hovering = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 24)
            } else {
                ItemIcon(item: item)
                    .frame(width: 18, height: 18)
                    .padding(.horizontal, 6)
                    .frame(height: 26)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.12 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if !disabled { onOpen?(item) } }
        .help(item.displayName)
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

/// The dropdown under the bird: the shelves, a title and a settings button.
struct ArrangePanelView: View {
    @ObservedObject var engine: LayoutEngine
    let preferences: Preferences
    let permissions: Permissions
    let images: IconImages
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
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help("Perch Settings")
            }

            ArrangeShelves(engine: engine, preferences: preferences, permissions: permissions,
                           images: images, onOpenItem: onOpenItem)
        }
        .padding(14)
        .frame(width: 380)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
    }
}
