import Combine
import Foundation

enum PerchIconStyle: String, CaseIterable, Identifiable {
    case bird
    case chevron
    case dots

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bird: "Bird"
        case .chevron: "Chevron"
        case .dots: "Dots"
        }
    }

    /// The SF Symbol shown in the menu bar. `revealed` is true while hidden icons are showing.
    func symbolName(revealed: Bool) -> String {
        switch self {
        case .bird: revealed ? "bird.fill" : "bird"
        case .chevron: revealed ? "chevron.right" : "chevron.left"
        case .dots: revealed ? "ellipsis.circle.fill" : "ellipsis.circle"
        }
    }
}

enum ClickAction: String, CaseIterable, Identifiable {
    case openPanel
    case revealInBar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openPanel: "Open the Perch panel"
        case .revealInBar: "Show hidden icons in the menu bar"
        }
    }
}

/// User settings, stored in UserDefaults. Views bind to it directly.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private enum Key {
        static let iconStyle = "iconStyle"
        static let clickAction = "clickAction"
        static let archivedSectionEnabled = "archivedSectionEnabled"
        static let autoRehideEnabled = "autoRehideEnabled"
        static let rehideDelay = "rehideDelay"
        static let rehideOnClickOutside = "rehideOnClickOutside"
        static let rehideOnAppSwitch = "rehideOnAppSwitch"
        static let hasSeenWelcome = "hasSeenWelcome"
    }

    private let defaults: UserDefaults

    @Published var iconStyle: PerchIconStyle {
        didSet { defaults.set(iconStyle.rawValue, forKey: Key.iconStyle) }
    }
    /// What a plain click on the bird does. Option-click does the other one.
    @Published var clickAction: ClickAction {
        didSet { defaults.set(clickAction.rawValue, forKey: Key.clickAction) }
    }
    @Published var archivedSectionEnabled: Bool {
        didSet { defaults.set(archivedSectionEnabled, forKey: Key.archivedSectionEnabled) }
    }
    @Published var autoRehideEnabled: Bool {
        didSet { defaults.set(autoRehideEnabled, forKey: Key.autoRehideEnabled) }
    }
    /// Seconds before revealed icons hide again.
    @Published var rehideDelay: Double {
        didSet { defaults.set(rehideDelay, forKey: Key.rehideDelay) }
    }
    @Published var rehideOnClickOutside: Bool {
        didSet { defaults.set(rehideOnClickOutside, forKey: Key.rehideOnClickOutside) }
    }
    @Published var rehideOnAppSwitch: Bool {
        didSet { defaults.set(rehideOnAppSwitch, forKey: Key.rehideOnAppSwitch) }
    }
    @Published var hasSeenWelcome: Bool {
        didSet { defaults.set(hasSeenWelcome, forKey: Key.hasSeenWelcome) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.iconStyle: PerchIconStyle.bird.rawValue,
            Key.clickAction: ClickAction.openPanel.rawValue,
            Key.archivedSectionEnabled: false,
            Key.autoRehideEnabled: true,
            Key.rehideDelay: 10.0,
            Key.rehideOnClickOutside: true,
            Key.rehideOnAppSwitch: false,
            Key.hasSeenWelcome: false,
        ])
        iconStyle = PerchIconStyle(rawValue: defaults.string(forKey: Key.iconStyle) ?? "") ?? .bird
        clickAction = ClickAction(rawValue: defaults.string(forKey: Key.clickAction) ?? "") ?? .openPanel
        archivedSectionEnabled = defaults.bool(forKey: Key.archivedSectionEnabled)
        autoRehideEnabled = defaults.bool(forKey: Key.autoRehideEnabled)
        rehideDelay = defaults.double(forKey: Key.rehideDelay)
        rehideOnClickOutside = defaults.bool(forKey: Key.rehideOnClickOutside)
        rehideOnAppSwitch = defaults.bool(forKey: Key.rehideOnAppSwitch)
        hasSeenWelcome = defaults.bool(forKey: Key.hasSeenWelcome)
    }
}
