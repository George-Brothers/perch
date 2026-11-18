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
        static let drawerEnabled = "drawerEnabled"
        static let searchEnabled = "searchEnabled"
        static let searchKeyCode = "searchKeyCode"
        static let searchModifiers = "searchModifiers"
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
    /// A keyboard shortcut that finds and opens any menu bar icon.
    @Published var searchEnabled: Bool {
        didSet { defaults.set(searchEnabled, forKey: Key.searchEnabled) }
    }
    @Published var searchShortcut: Shortcut {
        didSet {
            defaults.set(Int(searchShortcut.keyCode), forKey: Key.searchKeyCode)
            defaults.set(Int(searchShortcut.modifiers.rawValue), forKey: Key.searchModifiers)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.iconStyle: PerchIconStyle.bird.rawValue,
            Key.autoRehideEnabled: true,
            Key.rehideDelay: 15.0,
            Key.rehideOnClickOutside: true,
            Key.drawerEnabled: false,
            Key.searchEnabled: true,
            Key.searchKeyCode: Int(Shortcut.defaultSearch.keyCode),
            Key.searchModifiers: Int(Shortcut.defaultSearch.modifiers.rawValue),
        ])
        iconStyle = PerchIconStyle(rawValue: defaults.string(forKey: Key.iconStyle) ?? "") ?? .bird
        let stored = defaults.dictionary(forKey: Key.priorities) as? [String: String] ?? [:]
        priorities = stored.compactMapValues(IconPriority.init(rawValue:))
        autoRehideEnabled = defaults.bool(forKey: Key.autoRehideEnabled)
        rehideDelay = defaults.double(forKey: Key.rehideDelay)
        rehideOnClickOutside = defaults.bool(forKey: Key.rehideOnClickOutside)
        drawerEnabled = defaults.bool(forKey: Key.drawerEnabled)
        searchEnabled = defaults.bool(forKey: Key.searchEnabled)
        searchShortcut = Shortcut(
            keyCode: UInt32(defaults.integer(forKey: Key.searchKeyCode)),
            modifiers: NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: Key.searchModifiers)))
        )
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
