import AppKit
import ApplicationServices

/// Opens another app's menu bar icon, as if you had clicked it.
enum ItemOpener {
    /// Presses the item through Accessibility, which doesn't touch the mouse.
    /// If the app ignores that, clicks the item and puts the pointer straight back.
    static func open(_ item: MenuBarItem) {
        if AXUIElementPerformAction(item.element, kAXPressAction as CFString) == .success {
            return
        }
        guard let frame = AX.frame(of: item.element), frame.minX >= 0 else { return }
        click(at: CGPoint(x: frame.midX, y: frame.midY))
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
