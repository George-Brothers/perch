import AppKit
import ScreenCaptureKit
import os

/// Pictures of other apps' menu bar icons, for the drawer.
///
/// Only works with Screen Recording permission, which Perch asks for only when
/// you turn the drawer on. macOS can only picture icons that are on screen, so
/// Perch captures them whenever the bar is showing everything (at launch, after
/// arranging, when you show hidden icons) and keeps the last picture of each.
/// Never on a timer.
///
/// Each capture makes macOS flash its purple screen-recording dot, so Perch only
/// captures icons that are new, changed size, or haven't been pictured for a while.
@MainActor
final class IconImages: ObservableObject {
    /// Picture per `MenuBarItem.key`, at the icon's size in points.
    @Published private(set) var images: [String: NSImage] = [:]
    /// True when the icons are drawn light (for a dark menu bar).
    @Published private(set) var iconsAreLight = false

    private let log = Logger(subsystem: "com.georgebrothers.perch", category: "images")
    private var isCapturing = false
    /// When each icon was pictured, and how wide it was then.
    private var captured: [String: (date: Date, width: CGFloat)] = [:]
    private static let maxAge: TimeInterval = 30 * 60

    /// True when the icon has no picture, its picture is a different size, or it's old.
    func needsCapture(_ item: MenuBarItem) -> Bool {
        guard images[item.key] != nil, let last = captured[item.key] else { return true }
        let sizeChanged = abs(last.width - item.frame.width) > 1
        return sizeChanged || Date().timeIntervalSince(last.date) > Self.maxAge
    }

    func image(for item: MenuBarItem) -> NSImage? { images[item.key] }

    /// Rescans and pictures whatever needs it, following all of Perch's rules
    /// (drawer on, permission, no menu open). Set by the app; Settings calls it.
    var refresh: (() async -> Void)?

    private var themeObserver: NSObjectProtocol?

    init() {
        // Light/Dark mode redraws every icon: retake all pictures next time
        // they're on screen, keeping the old ones until then.
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.captured.removeAll() }
        }
    }

    /// Returns once no capture is running.
    func waitUntilIdle() async {
        while isCapturing { try? await Task.sleep(for: .milliseconds(50)) }
    }

    func clear() {
        images = [:]
        captured = [:]
        iconsAreLight = false
    }

    /// Captures the given icons that are on screen right now.
    func capture(_ items: [MenuBarItem]) async {
        guard !items.isEmpty, !isCapturing, CGPreflightScreenCaptureAccess() else { return }
        isCapturing = true
        defer { isCapturing = false }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            log.error("couldn't list windows: \(error.localizedDescription, privacy: .public)")
            return
        }
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        let barWindows = content.windows.filter { $0.windowLayer == statusLevel }

        // Pair each icon with the window that holds it.
        var jobs: [(key: String, window: SCWindow)] = []
        let widths = Dictionary(items.map { ($0.key, $0.frame.width) }, uniquingKeysWith: { a, _ in a })
        for item in items {
            let mid = CGPoint(x: item.frame.midX, y: item.frame.midY)
            let match = barWindows
                .filter { $0.isOnScreen && $0.frame.insetBy(dx: -1, dy: -1).contains(mid) }
                .min { $0.frame.width < $1.frame.width }
            if let match { jobs.append((item.key, match)) }
        }

        let pictures = await withTaskGroup(of: (String, NSImage)?.self) { group in
            for job in jobs {
                // SCWindow frames use a top-left origin on the primary display.
                let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
                let mid = CGPoint(x: job.window.frame.midX, y: job.window.frame.midY)
                let scale = NSScreen.screens.first { screen in
                    CGRect(x: screen.frame.minX, y: primaryTop - screen.frame.maxY,
                           width: screen.frame.width, height: screen.frame.height).contains(mid)
                }?.backingScaleFactor ?? 2
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

        guard !pictures.isEmpty else {
            log.notice("no icons captured")
            return
        }
        var updated = images
        let now = Date()
        for (key, image) in pictures {
            updated[key] = image
            captured[key] = (now, widths[key] ?? image.size.width)
        }
        images = updated
        // Judge from every picture, so one colorful new icon can't flip the look.
        iconsAreLight = Self.averageLuminance(of: Array(updated.values)) > 0.6
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
