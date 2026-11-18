import AppKit
import ScreenCaptureKit
import os

/// Pictures of other apps' menu bar icons, for the drawer.
///
/// Only works with Screen Recording permission, which Perch asks for only when
/// you turn the drawer on. Captures happen when the drawer opens, never on a
/// timer, and the last pictures are kept so the drawer appears instantly.
@MainActor
final class IconImages: ObservableObject {
    /// Picture per `MenuBarItem.key`, at the icon's size in points.
    @Published private(set) var images: [String: NSImage] = [:]
    /// True when the icons are drawn light (for a dark menu bar).
    @Published private(set) var iconsAreLight = false

    private let log = Logger(subsystem: "com.georgebrothers.perch", category: "images")
    private var isCapturing = false

    func image(for item: MenuBarItem) -> NSImage? { images[item.key] }

    /// Captures the given icons. Cheap enough to run each time the drawer opens.
    func capture(_ items: [MenuBarItem]) async {
        guard !items.isEmpty, !isCapturing, CGPreflightScreenCaptureAccess() else { return }
        isCapturing = true
        defer { isCapturing = false }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            log.error("couldn't list windows: \(error.localizedDescription, privacy: .public)")
            return
        }
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        let barWindows = content.windows.filter { $0.windowLayer == statusLevel }

        // Pair each icon with the window that holds it.
        var jobs: [(key: String, window: SCWindow)] = []
        for item in items {
            let mid = CGPoint(x: item.frame.midX, y: item.frame.midY)
            let match = barWindows
                .filter { $0.frame.insetBy(dx: -1, dy: -1).contains(mid) }
                .min { $0.frame.width < $1.frame.width }
            if let match { jobs.append((item.key, match)) }
        }

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let captured = await withTaskGroup(of: (String, NSImage)?.self) { group in
            for job in jobs {
                group.addTask {
                    let config = SCStreamConfiguration()
                    config.width = Int(job.window.frame.width * scale)
                    config.height = Int(job.window.frame.height * scale)
                    config.showsCursor = false
                    config.ignoreShadowsSingleWindow = true
                    let filter = SCContentFilter(desktopIndependentWindow: job.window)
                    guard let cgImage = try? await SCScreenshotManager.captureImage(
                        contentFilter: filter, configuration: config
                    ) else { return nil }
                    let image = NSImage(cgImage: cgImage, size: job.window.frame.size)
                    return (job.key, image)
                }
            }
            var result: [(String, NSImage)] = []
            for await pair in group { if let pair { result.append(pair) } }
            return result
        }

        guard !captured.isEmpty else {
            log.notice("no icons captured")
            return
        }
        var updated = images
        for (key, image) in captured { updated[key] = image }
        images = updated
        iconsAreLight = Self.averageLuminance(of: captured.map(\.1)) > 0.6
    }

    /// Average brightness of the drawn (non-transparent) pixels, 0 to 1.
    private static func averageLuminance(of images: [NSImage]) -> Double {
        var total = 0.0
        var weight = 0.0
        for image in images.prefix(8) {
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let rep = Optional(NSBitmapImageRep(cgImage: cg))
            else { continue }
            let stepX = max(1, rep.pixelsWide / 24)
            let stepY = max(1, rep.pixelsHigh / 12)
            for x in stride(from: 0, to: rep.pixelsWide, by: stepX) {
                for y in stride(from: 0, to: rep.pixelsHigh, by: stepY) {
                    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                          color.alphaComponent > 0.5
                    else { continue }
                    let luminance = 0.299 * color.redComponent + 0.587 * color.greenComponent + 0.114 * color.blueComponent
                    total += luminance * color.alphaComponent
                    weight += color.alphaComponent
                }
            }
        }
        return weight > 0 ? total / weight : 0
    }
}
