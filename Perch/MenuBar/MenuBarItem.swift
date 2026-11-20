import AppKit
import ApplicationServices

/// One icon in the menu bar, owned by some app.
struct MenuBarItem: Identifiable {
    enum Section: Int, CaseIterable {
        case hidden
        case shown
        /// macOS isn't drawing it: the app's icon is turned off in
        /// System Settings → Menu Bar.
        case notShowing
    }

    let id: String
    let element: AXUIElement
    let pid: pid_t
    let bundleID: String?
    let appName: String
    /// Accessibility identifier, set by Apple's own items (for example "com.apple.menuextra.wifi").
    let identifier: String?
    /// Accessibility description, often empty for third-party items.
    let label: String?
    /// Position and size in screen coordinates (top-left origin).
    let frame: CGRect
    /// Whether macOS actually has a window for this item in the menu bar.
    let isInMenuBar: Bool
    var section: Section = .shown

    /// Stable name for saving this icon's priority across launches.
    var key: String { id }

    /// A Live Activity (an app's temporary status, like a download or a timer).
    /// macOS places these itself and they come and go.
    var isLiveActivity: Bool { identifier?.hasSuffix(".liveActivity") == true }

    /// The clock and Control Center, which macOS keeps at the right end.
    var isFixed: Bool {
        identifier == "com.apple.menuextra.clock" || identifier == "com.apple.menuextra.controlcenter"
    }

    /// Whether Perch can move this icon. The mic/camera indicator, Live
    /// Activities, the clock and Control Center are placed by macOS and won't move.
    var isMovable: Bool {
        !isFixed && !isLiveActivity && identifier != "com.apple.menuextra.audiovideo"
    }

    var displayName: String {
        if let identifier, let name = Self.systemNames[identifier] { return name }
        if bundleID == "com.apple.controlcenter" || bundleID == "com.apple.systemuiserver",
           let label, !label.isEmpty {
            return String(label.split(separator: ",").first ?? Substring(label))
        }
        return Self.prettyAppNames[appName] ?? appName
    }

    private static let prettyAppNames = ["GeminiAppLauncher": "Gemini"]

    /// SF Symbol for Apple's own items, which have no app icon of their own.
    var systemSymbol: String? {
        identifier.flatMap { Self.systemSymbols[$0] }
    }

    var appIcon: NSImage? {
        // Live Activities belong to Control Center; show the app they're for.
        if isLiveActivity, let identifier,
           let url = NSWorkspace.shared.urlForApplication(
               withBundleIdentifier: String(identifier.dropLast(".liveActivity".count))
           ) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSRunningApplication(processIdentifier: pid)?.icon
    }

    private static let systemNames: [String: String] = [
        "com.apple.menuextra.wifi": "Wi-Fi",
        "com.apple.menuextra.battery": "Battery",
        "com.apple.menuextra.bluetooth": "Bluetooth",
        "com.apple.menuextra.focusmode": "Focus",
        "com.apple.menuextra.audiovideo": "Audio & Video",
        "com.apple.menuextra.sound": "Sound",
        "com.apple.menuextra.display": "Display",
        "com.apple.menuextra.airdrop": "AirDrop",
        "com.apple.menuextra.screenmirroring": "Screen Mirroring",
        "com.apple.menuextra.keyboardbrightness": "Keyboard Brightness",
        "com.apple.menuextra.nowplaying": "Now Playing",
        "com.apple.menuextra.siri": "Siri",
        "com.apple.menuextra.spotlight": "Spotlight",
        "com.apple.menuextra.textinput": "Input Sources",
        "com.apple.menuextra.timemachine": "Time Machine",
        "com.apple.menuextra.vpn": "VPN",
        "com.apple.menuextra.weather": "Weather",
        "com.apple.menuextra.accessibility": "Accessibility",
        "com.apple.menuextra.stagemanager": "Stage Manager",
        "com.apple.menuextra.hearing": "Hearing",
        "com.apple.menuextra.users": "Fast User Switching",
    ]

    private static let systemSymbols: [String: String] = [
        "com.apple.menuextra.wifi": "wifi",
        "com.apple.menuextra.battery": "battery.75percent",
        "com.apple.menuextra.bluetooth": "dot.radiowaves.left.and.right",
        "com.apple.menuextra.focusmode": "moon.fill",
        "com.apple.menuextra.audiovideo": "mic.fill",
        "com.apple.menuextra.sound": "speaker.wave.2.fill",
        "com.apple.menuextra.display": "sun.max.fill",
        "com.apple.menuextra.airdrop": "airplayaudio",
        "com.apple.menuextra.screenmirroring": "rectangle.on.rectangle",
        "com.apple.menuextra.keyboardbrightness": "light.max",
        "com.apple.menuextra.nowplaying": "play.fill",
        "com.apple.menuextra.siri": "waveform.circle",
        "com.apple.menuextra.spotlight": "magnifyingglass",
        "com.apple.menuextra.textinput": "keyboard",
        "com.apple.menuextra.timemachine": "clock.arrow.circlepath",
        "com.apple.menuextra.vpn": "network.badge.shield.half.filled",
        "com.apple.menuextra.weather": "cloud.sun.fill",
        "com.apple.menuextra.accessibility": "accessibility",
        "com.apple.menuextra.stagemanager": "squares.leading.rectangle",
        "com.apple.menuextra.hearing": "ear",
        "com.apple.menuextra.users": "person.crop.circle",
    ]
}
