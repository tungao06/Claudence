// Draws the disk image window's background, at 1x and 2x.
//
// Same reasoning as Scripts/make-icon.swift: drawn in CoreGraphics because no
// SVG rasteriser is guaranteed on a machine with only Command Line Tools, and
// the Swift toolchain is already a hard requirement for building the app at all.
//
// The geometry here and the icon positions in Scripts/make-dmg.sh describe the
// same window and have to move together. The two icon centres are at x = 150
// and x = 450, y = 200, in a 600 x 400 window.
//
// Usage: swift Scripts/make-dmg-art.swift <output-directory>

import AppKit
import CoreGraphics
import Foundation

enum Palette {
    static let plateTop = CGColor(srgbRed: 1.000, green: 0.992, blue: 0.976, alpha: 1) // #FFFDF9
    static let plateBottom = CGColor(srgbRed: 0.945, green: 0.918, blue: 0.871, alpha: 1) // #F1EADE
    static let arrow = CGColor(srgbRed: 0.760, green: 0.400, blue: 0.290, alpha: 1) // #C2664A
    static let title = NSColor(srgbRed: 0.239, green: 0.192, blue: 0.157, alpha: 1) // warm ink
    static let subtitle = NSColor(srgbRed: 0.478, green: 0.416, blue: 0.365, alpha: 1)
}

let windowSize = CGSize(width: 600, height: 400)

/// Draws the background at `scale`, in top-left coordinates.
func drawBackground(in context: CGContext, scale: CGFloat) {
    context.translateBy(x: 0, y: windowSize.height * scale)
    context.scaleBy(x: scale, y: -scale)
    context.setShouldAntialias(true)

    let space = CGColorSpaceCreateDeviceRGB()
    let plate = CGGradient(
        colorsSpace: space,
        colors: [Palette.plateTop, Palette.plateBottom] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        plate,
        start: CGPoint(x: 0, y: 0),
        end: CGPoint(x: 0, y: windowSize.height),
        options: []
    )

    // The arrow, between the two icon slots. Short enough that neither icon's
    // label crowds it: the labels sit below y = 240.
    let y: CGFloat = 196
    let start: CGFloat = 258
    let end: CGFloat = 342
    let head: CGFloat = 13

    context.saveGState()
    context.setStrokeColor(Palette.arrow)
    context.setLineWidth(4)
    context.setLineCap(.round)
    context.move(to: CGPoint(x: start, y: y))
    context.addLine(to: CGPoint(x: end - head * 0.6, y: y))
    context.strokePath()

    context.setFillColor(Palette.arrow)
    context.move(to: CGPoint(x: end, y: y))
    context.addLine(to: CGPoint(x: end - head, y: y - head * 0.72))
    context.addLine(to: CGPoint(x: end - head, y: y + head * 0.72))
    context.closePath()
    context.fillPath()
    context.restoreGState()

    // Text, through AppKit so the system font and its metrics are the real
    // ones rather than something reconstructed in CoreText by hand.
    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    defer { NSGraphicsContext.current = previous }

    func centred(_ string: String, font: NSFont, colour: NSColor, top: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour]
        let size = (string as NSString).size(withAttributes: attributes)
        (string as NSString).draw(
            at: NSPoint(x: (windowSize.width - size.width) / 2, y: top),
            withAttributes: attributes
        )
    }

    centred(
        "Claudence",
        font: .systemFont(ofSize: 24, weight: .semibold),
        colour: Palette.title,
        top: 44
    )
    centred(
        "Drag the app onto Applications to install",
        font: .systemFont(ofSize: 12, weight: .regular),
        colour: Palette.subtitle,
        top: 80
    )
    centred(
        "Menu bar only. Look for the ring mark at the right of the menu bar.",
        font: .systemFont(ofSize: 11, weight: .regular),
        colour: Palette.subtitle,
        top: 336
    )
}

func writePNG(scale: CGFloat, to url: URL) throws {
    let width = Int(windowSize.width * scale)
    let height = Int(windowSize.height * scale)
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "make-dmg-art", code: 1)
    }

    drawBackground(in: context, scale: scale)

    guard let image = context.makeImage() else { throw NSError(domain: "make-dmg-art", code: 2) }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: windowSize.width, height: windowSize.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-dmg-art", code: 3)
    }
    try data.write(to: url)
}

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: swift Scripts/make-dmg-art.swift <output-directory>\n".utf8))
    exit(2)
}
let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

try writePNG(scale: 1, to: directory.appendingPathComponent("background.png"))
try writePNG(scale: 2, to: directory.appendingPathComponent("background@2x.png"))

print("wrote background.png and background@2x.png to \(directory.path)")
