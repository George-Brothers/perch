import AppKit
import SwiftUI

/// The dropdown that hangs from the bird. It's built on first use, kept for
/// reuse, and listens for outside clicks only while it's open.
@MainActor
final class PanelController {
    private let model: LayoutEngine
    private let makeContent: () -> AnyView
    private var panel: PerchPanel?
    private weak var anchor: NSStatusBarButton?
    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?
    private var resizeObserver: NSObjectProtocol?

    init(model: LayoutEngine, makeContent: @escaping () -> AnyView) {
        self.model = model
        self.makeContent = makeContent
    }

    /// Runs each time the panel opens. Defaults to rescanning the icons.
    var onOpen: (() -> Void)?

    var isOpen: Bool { panel?.isVisible == true }

    func toggle(anchor: NSStatusBarButton?) {
        isOpen ? close() : open(anchor: anchor)
    }

    func open(anchor: NSStatusBarButton?) {
        self.anchor = anchor
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
        panel.makeKey()
        // After the panel is key, so a text field in it can take focus.
        if let onOpen { onOpen() } else { model.refresh() }
        MenuBarGeometry.ignoredWindowNumbers.insert(panel.windowNumber)
        installMonitors()
    }

    func close() {
        panel?.orderOut(nil)
        removeMonitors()
    }

    private func makePanel() -> PerchPanel {
        let panel = PerchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
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

        let hosting = NSHostingController(rootView: makeContent())
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hosting

        // The panel grows downward as items load, so keep its top edge pinned.
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
        let screen = anchor?.window?.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        let top = (anchorFrame?.minY ?? visible.maxY) - 6
        var x = (anchorFrame?.midX ?? visible.midX) - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        let origin = NSPoint(x: x.rounded(), y: (top - size.height).rounded())
        if panel.frame.origin != origin {
            panel.setFrameOrigin(origin)
        }
    }

    private func installMonitors() {
        removeMonitors()
        // Clicks in other apps (including other menu bar icons) close the panel.
        // Clicks on the bird itself come to Perch directly and toggle it instead.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Perch's own icon moves are clicks too; they shouldn't close the list.
                guard let self, !self.model.isArranging else { return }
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

/// A borderless panel that can still take key events (for Escape).
final class PerchPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// Perch never becomes the active app, so the panel may not be key when you
    /// click it. Make it key first so the very first click reaches the control.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !isKeyWindow {
            makeKey()
        }
        super.sendEvent(event)
    }
}
