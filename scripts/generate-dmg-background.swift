import AppKit

let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/dmg-artwork")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for scale in [1, 2] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640 * scale, pixelsHigh: 360 * scale,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 640, height: 360).fill()
    func centered(_ text: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, height: CGFloat = 40) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        (text as NSString).draw(in: NSRect(x: 24, y: y, width: 592, height: height), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor.black, .paragraphStyle: paragraph
        ])
    }
    centered("Drag Plaintexter to Applications", y: 280, size: 21, weight: .semibold)
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 278, y: 200))
    arrow.line(to: NSPoint(x: 357, y: 200))
    arrow.move(to: NSPoint(x: 341, y: 216))
    arrow.line(to: NSPoint(x: 357, y: 200))
    arrow.line(to: NSPoint(x: 341, y: 184))
    arrow.lineWidth = 3
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    NSColor.black.setStroke()
    arrow.stroke()
    centered("Open Plaintexter, then click pt in the menu bar\nto convert clipboard contents to plain text.\nControl-click pt for options.",
             y: 10, size: 14, weight: .regular, height: 64)
    NSGraphicsContext.restoreGraphicsState()
    let suffix = scale == 2 ? "@2x" : ""
    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("background\(suffix).png"))
}
