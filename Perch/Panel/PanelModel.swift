import Foundation
import os

/// What the Perch panel shows: every menu bar icon, sorted into sections.
@MainActor
final class PanelModel: ObservableObject {
    @Published private(set) var items: [MenuBarItem] = []
    @Published private(set) var hasScanned = false

    private let permissions: Permissions
    private weak var menuBar: MenuBarController?
    private let log = Logger(subsystem: "com.georgebrothers.perch", category: "panel")
    private var scanTask: Task<Void, Never>?

    init(permissions: Permissions, menuBar: MenuBarController) {
        self.permissions = permissions
        self.menuBar = menuBar
    }

    func items(in section: MenuBarItem.Section) -> [MenuBarItem] {
        items.filter { $0.section == section }
    }

    /// Rescans the menu bar. Cheap enough to run every time the panel opens.
    func refresh() {
        permissions.refresh()
        guard permissions.hasAccessibility else {
            items = []
            return
        }
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            let start = Date()
            let found = await MenuBarScanner.scan()
            guard let self, !Task.isCancelled else { return }
            let edges = self.menuBar?.dividerEdges()
            self.items = found.map { item in
                var item = item
                item.section = Self.section(for: item, hiddenEdge: edges?.hidden, archivedEdge: edges?.archived)
                return item
            }
            self.hasScanned = true
            self.log.debug("scan found \(found.count) items in \(Date().timeIntervalSince(start) * 1000, format: .fixed(precision: 0)) ms")
        }
    }

    private static func section(for item: MenuBarItem, hiddenEdge: CGFloat?, archivedEdge: CGFloat?) -> MenuBarItem.Section {
        guard item.isInMenuBar else { return .notShowing }
        if let archivedEdge, item.frame.maxX <= archivedEdge + 2 { return .archived }
        if let hiddenEdge, item.frame.maxX <= hiddenEdge + 2 { return .hidden }
        return .shown
    }
}
