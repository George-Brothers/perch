import AppKit

/// Cheap, on-demand questions about the menu bar. Nothing here runs on a timer.
enum MenuBarGeometry {
    /// Whether an icon's frame (top-down from the main screen, as Accessibility
    /// gives it) is in this screen's menu bar, including one auto-hidden above
    /// it. Checks both directions, so a display stacked above or below doesn't count.
    static func isInMenuBar(_ frame: CGRect, of screen: NSScreen) -> Bool {
        let top = (NSScreen.screens.first?.frame.height ?? 0) - screen.frame.maxY
        return screen.frame.minX <= frame.minX && frame.minX < screen.frame.maxX
            && frame.minY > top - 60 && frame.minY < top + menuBarHeight(for: screen) + 4
    }

    static func menuBarHeight(for screen: NSScreen) -> CGFloat {
        max(
            NSStatusBar.system.thickness,
            screen.frame.maxY - screen.visibleFrame.maxY,
            screen.safeAreaInsets.top
        )
    }

    /// Whether a point in screen coordinates is inside some display's menu bar.
    static func isInMenuBar(_ point: NSPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else {
            return false
        }
        return point.y >= screen.frame.maxY - menuBarHeight(for: screen)
    }

    /// Whether a point (screen coordinates, bottom-left origin) is empty menu
    /// bar space: in the bar, but not on an app menu or any icon. Asks
    /// Accessibility what's under the point; without it, the answer is no.
    /// Only the bar of the app that owns the menu bar counts, so the small gaps between icons don't.
    @MainActor static func isEmptyMenuBarSpace(_ point: NSPoint) -> Bool {
        guard isInMenuBar(point), AXIsProcessTrusted(),
              // Not the front app: while Perch's own window is in front, the
              // menu bar still belongs to the app before it.
              let front = (NSWorkspace.shared.menuBarOwningApplication
                  ?? NSWorkspace.shared.frontmostApplication)?.processIdentifier else { return false }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var element: AXUIElement?
        // Runs on every click; a busy app must not hold it up.
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.1)
        let error = AXUIElementCopyElementAtPosition(
            systemWide, Float(point.x), Float(primaryHeight - point.y), &element
        )
        guard error == .success, let element else { return false }
        var role: CFTypeRef?
        var pid: pid_t = 0
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        AXUIElementGetPid(element, &pid)
        return role as? String == kAXMenuBarRole as String && pid == front
    }

    /// Owners whose always-present windows hang from the top of the screen
    /// but are not menus.
    private static let ignoredOwners: Set<String> = ["Window Server", "Dock", "Notification Center"]

    /// Perch's own panels (drawer, Arrange) sit at menu level but aren't menus.
    @MainActor static var ignoredWindowNumbers: Set<Int> = []

    /// Whether an icon's frame starts on `screen` (any display when nil),
    /// including displays left of the main one, whose x is negative.
    /// Hidden icons are pushed off the left edge of their bar's display.
    static func isOnScreen(_ frame: CGRect, screen: NSScreen? = nil) -> Bool {
        let screens = screen.map { [$0] } ?? NSScreen.screens
        return screens.contains { $0.frame.minX <= frame.minX && frame.minX < $0.frame.maxX }
    }

    /// Whether any app has a menu or menu bar panel open right now.
    /// Reads window levels and sizes only, so it needs no Screen Recording permission.
    ///
    /// Three shapes count as an open menu:
    /// - a regular menu (pop-up menu level),
    /// - a Control Center panel such as Wi-Fi or Bluetooth (macOS 26 shows these
    ///   one level below the menu bar, starting at the top of the screen),
    /// - a popover hanging from a menu bar icon.
    /// Overlay windows above level 1000 (dictation pills and the like) are ignored.
    @MainActor static func isMenuOpen() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        // Window bounds use a top-left origin on the primary display; find each
        // display's top edge and bar height in those terms (displays can be stacked).
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let bars = NSScreen.screens.map { screen in
            (frame: CGRect(x: screen.frame.minX, y: primaryTop - screen.frame.maxY,
                           width: screen.frame.width, height: screen.frame.height),
             height: menuBarHeight(for: screen))
        }
        for window in windows {
            // Perch's own panels sit at menu level but aren't menus.
            if let number = window[kCGWindowNumber as String] as? Int, ignoredWindowNumbers.contains(number) { continue }
            guard let layer = window[kCGWindowLayer as String] as? Int else { continue }
            if layer == menuLevel { return true }
            guard layer > 0, layer < 1000,
                  let owner = window[kCGWindowOwnerName as String] as? String,
                  !ignoredOwners.contains(owner),
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { continue }
            // Menu bar icons themselves are exactly bar-height. Anything taller
            // that starts at or just under the menu bar is a panel hanging from it.
            let top = CGPoint(x: bounds.midX, y: bounds.minY)
            guard let bar = bars.first(where: { $0.frame.contains(top) }) else { continue }
            if bounds.minY <= bar.frame.minY + bar.height + 4, bounds.height > bar.height + 4 {
                return true
            }
        }
        return false
    }
}
