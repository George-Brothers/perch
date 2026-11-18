import AppIntents

/// Spotlight and Shortcuts actions. They run inside Perch, which is always open.

struct ShowHiddenIconsIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Hidden Icons"
    static let description = IntentDescription("Shows the menu bar icons Perch is hiding.")

    @MainActor
    func perform() async throws -> some IntentResult {
        AppDelegate.shared?.showHiddenIcons()
        return .result()
    }
}

struct ArrangeIntent: AppIntent {
    static let title: LocalizedStringResource = "Arrange Menu Bar"
    static let description = IntentDescription("Opens Perch's Arrange panel to reorder and hide menu bar icons.")

    @MainActor
    func perform() async throws -> some IntentResult {
        AppDelegate.shared?.showArrange()
        return .result()
    }
}

struct OpenIconIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Menu Bar Icon"
    static let description = IntentDescription("Opens a menu bar icon's menu, even when it's hidden.")

    @Parameter(title: "Icon")
    var icon: MenuBarIconEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$icon)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        switch await AppDelegate.shared?.openIcon(key: icon.id) {
        case .opened: return .result()
        case .busy: throw OpenFailed.busy
        case .noPermission: throw OpenFailed.noPermission
        case .gone, nil: throw OpenFailed.gone
        }
    }
}

/// A menu bar icon, as Spotlight and Shortcuts see it.
struct MenuBarIconEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Menu Bar Icon"
    static let defaultQuery = MenuBarIconQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct MenuBarIconQuery: EntityStringQuery {
    @MainActor
    private func all() async -> [MenuBarIconEntity] {
        let icons = await AppDelegate.shared?.icons() ?? []
        return icons.map { MenuBarIconEntity(id: $0.key, name: $0.displayName) }
    }

    func entities(for identifiers: [String]) async throws -> [MenuBarIconEntity] {
        await all().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [MenuBarIconEntity] {
        await all().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [MenuBarIconEntity] {
        await all()
    }
}

struct PerchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ShowHiddenIconsIntent(),
            phrases: ["Show hidden icons in \(.applicationName)", "Show hidden menu bar icons with \(.applicationName)"],
            shortTitle: "Show Hidden Icons",
            systemImageName: "menubar.arrow.down.rectangle"
        )
        AppShortcut(
            intent: ArrangeIntent(),
            phrases: ["Arrange menu bar with \(.applicationName)", "Arrange icons in \(.applicationName)"],
            shortTitle: "Arrange Menu Bar",
            systemImageName: "arrow.left.and.right.square"
        )
        AppShortcut(
            intent: OpenIconIntent(),
            phrases: ["Open \(\.$icon) with \(.applicationName)"],
            shortTitle: "Open Menu Bar Icon",
            systemImageName: "menubar.rectangle"
        )
    }
}

private enum OpenFailed: Error, CustomLocalizedStringResourceConvertible {
    /// The icon's app quit or removed it since Shortcuts last looked.
    case gone
    /// Perch is moving icons right now.
    case busy
    /// Perch hasn't been allowed Accessibility yet.
    case noPermission

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .gone: "That icon isn't in the menu bar anymore."
        case .busy: "Perch is arranging icons. Try again in a moment."
        case .noPermission: "Perch needs Accessibility permission. Open Perch to allow it."
        }
    }
}
