import AppKit
import Combine
@preconcurrency import CoreSpotlight
import UniformTypeIdentifiers
import os

/// Puts every menu bar icon in Spotlight, so you can open any icon's menu
/// (even a hidden one) by typing its name. Picking a result comes back to
/// Perch as a user activity; see `AppDelegate.application(_:continue:)`.
///
/// Updates only when the set of icons changes, which Perch already learns
/// from its event-driven scans. Nothing runs on a timer.
@MainActor
final class SpotlightIndex {
    private static let domain = "com.georgebrothers.perch.icons"
    private static let log = Logger(subsystem: "com.georgebrothers.perch", category: "spotlight")
    private let index = CSSearchableIndex.default()
    /// What's in Spotlight now: key → name.
    private var indexed: [String: String] = [:]
    private var cancellable: AnyCancellable?

    init(engine: LayoutEngine) {
        cancellable = engine.$items
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] items in self?.update(items) }
    }

    private func update(_ items: [MenuBarItem]) {
        // Live Activities come and go by themselves; leave them out.
        let icons = items.filter { $0.section != .notShowing && !$0.isLiveActivity }
        // An empty list means Perch can't see the bar (no Accessibility yet).
        guard !icons.isEmpty else { return }
        var current: [String: String] = [:]
        for icon in icons { current[icon.key] = icon.displayName }
        guard current != indexed else { return }
        indexed = current

        let searchable = icons.map(Self.searchableItem)
        let index = self.index
        let log = Self.log
        index.deleteSearchableItems(withDomainIdentifiers: [Self.domain]) { _ in
            index.indexSearchableItems(searchable) { error in
                if let error {
                    log.error("Spotlight indexing failed: \(error.localizedDescription, privacy: .public)")
                } else {
                    log.notice("Spotlight has \(searchable.count) menu bar icons")
                }
            }
        }
    }

    private static func searchableItem(for icon: MenuBarItem) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .item)
        attributes.title = icon.displayName
        attributes.displayName = icon.displayName
        attributes.contentDescription = "Menu bar icon"
        attributes.keywords = [icon.appName, icon.label, "menu bar", "menubar"].compactMap { $0 }
        attributes.thumbnailData = thumbnail(for: icon)
        let item = CSSearchableItem(uniqueIdentifier: icon.key, domainIdentifier: domain, attributeSet: attributes)
        item.expirationDate = .distantFuture
        return item
    }

    /// The app's icon, or the SF Symbol for Apple's own items, as a small PNG.
    private static func thumbnail(for icon: MenuBarItem) -> Data? {
        let image: NSImage?
        if let symbol = icon.systemSymbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 40, weight: .regular))
        } else {
            image = icon.appIcon
        }
        guard let image else { return nil }
        let size = NSSize(width: 64, height: 64)
        let rendered = NSImage(size: size, flipped: false) { rect in
            let fit = image.size.width > 0 ? min(rect.width / image.size.width, rect.height / image.size.height) : 1
            let drawn = NSSize(width: image.size.width * fit, height: image.size.height * fit)
            image.draw(in: NSRect(x: (rect.width - drawn.width) / 2, y: (rect.height - drawn.height) / 2,
                                  width: drawn.width, height: drawn.height))
            return true
        }
        guard let tiff = rendered.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
