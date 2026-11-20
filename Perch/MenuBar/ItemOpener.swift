import AppKit
import ApplicationServices

/// Opens another app's menu bar icon, as if you had clicked it.
enum ItemOpener {
    /// Presses the item through Accessibility. Never touches the mouse.
    /// Some apps (Shottr, Wispr Flow) open their menu but report an error
    /// because they're busy showing it; that's fine.
    @MainActor
    static func open(_ item: MenuBarItem, if stillWanted: @escaping () -> Bool = { true }) {
        guard stillWanted() else { return }
        _ = AXUIElementPerformAction(item.element, kAXPressAction as CFString)
    }
}
