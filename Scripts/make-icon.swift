// Renders the application icon at every size an .icns needs.
//
// Drawn in code rather than rasterised from the SVG in Resources/Icon because
// no SVG rasteriser is guaranteed on this machine: ImageMagick here has no
// librsvg delegate, and its own renderer drops gradients silently rather than
// failing, which produced a black plate the first time. CoreGraphics ships with
// macOS, so this has no dependency beyond the Command Line Tools.
//
// Each size is drawn at its native resolution rather than downsampled from
// 1024, so the 16 pt and 32 pt menu-adjacent sizes keep their strokes crisp.
//
// Usage: swift Scripts/make-icon.swift <output-directory>

import AppKit
import CoreGraphics
import Foundation

// The design tokens this icon borrows, from Sources/Claudence/UI/Components/Theme.swift.
enum Palette {
    static let plateTop = CGColor(srgbRed: 1.000, green: 0.992, blue: 0.976, alpha: 1) // #FFFDF9
    static let plateBottom = CGColor(srgbRed: 0.945, green: 0.918, blue: 0.871, alpha: 1) // #F1EADE
    static let plateEdge = CGColor(srgbRed: 0.890, green: 0.851, blue: 0.784, alpha: 1) // #E3D9C8
    static let track = CGColor(srgbRed: 0.929, green: 0.894, blue: 0.839, alpha: 1) // #EDE4D6
    static let arcStart = CGColor(srgbRed: 0.824, green: 0.467, blue: 0.353, alpha: 1) // #D2775A
    static let arcEnd = CGColor(srgbRed: 0.639, green: 0.180, blue: 0.141, alpha: 1) // #A32E24
    static let sessionInk = CGColor(srgbRed: 0.541, green: 0.416, blue: 0.341, alpha: 1) // #8A6A57
}

/// The reading the meter shows. Not full, so the arc has a visible start and
/// end and reads as a gauge rather than as a plain ring.
let reading = 0.70

/// Draws the icon into `context` on a square canvas of `side` points, using
/// top-left coordinates so the geometry matches the SVG in Resources/Icon.
func drawIcon(in context: CGContext, side: CGFloat) {
    let unit = side / 1024 // every measurement below is in 1024-canvas units

    context.translateBy(x: 0, y: side)
    context.scaleBy(x: 1, y: -1)

    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // The plate: the macOS content rect, 824 pt inside a 1024 pt canvas.
    let plate = CGRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
    let corner = 185 * unit
    let platePath = CGPath(roundedRect: plate, cornerWidth: corner, cornerHeight: corner, transform: nil)

    let space = CGColorSpaceCreateDeviceRGB()
    let plateGradient = CGGradient(
        colorsSpace: space,
        colors: [Palette.plateTop, Palette.plateBottom] as CFArray,
        locations: [0, 1]
    )!

    context.saveGState()
    context.addPath(platePath)
    context.clip()
    context.drawLinearGradient(
        plateGradient,
        start: CGPoint(x: plate.midX, y: plate.minY),
        end: CGPoint(x: plate.midX, y: plate.maxY),
        options: []
    )
    context.restoreGState()

    // A hairline edge, so the plate keeps its shape against a white background.
    context.saveGState()
    context.addPath(CGPath(
        roundedRect: plate.insetBy(dx: 1.5 * unit, dy: 1.5 * unit),
        cornerWidth: corner - 1.5 * unit,
        cornerHeight: corner - 1.5 * unit,
        transform: nil
    ))
    context.setStrokeColor(Palette.plateEdge)
    context.setLineWidth(3 * unit)
    context.strokePath()
    context.restoreGState()

    // The power meter: the empty track first, then the reading drawn onto it.
    let centre = CGPoint(x: 512 * unit, y: 512 * unit)
    let radius = 250 * unit
    let ringWidth = 72 * unit

    context.saveGState()
    context.setStrokeColor(Palette.track)
    context.setLineWidth(ringWidth)
    context.addArc(center: centre, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    context.strokePath()
    context.restoreGState()

    // Clockwise from twelve o'clock. The context is y-flipped, so `clockwise:
    // false` is what draws clockwise on screen.
    context.saveGState()
    context.setLineWidth(ringWidth)
    context.setLineCap(.round)
    context.addArc(
        center: centre,
        radius: radius,
        startAngle: -.pi / 2,
        endAngle: -.pi / 2 + .pi * 2 * reading,
        clockwise: false
    )
    context.replacePathWithStrokedPath()
    context.clip()
    let arcGradient = CGGradient(
        colorsSpace: space,
        colors: [Palette.arcStart, Palette.arcEnd] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        arcGradient,
        start: CGPoint(x: plate.minX, y: plate.minY),
        end: CGPoint(x: plate.maxX, y: plate.maxY),
        options: []
    )
    context.restoreGState()

    // Sessions: several at once, which is the whole point of the product.
    let bars: [(x: CGFloat, y: CGFloat, width: CGFloat, alpha: CGFloat)] = [
        (412, 439, 200, 1.00),
        (437, 495, 150, 0.70),
        (457, 551, 110, 0.45),
    ]
    for bar in bars {
        let rect = CGRect(x: bar.x * unit, y: bar.y * unit, width: bar.width * unit, height: 34 * unit)
        context.saveGState()
        context.setFillColor(Palette.sessionInk.copy(alpha: bar.alpha)!)
        context.addPath(CGPath(
            roundedRect: rect,
            cornerWidth: 17 * unit,
            cornerHeight: 17 * unit,
            transform: nil
        ))
        context.fillPath()
        context.restoreGState()
    }
}

func writePNG(side: Int, to url: URL) throws {
    guard let context = CGContext(
        data: nil,
        width: side,
        height: side,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "make-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "no context at \(side)"])
    }

    drawIcon(in: context, side: CGFloat(side))

    guard let image = context.makeImage() else {
        throw NSError(domain: "make-icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "no image at \(side)"])
    }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: side, height: side)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-icon", code: 3, userInfo: [NSLocalizedDescriptionKey: "no png at \(side)"])
    }
    try data.write(to: url)
}

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: swift Scripts/make-icon.swift <output-directory>\n".utf8))
    exit(2)
}
let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

// The set `iconutil` expects. Both members of a pair are drawn at their own
// pixel size, so `icon_32x32.png` and `icon_16x16@2x.png` are separate renders.
let variants: [(name: String, side: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for variant in variants {
    try writePNG(side: variant.side, to: outputDirectory.appendingPathComponent(variant.name))
}

print("wrote \(variants.count) sizes to \(outputDirectory.path)")
