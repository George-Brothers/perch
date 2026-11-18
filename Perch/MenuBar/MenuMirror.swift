import AppKit
import ApplicationServices
import os

/// Opens a hidden icon right under Perch's bar, without the icon coming into
/// the menu bar and without touching the mouse.
///
/// A hidden icon sits off the left edge of the screen, so when Perch presses
/// it through Accessibility, whatever it opens appears off screen too:
/// - a menu: Perch reads it, closes it, and shows the same items as its own
///   menu. Picking one opens the real menu off screen again and presses that item.
/// - a panel (Stats, say): Perch moves the panel under its bar.
@MainActor
enum MenuMirror {
    private nonisolated static let log = Logger(subsystem: "com.georgebrothers.perch", category: "open")

    /// One item of a copied menu.
    struct Entry {
        let title: String
        let enabled: Bool
        let checked: Bool
        let key: String
        let modifiers: NSEvent.ModifierFlags
        let isSeparator: Bool
        let children: [Entry]
        /// Indexes from the top menu down to this item.
        let path: [Int]
        /// Titles along the same path, to check the real menu still matches.
        let titles: [String]
    }

    /// What a copied item needs to press the real one.
    private final class Pick: NSObject {
        let path: [Int]
        let titles: [String]
        init(path: [Int], titles: [String]) {
            self.path = path
            self.titles = titles
        }
    }

    private enum Result {
        case menu([Entry])
        case panel
        case nothing
    }

    enum Outcome {
        /// Its menu was shown and you picked an item.
        case picked
        /// Its menu was shown and you closed it without picking.
        case dismissed
        /// It opened a panel, which is now under Perch's bar.
        case panel
        /// It showed nothing Perch could bring over.
        case failed
    }

