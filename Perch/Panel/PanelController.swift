import AppKit
import SwiftUI

/// What a panel hangs from: a frame in screen coordinates (bottom-left origin),
/// read again each time the panel repositions, since items move.
typealias PanelAnchor = @MainActor () -> NSRect?

enum PanelAnchorScreen {
    /// The display an anchor sits on.
    static func of(_ frame: NSRect) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(NSPoint(x: frame.midX, y: frame.midY), $0.frame, false) }
    }
}

/// The dropdown that hangs from the bird. It's built on first use, kept for
/// reuse, and listens for outside clicks only while it's open.
@MainActor
final class PanelController {
    private let model: LayoutEngine
    private let makeContent: () -> AnyView
    private var panel: PerchPanel?
    private var anchor: PanelAnchor?
    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?
    private var resizeObserver: NSObjectProtocol?
    /// Once you start using the panel it holds still: as it resizes, its top
    /// and right edges stay put (the rows are right-aligned, like the bar), so
    /// nothing shifts under the pointer. Until then it follows the anchor while
    /// its content loads.
    private var pinned: (right: CGFloat, top: CGFloat)?
    private var pinLater: DispatchWorkItem?

    init(model: LayoutEngine, makeContent: @escaping () -> AnyView) {
        self.model = model
        self.makeContent = makeContent
    }

    /// Where the panel's top-left corner goes, instead of hanging from the
    /// anchor (Arrange over the menu bar covers the bar from the left edge).
    var topLeft: (() -> NSPoint?)?

    /// Runs each time the panel opens. Defaults to rescanning the icons.
    var onOpen: (() -> Void)?

    var isOpen: Bool { panel?.isVisible == true }

    func toggle(anchor: PanelAnchor?) {
        isOpen ? close() : open(anchor: anchor)
    }

    func open(anchor: PanelAnchor?) {
        self.anchor = anchor
        let panel = self.panel ?? makePanel()
        self.panel = panel
        pinned = nil
        position(panel)
        pinLater?.cancel()
        let pin = DispatchWorkItem { [weak self] in self?.pin() }
        pinLater = pin
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: pin)
        panel.orderFrontRegardless()
        panel.makeKey()
        // After the panel is key, so a text field in it can take focus.
        if let onOpen { onOpen() } else { model.refresh() }
        MenuBarGeometry.ignoredWindowNumbers.insert(panel.windowNumber)
        installMonitors()
    }

    /// Runs when the panel closes, however it was closed.
    var onClose: (() -> Void)?

    func close() {
        let wasOpen = isOpen
        pinLater?.cancel()
        pinned = nil
        panel?.orderOut(nil)
        removeMonitors()
        if wasOpen { onClose?() }
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
        panel.onMouseDown = { [weak self] in self?.pin() }

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

    private func pin() {
        guard isOpen, pinned == nil, let frame = panel?.frame else { return }
        pinned = (frame.maxX, frame.maxY)
    }

    private func position(_ panel: NSPanel) {
        let size = panel.frame.size
        if let corner = topLeft?() {
            let origin = NSPoint(x: corner.x.rounded(), y: (corner.y - size.height).rounded())
            if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
            return
        }
        if let pinned, let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            let x = min(max(pinned.right - size.width, visible.minX + 8), visible.maxX - size.width - 8)
            let origin = NSPoint(x: x.rounded(), y: (pinned.top - size.height).rounded())
            if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
            return
        }
        // While Control Center restarts, Perch's items can briefly report a
        // frame away from the menu bar; hang from the top of the screen then.
        let anchorFrame = anchor?().flatMap { MenuBarGeometry.isInMenuBar(NSPoint(x: $0.midX, y: $0.midY)) ? $0 : nil }
        let screen = anchorFrame.flatMap(PanelAnchorScreen.of) ?? NSScreen.main
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
                // Not while icons are moving. Empty menu bar space toggles the panel itself (see MenuBarController).
                guard let self, !MenuBarGeometry.isEmptyMenuBarSpace(NSEvent.mouseLocation), !self.model.isArranging else { return }
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

    /// Any click in the panel, before it's handled.
    var onMouseDown: (() -> Void)?

    /// Perch never becomes the active app, so the panel may not be key when you
    /// click it. Make it key first so the very first click reaches the control.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            onMouseDown?()
        }
        if event.type == .leftMouseDown, !isKeyWindow {
            makeKey()
        }
        super.sendEvent(event)
    }
}
