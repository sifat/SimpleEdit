// Generates Resources/AppIcon.icns.
//
// Run:  xcrun swift tools/appicon/make-icon.swift
//
// Kept in the repo so the icon is reproducible rather than a binary blob nobody
// can edit. Draws at 1024 and downsamples to every size the iconset needs.
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
let output = root.appendingPathComponent("Resources/AppIcon.icns")

// MARK: - Palette

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}
let topColor = rgb(150, 208, 252)
let bottomColor = rgb(56, 138, 219)
// Amber reads as syntax highlighting and still separates from a light blue
// ground; a second blue would disappear into it.
let accent = rgb(255, 176, 59)

// MARK: - Drawing

func drawIcon(size S: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: S, height: S))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let ctx = NSGraphicsContext.current else { return image }
    ctx.imageInterpolation = .high
    let u = S / 1024  // everything below is authored against a 1024 canvas

    // macOS app icons sit inside a margin rather than filling the tile.
    let margin: CGFloat = 100 * u
    let plate = NSRect(x: margin, y: margin, width: S - margin * 2, height: S - margin * 2)
    // Apple's rounded-rect ratio for macOS icons is ~0.2237 of the plate width.
    let radius = plate.width * 0.2237
    let squircle = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)

    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(starting: topColor, ending: bottomColor)?.draw(in: plate, angle: -90)

    // A soft highlight across the top third, so the tile does not read flat.
    NSGradient(
        starting: NSColor(white: 1, alpha: 0.22),
        ending: NSColor(white: 1, alpha: 0)
    )?.draw(in: NSRect(x: plate.minX, y: plate.midY, width: plate.width, height: plate.height / 2), angle: -90)

    // Content area inside the plate.
    let inset: CGFloat = 90 * u
    let content = plate.insetBy(dx: inset, dy: inset)

    // The line-number gutter, which is the one bit of chrome that makes this
    // read as a code editor rather than a generic document.
    let gutterWidth: CGFloat = 78 * u
    let gutter = NSRect(x: content.minX, y: content.minY, width: gutterWidth, height: content.height)
    NSColor(white: 1, alpha: 0.16).setFill()
    NSBezierPath(roundedRect: gutter, xRadius: 16 * u, yRadius: 16 * u).fill()

    // Rows of "text", widths varied so it looks like code rather than prose.
    let rowHeight: CGFloat = 44 * u
    let rowGap: CGFloat = 42 * u
    // Indentation is what separates "code" from "a to-do list" at a glance, so
    // the rows are nested rather than flush-left.
    let indents: [CGFloat] = [0, 62, 62, 124, 0]
    let widths: [CGFloat] = [300, 330, 250, 210, 150]
    let isAccent = [false, true, false, true, false]

    let block = rowHeight * CGFloat(widths.count) + rowGap * CGFloat(widths.count - 1)
    var y = content.midY + block / 2 - rowHeight
    let textX = content.minX + gutterWidth + 46 * u

    for (index, width) in widths.enumerated() {
        // The line-number tick in the gutter.
        NSColor(white: 1, alpha: 0.45).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: gutter.minX + 22 * u, y: y, width: 34 * u, height: rowHeight),
            xRadius: rowHeight / 2, yRadius: rowHeight / 2
        ).fill()

        (isAccent[index] ? accent : NSColor.white).setFill()
        NSBezierPath(
            roundedRect: NSRect(
                x: textX + indents[index] * u,
                y: y,
                width: width * u,
                height: rowHeight
            ),
            xRadius: rowHeight / 2, yRadius: rowHeight / 2
        ).fill()

        y -= rowHeight + rowGap
    }
    NSGraphicsContext.restoreGraphicsState()

    // A hairline edge keeps the tile crisp against a light Dock.
    NSColor(white: 0, alpha: 0.16).setStroke()
    squircle.lineWidth = 2 * u
    squircle.stroke()

    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else { throw NSError(domain: "icon", code: 1) }
    try png.write(to: url)
}

// MARK: - Iconset

let fm = FileManager.default
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

// The exact set iconutil expects.
let variants: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
    (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

for v in variants {
    let pixels = v.points * v.scale
    let suffix = v.scale == 2 ? "@2x" : ""
    let name = "icon_\(v.points)x\(v.points)\(suffix).png"
    // Draw at the real pixel size so small sizes stay crisp instead of being
    // a blurry downsample of the 1024 artwork.
    let image = drawIcon(size: CGFloat(pixels))
    image.size = NSSize(width: pixels, height: pixels)
    try writePNG(image, to: iconset.appendingPathComponent(name))
    print("  \(name)  \(pixels)x\(pixels)")
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { exit(task.terminationStatus) }
print("wrote \(output.path)")
