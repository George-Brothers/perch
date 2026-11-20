import AppKit
import ApplicationServices

/// Lists every app's menu bar icons through the Accessibility API.
///
/// On macOS 26 every menu bar icon's window belongs to Control Center, so the
/// window list can't say which app owns which icon. Accessibility can: each
/// app exposes its icons as children of its "extras menu bar".
/// Runs only when asked (a pass, or Arrange or Perch's bar opening), never on a timer.
enum MenuBarScanner {
    private struct AppInfo {
        let pid: pid_t
        let bundleID: String?
        let name: String
    }

    /// Call on the main thread. The Accessibility work runs on background threads.
    static func scan() async -> [MenuBarItem] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier != ownPID }
            .map { AppInfo(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier, name: $0.localizedName ?? "App") }

        return await Task.detached(priority: .userInitiated) {
            let barWindows = statusBarWindowFrames()
            let lock = NSLock()
            var found: [MenuBarItem] = []
            DispatchQueue.concurrentPerform(iterations: apps.count) { index in
                let items = items(for: apps[index], barWindows: barWindows)
                guard !items.isEmpty else { return }
                lock.lock()
                found.append(contentsOf: items)
                lock.unlock()
            }
            return found.sorted { $0.frame.minX < $1.frame.minX }
        }.value
    }

    private static func items(for app: AppInfo, barWindows: [CGRect]) -> [MenuBarItem] {
        let appElement = AXUIElementCreateApplication(app.pid)
        // A hung app must not stall the scan.
        AXUIElementSetMessagingTimeout(appElement, 0.25)

        guard let extras = AX.element(appElement, "AXExtrasMenuBar") else { return [] }
        let children = AX.elements(extras, kAXChildrenAttribute)

        var result: [MenuBarItem] = []
        for (index, child) in children.enumerated() {
            // Later presses and frame checks go to the item itself; keep them short too.
            AXUIElementSetMessagingTimeout(child, 0.25)
            let identifier = AX.string(child, kAXIdentifierAttribute)

            guard let frame = AX.frame(of: child), frame.width > 0, frame.height > 0 else { continue }
            let label = AX.string(child, kAXDescriptionAttribute) ?? AX.string(child, kAXTitleAttribute)
            let mid = CGPoint(x: frame.midX, y: frame.midY)
            let inBar = barWindows.contains { $0.insetBy(dx: -2, dy: -2).contains(mid) }
            // Two items can share an identifier (two Live Activities from one app).
            var id = "\(app.bundleID ?? String(app.pid))#\(identifier ?? String(index))"
            if result.contains(where: { $0.id == id }) { id += "#\(index)" }

            result.append(MenuBarItem(
                id: id,
                element: child,
                pid: app.pid,
                bundleID: app.bundleID,
                appName: app.name,
                identifier: identifier,
                label: label,
                frame: frame,
                isInMenuBar: inBar
            ))
        }
        return result
    }

    /// Frames of every menu bar icon window, on screen or pushed off it.
    /// Bounds are readable without Screen Recording permission.
    private static func statusBarWindowFrames() -> [CGRect] {
        guard let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        return windows.compactMap { window in
            guard window[kCGWindowLayer as String] as? Int == statusLevel,
                  let dict = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict),
                  // Perch's collapsed divider spans thousands of points; an icon
                  // that's turned off could seem to be inside it.
                  rect.width < 2000
            else { return nil }
            return rect
        }
    }
}

/// Typed Accessibility reads. Core Foundation casts never fail at runtime,
/// so each helper checks the value's real type before handing it back.
enum AX {
    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = raw(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        guard let value = raw(element, name), CFGetTypeID(value) == CFArrayGetTypeID(),
              let array = value as? [AnyObject]
        else { return [] }
        return array.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? (item as! AXUIElement) : nil
        }
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        guard let value = raw(element, name), CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        let string = value as! String
        return string.isEmpty ? nil : string
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = axValue(element, kAXPositionAttribute),
              let size = axValue(element, kAXSizeAttribute)
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin),
              AXValueGetValue(size, .cgSize, &extent)
        else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private static func axValue(_ element: AXUIElement, _ name: String) -> AXValue? {
        guard let value = raw(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    static func raw(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
