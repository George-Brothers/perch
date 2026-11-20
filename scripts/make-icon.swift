// Draws Perch's 1024px app icon: a white bird flying out of a menu bar on a sky-blue squircle.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let size = 1024

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: an 824px squircle centred in the 1024px canvas.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
NSGraphicsContext.saveGraphicsState()
shadow.set()
NSColor.white.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

let sky = NSGradient(
    starting: NSColor(srgbRed: 0.42, green: 0.80, blue: 1.00, alpha: 1),
    ending: NSColor(srgbRed: 0.05, green: 0.38, blue: 0.82, alpha: 1)
)!
sky.draw(in: shape, angle: -90)

// A menu bar strip across the top, with a few icon dots on the right.
NSGraphicsContext.saveGraphicsState()
shape.addClip()
let barHeight: CGFloat = 118
NSColor.white.withAlphaComponent(0.22).setFill()
NSRect(x: tile.minX, y: tile.maxY - barHeight, width: tile.width, height: barHeight).fill()
let dotY = tile.maxY - barHeight / 2
for (index, width) in [CGFloat(54), 54, 96].enumerated() {
    let x = tile.maxX - 120 - CGFloat(index) * 92 - (index == 2 ? 30 : 0)
    let dot = NSBezierPath(roundedRect: NSRect(x: x - width / 2, y: dotY - 18, width: width, height: 36), xRadius: 18, yRadius: 18)
    NSColor.white.withAlphaComponent(0.85).setFill()
    dot.fill()
}
NSGraphicsContext.restoreGraphicsState()

// The bird, flying out of the bar.
let config = NSImage.SymbolConfiguration(pointSize: 360, weight: .regular)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
let bird = NSImage(systemSymbolName: "bird.fill", accessibilityDescription: nil)!
    .withSymbolConfiguration(config)!
let birdSize = bird.size
bird.draw(in: NSRect(x: (CGFloat(size) - birdSize.width) / 2 - 10, y: tile.minY + (tile.height - barHeight - birdSize.height) / 2 - 6,
                     width: birdSize.width, height: birdSize.height))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
