import AppKit

/// Cheap, on-demand questions about the menu bar. Nothing here runs on a timer.
enum MenuBarGeometry {
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

    /// Owners whose always-present windows hang from the top of the screen
    /// but are not menus.
    private static let ignoredOwners: Set<String> = ["Window Server", "Dock", "Notification Center"]

    /// Whether any app has a menu or menu bar panel open right now.
    /// Reads window levels and sizes only, so it needs no Screen Recording permission.
    ///
    /// Three shapes count as an open menu:
    /// - a regular menu (pop-up menu level),
    /// - a Control Center panel such as Wi-Fi or Bluetooth (macOS 26 shows these
    ///   one level below the menu bar, starting at the top of the screen),
    /// - a popover hanging from a menu bar icon.
    /// Overlay windows above level 1000 (dictation pills and the like) are ignored.
    static func isMenuOpen() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let barHeight = NSScreen.main.map(menuBarHeight(for:)) ?? 24
        let ownPID = Int(ProcessInfo.processInfo.processIdentifier)

        for window in windows {
            // Perch's own Arrange panel sits at menu level but isn't a menu.
            if window[kCGWindowOwnerPID as String] as? Int == ownPID { continue }
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
            if bounds.minY <= barHeight + 4, bounds.height > barHeight + 4 {
                return true
            }
        }
        return false
    }
}
