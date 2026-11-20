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

/// How much an icon matters to you.
enum IconPriority: String, CaseIterable, Identifiable {
    /// Always in the menu bar.
    case always
    /// In the menu bar when there's room, otherwise hidden.
    case auto
    /// Only shown when you click the bird.
    case hide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .always: "Always"
        case .auto: "Auto"
        case .hide: "Hide"
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.iconStyle: PerchIconStyle.bird.rawValue,
            Key.autoRehideEnabled: true,
            Key.rehideDelay: 15.0,
            Key.rehideOnClickOutside: true,
        ])
        iconStyle = PerchIconStyle(rawValue: defaults.string(forKey: Key.iconStyle) ?? "") ?? .bird
        let stored = defaults.dictionary(forKey: Key.priorities) as? [String: String] ?? [:]
        priorities = stored.compactMapValues(IconPriority.init(rawValue:))
        autoRehideEnabled = defaults.bool(forKey: Key.autoRehideEnabled)
        rehideDelay = defaults.double(forKey: Key.rehideDelay)
        rehideOnClickOutside = defaults.bool(forKey: Key.rehideOnClickOutside)
    }

    func priority(for key: String) -> IconPriority {
        priorities[key] ?? .auto
    }

    func setPriority(_ priority: IconPriority, for key: String) {
        if priority == .auto {
            priorities.removeValue(forKey: key)
        } else {
            priorities[key] = priority
        }
    }
}
