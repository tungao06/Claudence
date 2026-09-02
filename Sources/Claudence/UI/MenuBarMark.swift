import AppKit
import SwiftUI

/// The menu bar's ring mark, drawn into an `NSImage`.
///
/// ## Why this is not the SwiftUI view
///
/// `RingMark` and `QuietMark` are `View`s built out of `Shape`s, and they are
/// the right thing everywhere the application paints its own surface. They draw
/// nothing at all inside a `MenuBarExtra` label. Measured on macOS 26.6.2 with
/// the label reduced to
///
/// ```swift
/// HStack { Circle().fill(.red).frame(width: 8, height: 8); Text("X") }
/// ```
///
/// the menu bar showed `X` and no dot. `Text` renders, shapes do not. SwiftUI
/// hands the label to AppKit as a status item image, and whatever it uses to
/// produce that image does not carry vector drawing through.
///
/// The failure was silent and total rather than faint, and in the one style
/// where the mark is the whole label -- `.minimal`, which draws the ring and no
/// reading -- it took the entire status item with it. The application was
/// running, the popover was mounted, `NSStatusItem` existed, and the menu bar
/// had nothing on it and so no way to reach any of it. That is the bug this
/// file exists to fix: an accessory application with no Dock icon and no
/// Force Quit entry that cannot be clicked cannot be quit either.
///
/// ## Template images
///
/// A neutral mark is drawn as a template, so AppKit tints it against whatever
/// the menu bar happens to be. This is not a preference. The menu bar is the
/// one surface this application does not paint and whose appearance it cannot
/// read: it follows the wallpaper behind it, not `NSApp.appearance`, so a
/// colour resolved from the app's own appearance can land dark ink on a dark
/// strip. A template cannot.
///
/// A *measured* mark keeps its severity colour, and is worth the risk the
/// template avoids: the colour is one of the two redundant cues the project
/// requires, the reading beside it carries the same fact in digits, and amber
/// and red read against both a light and a dark strip. Neutral grey does not,
/// which is exactly why the unknown state is the one that gives up its ink.
enum MenuBarMark {
    /// The gauge: a continuous ring with the reading laid over it, or a broken
    /// ring when there is no reading. Same geometry as `RingMark`, which stays
    /// the definition everywhere the app paints its own background.
    ///
    /// - Parameter percentUsed: nil draws the broken ring. A measured zero
    ///   draws the continuous track with no arc, which is why "arc absent"
    ///   could not be the unknown state.
    static func gauge(
        percentUsed: Double?,
        size: CGFloat,
        arcColor: Color,
        trackColor: Color
    ) -> NSImage {
        let fraction = percentUsed.map { min(1, max(0, $0 / 100)) }

        let image = draw(size: size) { context, center, radius, stroke in
            guard let fraction else {
                // The broken ring is drawn in the arc's ink rather than the
                // track's: it is the only mark there is in this state, so it
                // has to be as legible as a reading would have been.
                NSColor(arcColor).setStroke()
                context.setLineWidth(stroke)
                context.setLineCap(.butt)
                context.setLineDash(
                    phase: 0,
                    lengths: Theme.Mark.unknownDashMultiples.map { $0 * stroke }
                )
                strokeArc(context, center, radius, 1)
                return
            }

            NSColor(trackColor).setStroke()
            context.setLineWidth(stroke)
            context.setLineCap(.round)
            context.setLineDash(phase: 0, lengths: [])
            strokeArc(context, center, radius, 1)

            guard fraction > 0 else { return }
            NSColor(arcColor).setStroke()
            strokeArc(context, center, radius, fraction)
        }

        // Only the unknown mark gives up its colour; see the note above.
        image.isTemplate = fraction == nil
        return image
    }

    /// The live reading turned off: a plain continuous ring, no arc, no
    /// reading. A third silhouette, distinct from both honest states, so the
    /// menu bar never implies a measurement that is being withheld.
    static func quiet(size: CGFloat) -> NSImage {
        let image = draw(size: size) { context, center, radius, stroke in
            NSColor.labelColor.setStroke()
            context.setLineWidth(stroke)
            context.setLineCap(.round)
            strokeArc(context, center, radius, 1)
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Drawing

    /// Sets up the flipped context every mark shares and hands the body its
    /// geometry.
    ///
    /// Flipped, because the angles come from `Theme.Mark` and those were
    /// written for SwiftUI's y-down space: in a flipped context an increasing
    /// angle sweeps clockwise, which is the direction the gauge fills.
    ///
    /// The radius accounts for the stroke the same way `RingMark` does with its
    /// `.padding(stroke / 2)`: the path is drawn on the centreline, so half the
    /// stroke falls outside the arc and has to be paid for out of the size.
    private static func draw(
        size: CGFloat,
        _ body: @escaping (
            _ context: CGContext,
            _ center: CGPoint,
            _ radius: CGFloat,
            _ stroke: CGFloat
        ) -> Void
    ) -> NSImage {
        let stroke = size * Theme.Mark.strokeFraction
        return NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            body(
                context,
                CGPoint(x: size / 2, y: size / 2),
                (size - stroke) / 2,
                stroke
            )
            return true
        }
    }

    /// Strokes `fraction` of the gauge circle, starting where the design starts
    /// it rather than at twelve o'clock.
    private static func strokeArc(
        _ context: CGContext,
        _ center: CGPoint,
        _ radius: CGFloat,
        _ fraction: Double
    ) {
        context.beginPath()
        let path = CGMutablePath()
        path.addRelativeArc(
            center: center,
            radius: radius,
            startAngle: CGFloat(Theme.Mark.arcStart * .pi / 180),
            delta: CGFloat(fraction * 2 * .pi)
        )
        context.addPath(path)
        context.strokePath()
    }
}
