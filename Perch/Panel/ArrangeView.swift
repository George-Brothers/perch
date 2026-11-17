import SwiftUI

/// One row per menu bar icon with an Always / Auto / Hide switch.
/// Used in the dropdown and in Settings → Icons.
struct ArrangeList: View {
    @ObservedObject var engine: LayoutEngine
    @ObservedObject var preferences: Preferences
    @ObservedObject var permissions: Permissions
    var onOpenItem: ((MenuBarItem) -> Void)?

    /// Closest to the bird first, the same order you read the bar from the right.
    private var arrangeable: [MenuBarItem] {
        engine.items.filter { $0.section != .notShowing }.sorted { $0.frame.minX > $1.frame.minX }
    }

    private var turnedOff: [MenuBarItem] {
        engine.items.filter { $0.section == .notShowing }
    }

    var body: some View {
        if !permissions.hasAccessibility {
            PermissionCard(permissions: permissions)
        } else if !engine.hasScanned {
            HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                .padding(.vertical, 20)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(arrangeable) { item in
                    ItemRow(item: item, priority: binding(for: item), onOpen: onOpenItem)
                }
                if !turnedOff.isEmpty {
                    Text("macOS isn't showing \(turnedOff.map(\.displayName).joined(separator: ", ")). You can turn them on in System Settings → Menu Bar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                        .padding(.horizontal, 6)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func binding(for item: MenuBarItem) -> Binding<IconPriority> {
        Binding(
            get: { preferences.priority(for: item.key) },
            set: { engine.setPriority($0, for: item) }
        )
    }
}

private struct ItemRow: View {
    let item: MenuBarItem
    @Binding var priority: IconPriority
    var onOpen: ((MenuBarItem) -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                onOpen?(item)
            } label: {
                HStack(spacing: 10) {
                    ItemIcon(item: item)
                        .frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.displayName)
                            .lineLimit(1)
                        Text(item.section == .shown ? "In the menu bar" : "Hidden")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onOpen == nil)
            .help(onOpen == nil ? item.displayName : "Open \(item.displayName)")

            Picker("", selection: $priority) {
                ForEach(IconPriority.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.06) : .clear)
        )
        .onHover { hovering = $0 }
    }
}

struct ItemIcon: View {
    let item: MenuBarItem

    var body: some View {
        if let symbol = item.systemSymbol {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.08)))
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

/// The dropdown under the bird: just the list, a title and a settings button.
struct ArrangePanelView: View {
    @ObservedObject var engine: LayoutEngine
    let preferences: Preferences
    let permissions: Permissions
    let onOpenItem: (MenuBarItem) -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Arrange Icons")
                    .font(.headline)
                if engine.isArranging {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                Button(action: onOpenSettings) { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .help("Perch Settings")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ScrollView {
                ArrangeList(engine: engine, preferences: preferences, permissions: permissions, onOpenItem: onOpenItem)
                    .padding(.horizontal, 8)
            }
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)

            Text("**Always** stays in the bar. **Auto** stays when there's room. **Hide** shows when you click Perch's icon.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(width: 360)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
    }
}
