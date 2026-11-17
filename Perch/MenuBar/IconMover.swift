import AppKit

/// Moves menu bar icons the way you would by hand: a ⌘-drag. macOS has no API
/// for this, so Perch posts the mouse events itself, hides the pointer while it
/// works, and puts it back where it was. Needs Accessibility permission.
///
/// Call off the main thread: each move takes a few hundred milliseconds.
enum IconMover {
    /// Drags the icon at `from` and drops it at `to` (screen coordinates, top-left origin).
    static func drag(from start: CGPoint, to end: CGPoint) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let original = CGEvent(source: nil)?.location

        func post(_ type: CGEventType, _ point: CGPoint) {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                      mouseCursorPosition: point, mouseButton: .left) else { return }
            event.flags = .maskCommand
            event.post(tap: .cgSessionEventTap)
        }

        // Detach the physical mouse so moving it can't bend the drag.
        CGAssociateMouseAndMouseCursorPosition(0)
        CGDisplayHideCursor(CGMainDisplayID())
        defer {
            if let original { CGWarpMouseCursorPosition(original) }
            CGDisplayShowCursor(CGMainDisplayID())
            CGAssociateMouseAndMouseCursorPosition(1)
        }

        post(.leftMouseDown, start)
        usleep(50_000)
        let steps = 10
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            post(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y))
            usleep(15_000)
        }
        usleep(50_000)
        post(.leftMouseUp, end)
        usleep(120_000)
    }
}
