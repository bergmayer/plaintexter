import AppKit
import CoreText

// Run from the project root. Draw each standard icon size directly from paths
// so both the rounded tile and the lettering stay sharp at small sizes.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent(".build/AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func renderIcon(pixels: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    defer { NSGraphicsContext.restoreGraphicsState() }

    let context = graphics.cgContext
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
                            xRadius: 184, yRadius: 184)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 24,
                      color: NSColor.black.withAlphaComponent(0.2).cgColor)
    NSColor(calibratedWhite: 0.965, alpha: 1).setFill()
    tile.fill()
    context.restoreGState()

    NSColor(calibratedWhite: 0.78, alpha: 1).setStroke()
    tile.lineWidth = 2
    tile.stroke()

    let font = NSFont.monospacedSystemFont(ofSize: 540, weight: .semibold)
    let letters = NSAttributedString(string: "pt", attributes: [
        .font: font,
        .foregroundColor: NSColor(calibratedWhite: 0.14, alpha: 1)
    ])
    let line = CTLineCreateWithAttributedString(letters)
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    context.textMatrix = .identity
    context.textPosition = CGPoint(x: 512 - bounds.midX, y: 512 - bounds.midY)
    CTLineDraw(line, context)
    return bitmap.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let file = iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        try renderIcon(pixels: points * scale).write(to: file)
    }
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["--convert", "icns", "--output",
                     root.appendingPathComponent("Resources/AppIcon.icns").path, iconset.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
print(root.appendingPathComponent("Resources/AppIcon.icns").path)
