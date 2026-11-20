import AppKit
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case icons
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .icons: "Icons"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .icons: "menubar.rectangle"
        case .about: "info.circle"
        }
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var pane: SettingsPane? = .general
}

/// Builds the Settings window on first use and reuses it after that.
@MainActor
final class SettingsWindowController {
    private let navigation = SettingsNavigation()
    private let makeContent: (SettingsNavigation) -> AnyView
    private var window: NSWindow?

    init(makeContent: @escaping (SettingsNavigation) -> AnyView) {
        self.makeContent = makeContent
    }

    func show(pane: SettingsPane?) {
        if let pane { navigation.pane = pane }

        if window == nil {
            let hosting = NSHostingController(rootView: makeContent(navigation))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Perch Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 680, height: 500))
            window.contentMinSize = NSSize(width: 600, height: 420)
            window.center()
            window.setFrameAutosaveName("PerchSettings")
            self.window = window
        }

        // Perch has no Dock icon, so macOS won't always bring it forward on its own.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}
