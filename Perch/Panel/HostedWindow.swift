import AppKit
import SwiftUI

/// A plain window for a SwiftUI page (the Guide, setup). It starts over from
/// the first page each time it reopens.
@MainActor
final class HostedWindow {
    private let title: String
    private let size: CGSize
    private let makeContent: (@escaping () -> Void) -> AnyView
    private var window: NSWindow?
    /// Runs when the window closes, however it was closed.
    var onClose: (() -> Void)?
    private var closeObserver: NSObjectProtocol?

    init(title: String, size: CGSize, makeContent: @escaping (_ close: @escaping () -> Void) -> AnyView) {
        self.title = title
        self.size = size
        self.makeContent = makeContent
    }

    var isOpen: Bool { window?.isVisible == true }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: makeContent { [weak self] in self?.window?.close() })
            let window = NSWindow(contentViewController: hosting)
            window.title = title
            window.styleMask = [.titled, .closable]
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.setContentSize(size)
            window.center()
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onClose?() }
            }
            self.window = window
        } else if let window, !window.isVisible {
            window.contentViewController = NSHostingController(
                rootView: makeContent { [weak self] in self?.window?.close() }
            )
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func close() {
        window?.close()
    }
}
