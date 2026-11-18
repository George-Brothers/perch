import AppKit
import SwiftUI

/// The drawer: hidden icons in a small bar that drops down from the bird.
/// Nothing in the menu bar moves; the icons are pictures you can click.
@MainActor
final class DrawerController {
    private let engine: LayoutEngine
    private let images: IconImages
    private let preferences: Preferences
    private var panel: PerchPanel?
    private weak var anchor: NSStatusBarButton?
    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?
    private var resizeObserver: NSObjectProtocol?

    /// Opens the icon's own menu. Set by the app.
    var onOpenItem: ((MenuBarItem) -> Void)?
    var onOpenArrange: (() -> Void)?

    init(engine: LayoutEngine, images: IconImages, preferences: Preferences) {
        self.engine = engine
        self.images = images
        self.preferences = preferences
    }

    var isOpen: Bool { panel?.isVisible == true }

    func toggle(anchor: NSStatusBarButton?) {
        isOpen ? close() : open(anchor: anchor)
    }

    func open(anchor: NSStatusBarButton?) {
        self.anchor = anchor
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        installMonitors()

        // Show what we have now, then refresh the list and the pictures.
        Task {
            let items = await engine.rescan()
            await images.capture(items.filter { $0.section == .hidden })
        }
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        removeMonitors()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
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
            onOpen: { [weak self] item in
                self?.close()
                self?.onOpenItem?(item)
            },
            onArrange: { [weak self] in
                self?.close()
                self?.onOpenArrange?()
            }
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
        let anchorFrame = anchor?.window?.frame
        guard let screen = anchor?.window?.screen ?? NSScreen.main else { return }
        let barBottom = screen.frame.maxY - MenuBarGeometry.menuBarHeight(for: screen)
        let visible = screen.frame
        var x = (anchorFrame?.maxX ?? visible.maxX - 8) - size.width + 8
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
                guard let self, !self.engine.isArranging else { return }
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
    let onOpen: (MenuBarItem) -> Void
    let onArrange: () -> Void

    private var hidden: [MenuBarItem] {
        engine.items.filter { $0.section == .hidden }.sorted { $0.frame.minX < $1.frame.minX }
    }

    var body: some View {
        HStack(spacing: 0) {
            if hidden.isEmpty {
                Text(engine.hasScanned ? "No hidden icons" : " ")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
            } else {
                ForEach(hidden) { item in
                    DrawerIcon(item: item, image: images.image(for: item), onOpen: onOpen)
                        .contextMenu { priorityMenu(for: item) }
                }
            }
        }
        .frame(minHeight: 24)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(.regularMaterial, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .environment(\.colorScheme, images.iconsAreLight ? .dark : .light)
        .fixedSize()
        .padding(1)
    }

    @ViewBuilder
    private func priorityMenu(for item: MenuBarItem) -> some View {
        Text(item.displayName)
        Divider()
        Button("Keep in Menu Bar") { engine.setPriority(.always, for: item) }
        Button("Show When There's Room") { engine.setPriority(.auto, for: item) }
        Divider()
        Button("Arrange Icons…", action: onArrange)
    }
}

private struct DrawerIcon: View {
    let item: MenuBarItem
    let image: NSImage?
    let onOpen: (MenuBarItem) -> Void
    @State private var hovering = false

    var body: some View {
        Button { onOpen(item) } label: {
            Group {
                if let image {
                    Image(nsImage: image)
                        .interpolation(.high)
                } else {
                    ItemIcon(item: item)
                        .frame(width: 18, height: 18)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.12 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.displayName)
    }
}
