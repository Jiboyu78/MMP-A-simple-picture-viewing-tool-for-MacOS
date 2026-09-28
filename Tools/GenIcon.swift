import AppKit

// Generates the PNG set used to build AppIcon.icns.
// Usage: GenIcon <output-iconset-dir>

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"

func drawIcon(pixel: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: pixel, height: pixel))
    image.lockFocus()
    defer { image.unlockFocus() }

    let bounds = NSRect(x: 0, y: 0, width: pixel, height: pixel)
    let radius = pixel * 0.2237
    let shape = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
    shape.addClip()

    let top = NSColor(calibratedRed: 0.18, green: 0.24, blue: 0.36, alpha: 1)
    let bottom = NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.09, alpha: 1)
    NSGradient(colors: [top, bottom])?.draw(in: bounds, angle: 270)

    // Photo frame
    let inset = pixel * 0.20
    let frame = bounds.insetBy(dx: inset, dy: inset)
    let framePath = NSBezierPath(roundedRect: frame, xRadius: pixel * 0.055, yRadius: pixel * 0.055)
    NSColor.white.withAlphaComponent(0.92).setFill()
    framePath.fill()

    // Sun
    let sunR = pixel * 0.062
    let sunCenter = NSPoint(x: frame.maxX - pixel * 0.115, y: frame.maxY - pixel * 0.115)
    let sun = NSBezierPath(ovalIn: NSRect(
        x: sunCenter.x - sunR, y: sunCenter.y - sunR,
        width: sunR * 2, height: sunR * 2
    ))
    NSColor(calibratedRed: 0.99, green: 0.72, blue: 0.25, alpha: 1).setFill()
    sun.fill()

    // Mountain
    let mountain = NSBezierPath()
    mountain.move(to: NSPoint(x: frame.minX + pixel * 0.02, y: frame.minY + pixel * 0.055))
    mountain.line(to: NSPoint(x: frame.minX + pixel * 0.215, y: frame.minY + pixel * 0.215))
    mountain.line(to: NSPoint(x: frame.minX + pixel * 0.365, y: frame.minY + pixel * 0.055))
    mountain.close()
    NSColor(calibratedRed: 0.16, green: 0.55, blue: 0.85, alpha: 1).setFill()
    mountain.fill()

    let mountain2 = NSBezierPath()
    mountain2.move(to: NSPoint(x: frame.minX + pixel * 0.135, y: frame.minY + pixel * 0.055))
    mountain2.line(to: NSPoint(x: frame.minX + pixel * 0.315, y: frame.minY + pixel * 0.30))
    mountain2.line(to: NSPoint(x: frame.minX + pixel * 0.50, y: frame.minY + pixel * 0.055))
    mountain2.close()
    NSColor(calibratedRed: 0.10, green: 0.35, blue: 0.62, alpha: 1).setFill()
    mountain2.fill()

    return image
}

let specs: [(pixel: Int, name: String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

for spec in specs {
    let image = drawIcon(pixel: CGFloat(spec.pixel))
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("failed: \(spec.name)\n".data(using: .utf8)!)
        continue
    }
    let url = URL(fileURLWithPath: outputDir).appendingPathComponent(spec.name)
    try? png.write(to: url)
}

print("iconset written to \(outputDir)")