    /// Opens a hidden icon with its menu's top-left corner at `point` (screen
    /// coordinates, bottom-left origin). Returns once its menu has closed.
    static func open(_ item: MenuBarItem, at point: NSPoint) async -> Outcome {
        let element = item.element
        let pid = item.pid
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let screens = NSScreen.screens.map { screen in
            // Top-left origin, like Accessibility.
            CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY,
                   width: screen.frame.width, height: screen.frame.height)
        }
        let target = CGPoint(x: point.x, y: primaryHeight - point.y)
        let result = await Task.detached(priority: .userInitiated) {
            openOffScreen(element, pid: pid, panelOrigin: target, screens: screens)
        }.value
        switch result {
        case .menu(let entries):
            return show(entries, for: item, at: point) ? .picked : .dismissed
        case .panel:
            return .panel
        case .nothing:
            log.notice("\(item.displayName, privacy: .public) opened nothing Perch could show")
            return .failed
        }
    }

    // MARK: - Reading

    private nonisolated static func openOffScreen(_ element: AXUIElement, pid: pid_t, panelOrigin: CGPoint,
                                                  screens: [CGRect]) -> Result {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        AXUIElementSetMessagingTimeout(element, 0.3)
        let windowsBefore = Set(AX.elements(app, kAXWindowsAttribute).map(CFHash))
        // Apps busy opening their menu often answer the press late; that's fine.
        _ = AXUIElementPerformAction(element, kAXPressAction as CFString)

        for _ in 0..<30 {
            if let menu = AX.elements(element, kAXChildrenAttribute).first(where: { AX.string($0, kAXRoleAttribute) == "AXMenu" }) {
                let entries = read(menu, path: [], titles: [])
                _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
                return .menu(entries)
            }
            // A panel that just opened off screen: bring it under Perch's bar.
            for window in AX.elements(app, kAXWindowsAttribute) where !windowsBefore.contains(CFHash(window)) {
                guard let frame = AX.frame(of: window), !screens.contains(where: { $0.intersects(frame) }) else { continue }
                let screen = screens.min { abs($0.minX - panelOrigin.x) < abs($1.minX - panelOrigin.x) } ?? .zero
                var origin = CGPoint(x: min(panelOrigin.x, screen.maxX - frame.width - 8), y: panelOrigin.y)
                origin.x = max(origin.x, screen.minX + 8)
                if let value = AXValueCreate(.cgPoint, &origin),
                   AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success {
                    return .panel
                }
            }
            usleep(25_000)
        }
        return .nothing
    }

    private nonisolated static func read(_ menu: AXUIElement, path: [Int], titles: [String]) -> [Entry] {
        AX.elements(menu, kAXChildrenAttribute).enumerated().map { index, element in
            let title = AX.string(element, kAXTitleAttribute) ?? ""
            let enabled = AX.raw(element, kAXEnabledAttribute) as? Bool ?? true
            let submenu = AX.elements(element, kAXChildrenAttribute).first { AX.string($0, kAXRoleAttribute) == "AXMenu" }
            let rawModifiers = AX.raw(element, "AXMenuItemCmdModifiers") as? Int ?? 0
            var modifiers: NSEvent.ModifierFlags = rawModifiers & 8 == 0 ? [.command] : []
            if rawModifiers & 1 != 0 { modifiers.insert(.shift) }
            if rawModifiers & 2 != 0 { modifiers.insert(.option) }
            if rawModifiers & 4 != 0 { modifiers.insert(.control) }
            return Entry(
                title: title,
                enabled: enabled,
                checked: !(AX.string(element, "AXMenuItemMarkChar") ?? "").isEmpty,
                key: AX.string(element, "AXMenuItemCmdChar") ?? "",
                modifiers: modifiers,
                isSeparator: title.isEmpty && !enabled && submenu == nil,
                children: submenu.map { read($0, path: path + [index], titles: titles + [title]) } ?? [],
                path: path + [index],
                titles: titles + [title]
            )
        }
    }

    // MARK: - Showing

    /// Keeps the handler alive while its menu is up (menu items hold targets weakly).
    private static var handler: Handler?

    /// Shows the copied menu until it closes. True if you picked an item.
    private static func show(_ entries: [Entry], for item: MenuBarItem, at point: NSPoint) -> Bool {
        let handler = Handler(item: item)
        self.handler = handler
        let menu = NSMenu()
        add(entries, to: menu, handler: handler)
        menu.popUp(positioning: nil, at: point, in: nil)
        return handler.picked
    }

    private static func add(_ entries: [Entry], to menu: NSMenu, handler: Handler) {
        menu.autoenablesItems = false
        for entry in entries {
            if entry.isSeparator {
                menu.addItem(.separator())
                continue
            }
            let menuItem = NSMenuItem(title: entry.title, action: nil, keyEquivalent: entry.key.lowercased())
            menuItem.keyEquivalentModifierMask = entry.modifiers
            menuItem.isEnabled = entry.enabled
            menuItem.state = entry.checked ? .on : .off
            if entry.children.isEmpty {
                menuItem.target = handler
                menuItem.action = #selector(Handler.pick(_:))
                menuItem.representedObject = Pick(path: entry.path, titles: entry.titles)
            } else {
                let submenu = NSMenu(title: entry.title)
                add(entry.children, to: submenu, handler: handler)
                menuItem.submenu = submenu
            }
            menu.addItem(menuItem)
        }
    }

    private final class Handler: NSObject {
        let item: MenuBarItem
        private(set) var picked = false

        init(item: MenuBarItem) {
            self.item = item
        }

        @objc func pick(_ sender: NSMenuItem) {
            guard let pick = sender.representedObject as? Pick else { return }
            picked = true
            let element = item.element
            let path = pick.path, titles = pick.titles
            Task.detached(priority: .userInitiated) {
                MenuMirror.press(path: path, titles: titles, in: element)
            }
        }
    }

    /// Opens the real menu off screen again and presses the item at `path`.
    private nonisolated static func press(path: [Int], titles: [String], in element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, 0.3)
        _ = AXUIElementPerformAction(element, kAXPressAction as CFString)
        var menu: AXUIElement?
        for _ in 0..<30 {
            menu = AX.elements(element, kAXChildrenAttribute).first { AX.string($0, kAXRoleAttribute) == "AXMenu" }
            if menu != nil { break }
            usleep(25_000)
        }
        guard let top = menu else { return }
        var current = top
        for (depth, index) in path.enumerated() {
            let items = AX.elements(current, kAXChildrenAttribute)
            let isLast = depth == path.count - 1
            // The menu may have changed since it was copied (an app can
            // reorder its submenus). Every step must still have the title it
            // had; if it moved, take the one item with that title, never a guess.
            let title = depth < titles.count ? titles[depth] : ""
            var found = index < items.count ? items[index] : nil
            if let candidate = found, (AX.string(candidate, kAXTitleAttribute) ?? "") != title {
                found = nil
            }
            if found == nil, !title.isEmpty {
                let matches = items.filter { AX.string($0, kAXTitleAttribute) == title }
                found = matches.count == 1 ? matches[0] : nil
            }
            guard let next = found else { break }
            if isLast {
                AXUIElementSetMessagingTimeout(next, 0.5)
                let result = AXUIElementPerformAction(next, kAXPressAction as CFString)
                log.notice("picked a menu item (\(result.rawValue, privacy: .public))")
                return
            }
            guard let submenu = AX.elements(next, kAXChildrenAttribute).first(where: { AX.string($0, kAXRoleAttribute) == "AXMenu" })
            else { break }
            current = submenu
        }
        // Couldn't find it: close the menu rather than leave it open off screen.
        log.notice("couldn't find the picked menu item; closing the menu")
        _ = AXUIElementPerformAction(top, kAXCancelAction as CFString)
    }
}
