import AppKit
import SwiftUI

/// Perch's bar: every icon that's hidden or doesn't fit, in a small bar under
/// the menu bar. Nothing in the menu bar moves. Clicking an icon opens its
/// menu right there (see `MenuMirror`).
@MainActor
final class DrawerController {
    private let engine: LayoutEngine
    private let images: IconImages
    private let preferences: Preferences
    private var panel: PerchPanel?
    private var anchor: PanelAnchor?
    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?
    private var resizeObserver: NSObjectProtocol?
    /// Bumped on every open, so a fade-out that finishes late doesn't hide a reopened drawer.
    private var generation = 0

    /// Opens the icon's own menu with its top-left corner at the point, and
    /// returns once it's done: true if Perch's bar should close too (you picked
    /// something), false to leave it open. Set by the app.
    var onOpenItem: ((MenuBarItem, NSPoint) async -> Bool)?
    /// Which icon's menu is open, so it stays highlighted like in the menu bar.
    private let state = DrawerState()
    var onOpenArrange: (() -> Void)?

    init(engine: LayoutEngine, images: IconImages, preferences: Preferences) {
        self.engine = engine
        self.images = images
        self.preferences = preferences
    }

    /// False as soon as closing starts, so a click during the fade reopens it.
    private(set) var isOpen = false

    func toggle(anchor: PanelAnchor?) {
        isOpen ? close() : open(anchor: anchor)
    }

    func open(anchor: PanelAnchor?) {
        self.anchor = anchor
        let panel = self.panel ?? makePanel()
        self.panel = panel
        generation += 1
        isOpen = true
        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey() // for Escape
        MenuBarGeometry.ignoredWindowNumbers.insert(panel.windowNumber)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        installMonitors()

        // Hidden icons are off screen, so the pictures come from the last time
        // they were showing. Just refresh which icons are hidden.
        engine.refresh()
    }

    func close() {
        guard isOpen, let panel else { return }
        isOpen = false
        removeMonitors()
        let closing = generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard self?.generation == closing else { return }
                panel.orderOut(nil)
            }
        }
    }

    private func makePanel() -> PerchPanel {
        let panel = PerchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let view = DrawerView(
            engine: engine,
            images: images,
            preferences: preferences,
            state: state,
            onOpen: { [weak self] item, iconMinX in
                guard let self, let panel = self.panel, self.state.activeKey == nil else { return }
                // The menu drops from the clicked icon, just under Perch's bar,
                // which stays open like the menu bar does.
                let point = NSPoint(x: panel.frame.minX + iconMinX, y: panel.frame.minY - 2)
                self.state.activeKey = item.key
                Task {
                    let shouldClose = await self.onOpenItem?(item, point) ?? true
                    self.state.activeKey = nil
                    if shouldClose { self.close() }
                }
            },
            onArrange: { [weak self] in
                self?.close()
                self?.onOpenArrange?()
            },
            onClose: { [weak self] in self?.close() }
        )
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hosting

        // Keep the right edge under the bird as the drawer grows or shrinks.
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main
        ) { [weak self, weak panel] _ in
            MainActor.assumeIsolated {
                guard let self, let panel else { return }
                self.position(panel)
            }
        }
        return panel
    }

    private func position(_ panel: NSPanel) {
        let size = panel.frame.size
        let anchorFrame = anchor?()
        guard let screen = anchorFrame.flatMap(PanelAnchorScreen.of) ?? NSScreen.main else { return }
        let barBottom = screen.frame.maxY - MenuBarGeometry.menuBarHeight(for: screen)
        let visible = screen.frame
        var x = (anchorFrame?.maxX ?? visible.maxX - 8) - size.width + 1
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let origin = NSPoint(x: x.rounded(), y: (barBottom - 5 - size.height).rounded())
        if panel.frame.origin != origin {
            panel.setFrameOrigin(origin)
        }
    }

    private func installMonitors() {
        removeMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Empty menu bar space toggles the panel itself (see MenuBarController).
                guard let self, !MenuBarGeometry.isEmptyMenuBarSpace(NSEvent.mouseLocation), !self.engine.isArranging else { return }
                self.close()
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event } // Escape
            MainActor.assumeIsolated { self?.close() }
            return nil
        }
    }

    private func removeMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        outsideClickMonitor = nil
        keyMonitor = nil
    }
}

/// The drawer's content: the hidden icons in menu bar order.
struct DrawerView: View {
    @ObservedObject var engine: LayoutEngine
    @ObservedObject var images: IconImages
    @ObservedObject var preferences: Preferences
    @ObservedObject var state: DrawerState
    /// The icon, and its left edge within the bar.
    let onOpen: (MenuBarItem, CGFloat) -> Void
    let onArrange: () -> Void
    let onClose: () -> Void

    private var hidden: [MenuBarItem] {
        engine.inHiddenOrder(engine.items.filter { $0.section == .hidden })
    }

    var body: some View {
        HStack(spacing: 0) {
            if hidden.isEmpty {
                Text(engine.hasScanned ? "No hidden icons" : " ")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
            } else {
                ForEach(hidden) { item in
                    DrawerIcon(item: item, image: images.image(for: item),
                               isActive: state.activeKey == item.key, onOpen: onOpen)
                        .contextMenu { priorityMenu(for: item) }
                }
            }
        }
        .frame(minHeight: 24)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(.regularMaterial, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .modifier(MatchIconColors(images: images, active: hidden.contains { images.image(for: $0) != nil }))
        .fixedSize()
        .padding(1)
    }

    @ViewBuilder
    private func priorityMenu(for item: MenuBarItem) -> some View {
        Text(item.displayName)
        Divider()
        Button("Show in Menu Bar") {
            onClose()
            engine.place(item, .before(.divider, shown: true))
        }
        Divider()
        Button("Arrange Icons…", action: onArrange)
    }
}

/// Pictures of icons are drawn for the menu bar behind them, so give the drawer
/// the same light or dark look. With no pictures yet, follow the system.
struct MatchIconColors: ViewModifier {
    @ObservedObject var images: IconImages
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.environment(\.colorScheme, images.iconsAreLight ? .dark : .light)
        } else {
            content
        }
    }
}

/// What Perch's bar is showing right now.
@MainActor
final class DrawerState: ObservableObject {
    @Published var activeKey: String?
}

private struct DrawerIcon: View {
    let item: MenuBarItem
    let image: NSImage?
    let isActive: Bool
    let onOpen: (MenuBarItem, CGFloat) -> Void
    @State private var hovering = false
    @State private var minX: CGFloat = 0

    var body: some View {
        Button { onOpen(item, minX) } label: {
            Group {
                if let image {
                    // Notched displays have a taller bar; keep the drawer slim anyway.
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(height: min(image.size.height, 24))
                        .frame(minWidth: 26)
                } else {
                    ItemIcon(item: item)
                        .frame(width: 18, height: 18)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isActive ? 0.18 : (hovering ? 0.12 : 0)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .background(GeometryReader { geometry in
            Color.clear
                .onAppear { minX = geometry.frame(in: .global).minX }
                .onChange(of: geometry.frame(in: .global).minX) { _, x in minX = x }
        })
        .help(item.displayName)
        .accessibilityLabel(item.displayName)
    }
}
