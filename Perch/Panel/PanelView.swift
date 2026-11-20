import SwiftUI

struct PanelView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var permissions: Permissions
    @ObservedObject var menuBar: MenuBarController
    @ObservedObject var preferences: Preferences

    let onOpenItem: (MenuBarItem) -> Void
    let onToggleBar: () -> Void
    let onOpenSettings: () -> Void

    private var visibleSections: [MenuBarItem.Section] {
        var sections: [MenuBarItem.Section] = [.hidden, .shown]
        if preferences.archivedSectionEnabled { sections.insert(.archived, at: 1) }
        sections.append(.notShowing)
        return sections
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.6)
            content
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            if permissions.hasAccessibility {
                Divider().opacity(0.6)
                Text("Hold ⌘ and drag icons in the menu bar to move them between sections.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
            }
        }
        .frame(width: 380)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bird.fill")
                .foregroundStyle(Color.accentColor)
            Text("Perch")
                .font(.headline)
            Spacer()
            Button(action: onToggleBar) {
                Label(menuBar.visibility.isRevealed ? "Hide in Bar" : "Show in Bar",
                      systemImage: menuBar.visibility.isRevealed ? "eye.slash" : "eye")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            .help("Show or hide your hidden icons in the menu bar itself")
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Perch Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if !permissions.hasAccessibility {
            PermissionCard(permissions: permissions)
        } else if !model.hasScanned {
            HStack {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
            .padding(.vertical, 24)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(visibleSections, id: \.self) { section in
                        sectionView(section)
                    }
                }
            }
            .frame(maxHeight: 460)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func sectionView(_ section: MenuBarItem.Section) -> some View {
        let items = model.items(in: section)
        if !items.isEmpty || section == .hidden {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(section.title.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("\(items.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                if items.isEmpty {
                    Text("Nothing hidden yet. ⌘-drag icons left of the │ line to hide them.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                        ForEach(items) { item in
                            ItemTile(item: item, dimmed: section == .notShowing) { onOpenItem(item) }
                        }
                    }
                }
                if section == .notShowing {
                    Text("macOS isn't drawing these. They're turned off in System Settings → Menu Bar, or there's no room.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ItemTile: View {
    let item: MenuBarItem
    let dimmed: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                icon
                    .frame(width: 28, height: 28)
                Text(item.displayName)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
            .opacity(dimmed ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.label.map { "\(item.displayName): \($0)" } ?? item.displayName)
    }

    @ViewBuilder
    private var icon: some View {
        if let symbol = item.systemSymbol {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.08)))
        } else if let icon = item.appIcon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
        }
    }
}

private struct PermissionCard: View {
    @ObservedObject var permissions: Permissions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "hand.raised.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text("Let Perch see your menu bar")
                    .font(.headline)
            }
            Text("Perch needs Accessibility access to list your menu bar icons and open them for you. It uses it for nothing else.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Allow Access…") { permissions.requestAccessibility() }
                    .buttonStyle(.borderedProminent)
                Button("Open Settings") { permissions.openAccessibilitySettings() }
            }
        }
        .padding(.vertical, 6)
    }
}

/// The blurred, translucent background that menus use.
private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
