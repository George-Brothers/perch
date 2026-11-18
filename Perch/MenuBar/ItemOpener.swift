import AppKit
import ApplicationServices

/// Opens another app's menu bar icon, as if you had clicked it.
enum ItemOpener {
    /// Presses the item through Accessibility, which doesn't touch the mouse.
    /// If the app ignores that, clicks the item and puts the pointer straight back.
    /// `stillWanted` is checked again before the fallback click, in case
    /// something else happened in the meantime.
    @MainActor
    static func open(_ item: MenuBarItem, if stillWanted: @escaping () -> Bool = { true }) {
        if AXUIElementPerformAction(item.element, kAXPressAction as CFString) == .success {
            return
        }
        // Many apps (Shottr, Wispr Flow) open their menu but are too busy
        // showing it to answer in time, so the press reports an error even
        // though it worked. Clicking then would close the menu again, so only
        // click if no menu came up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard stillWanted(), !MenuBarGeometry.isMenuOpen(),
                  let frame = AX.frame(of: item.element), MenuBarGeometry.isOnScreen(frame)
            else { return }
            click(at: CGPoint(x: frame.midX, y: frame.midY))
        }
    }

    private static func click(at point: CGPoint) {
        let original = CGEvent(source: nil)?.location
        let source = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        if let original {
            CGWarpMouseCursorPosition(original)
        }
    }
}
