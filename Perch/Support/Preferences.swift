import AppKit
import Combine

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

/// Where you want an icon. Its order in the bar is its priority: when the bar
/// runs out of room, the leftmost icons are hidden until there's room again.
enum IconPriority: String, CaseIterable, Identifiable {
    /// In the menu bar.
    case shown
    /// Only shown when you show hidden icons.
    case hidden

    var id: String { rawValue }

    /// Reads values saved by earlier versions too ("always", "auto", "hide").
    init?(stored: String) {
        switch stored {
        case "shown", "always", "auto": self = .shown
        case "hidden", "hide": self = .hidden
        default: return nil
        }
    }
}

/// User settings, stored in UserDefaults. Views bind to it directly.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private enum Key {
        static let iconStyle = "iconStyle"
        static let priorities = "iconPriorities"
        static let autoRehideEnabled = "autoRehideEnabled"
        static let rehideDelay = "rehideDelay"
        static let rehideOnClickOutside = "rehideOnClickOutside"
        static let drawerEnabled = "drawerEnabled"
    }

    private let defaults: UserDefaults

    @Published var iconStyle: PerchIconStyle {
        didSet { defaults.set(iconStyle.rawValue, forKey: Key.iconStyle) }
    }
    /// Priority per icon, keyed by `MenuBarItem.key`. Icons not listed are `.auto`.
    @Published private(set) var priorities: [String: IconPriority] {
        didSet { defaults.set(priorities.mapValues(\.rawValue), forKey: Key.priorities) }
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
    /// Show hidden icons in a drawer under the menu bar. Off by default
    /// because it needs Screen Recording permission.
    @Published var drawerEnabled: Bool {
        didSet { defaults.set(drawerEnabled, forKey: Key.drawerEnabled) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.iconStyle: PerchIconStyle.bird.rawValue,
            Key.autoRehideEnabled: true,
            Key.rehideDelay: 15.0,
            Key.rehideOnClickOutside: true,
            Key.drawerEnabled: false,
        ])
        iconStyle = PerchIconStyle(rawValue: defaults.string(forKey: Key.iconStyle) ?? "") ?? .bird
        let stored = defaults.dictionary(forKey: Key.priorities) as? [String: String] ?? [:]
        priorities = stored.compactMapValues(IconPriority.init(stored:)).filter { $0.value == .hidden }
        autoRehideEnabled = defaults.bool(forKey: Key.autoRehideEnabled)
        rehideDelay = defaults.double(forKey: Key.rehideDelay)
        rehideOnClickOutside = defaults.bool(forKey: Key.rehideOnClickOutside)
        drawerEnabled = defaults.bool(forKey: Key.drawerEnabled)
    }

    func priority(for key: String) -> IconPriority {
        priorities[key] ?? .shown
    }

    func setPriority(_ priority: IconPriority, for key: String) {
        if priority == .shown {
            priorities.removeValue(forKey: key)
        } else {
            priorities[key] = priority
        }
    }
}
