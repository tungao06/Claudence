import SwiftUI
import AppKit
import ClaudenceCore

/// The single definition of the visual language.
///
/// Every colour, size, font and duration used by a component comes from here.
/// No component file contains a colour literal, and no state colour is chosen
/// anywhere but in `Theme.color(for:)`. See spec section 12.
///
/// Monochrome-first: the healthy state is deliberately neutral, so colour only
/// appears when something actually needs attention. One accent colour (blue)
/// carries interaction, never severity.
enum Theme {

    // MARK: - Palette primitives
    //
    // The only place in the application where a raw colour value is written.
    // Values are sRGB components, resolved per appearance by AppKit so the
    // whole theme adapts to light and dark without an asset catalog.

    private static func adaptive(
        light: (r: Double, g: Double, b: Double, a: Double),
        dark: (r: Double, g: Double, b: Double, a: Double)
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
        })
    }

    // MARK: - Semantic state tokens

    /// Neutral graphite. Nothing is wrong, so nothing shouts.
    static var healthy: Color {
        adaptive(light: (0.36, 0.39, 0.42, 1.0), dark: (0.74, 0.77, 0.81, 1.0))
    }

    /// Soft amber. Worth noticing, not worth stopping for.
    static var attention: Color {
        adaptive(light: (0.80, 0.58, 0.13, 1.0), dark: (0.95, 0.75, 0.33, 1.0))
    }

    /// Deep orange. Plan around it.
    static var warning: Color {
        adaptive(light: (0.84, 0.42, 0.12, 1.0), dark: (0.96, 0.60, 0.29, 1.0))
    }

    /// Red. Act now.
    static var critical: Color {
        adaptive(light: (0.76, 0.20, 0.20, 1.0), dark: (0.94, 0.41, 0.39, 1.0))
    }

    /// The one accent colour. Interaction and emphasis only, never severity.
    static var accent: Color {
        adaptive(light: (0.16, 0.44, 0.82, 1.0), dark: (0.41, 0.66, 1.00, 1.0))
    }

    // MARK: - Surface and text tokens

    /// Unfilled portion of any bar or ring.
    static var track: Color {
        adaptive(light: (0.0, 0.0, 0.0, 0.09), dark: (1.0, 1.0, 1.0, 0.14))
    }

    static var textPrimary: Color { Color(nsColor: .labelColor) }
    static var textSecondary: Color { Color(nsColor: .secondaryLabelColor) }
    static var textTertiary: Color { Color(nsColor: .tertiaryLabelColor) }
    static var separator: Color { Color(nsColor: .separatorColor) }
    static var surface: Color { Color(nsColor: .controlBackgroundColor) }

    // MARK: - Severity resolution

    /// The only mapping from state to colour in the application.
    static func color(for severity: Severity) -> Color {
        switch severity {
        case .healthy: return healthy
        case .attention: return attention
        case .warning: return warning
        case .critical: return critical
        }
    }

    /// Colour is never the sole carrier of meaning: each severity also has a
    /// distinct silhouette (circle, circle, triangle, octagon).
    static func glyph(for severity: Severity) -> String {
        switch severity {
        case .healthy: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }

    /// Spoken and written name of a severity. Used in every accessibility label.
    static func name(for severity: Severity) -> String {
        switch severity {
        case .healthy: return "healthy"
        case .attention: return "attention"
        case .warning: return "warning"
        case .critical: return "critical"
        }
    }

    // MARK: - Session status resolution

    static func color(for status: SessionStatus) -> Color {
        guard status.isDerivable else { return textTertiary }
        switch status {
        case .running: return accent
        case .idle: return textTertiary
        case .completed: return healthy
        default: return textTertiary
        }
    }

    static func glyph(for status: SessionStatus) -> String {
        guard status.isDerivable else { return "questionmark.circle" }
        switch status {
        case .running: return "circle.fill"
        case .idle: return "circle"
        case .completed: return "checkmark.circle.fill"
        default: return "questionmark.circle"
        }
    }

    /// Short on-screen text. States with no data source say so rather than
    /// pretending to be a state we can prove. See spec section 6.
    static func name(for status: SessionStatus) -> String {
        guard status.isDerivable else { return "Unsupported state" }
        switch status {
        case .running: return "Working"
        case .idle: return "Idle"
        case .completed: return "Completed"
        default: return "Unsupported state"
        }
    }

    // MARK: - Type scale

    enum Typography {
        /// The one large number in the product: the power meter reading.
        static var hero: Font { .system(size: 26, weight: .semibold, design: .rounded).monospacedDigit() }
        /// A secondary measured value.
        static var value: Font { .system(size: 15, weight: .semibold, design: .rounded).monospacedDigit() }
        /// A row title, e.g. a project name.
        static var title: Font { .system(size: 13, weight: .semibold) }
        static var body: Font { .system(size: 12, weight: .regular) }
        static var label: Font { .system(size: 11, weight: .medium) }
        static var caption: Font { .system(size: 10, weight: .regular) }
        /// Aligned numerals for breakdown tables.
        static var numeric: Font { .system(size: 11, weight: .regular, design: .monospaced) }
        /// Uppercase section header. Pair with `Theme.sectionTracking`.
        static var section: Font { .system(size: 10, weight: .semibold) }
    }

    static let sectionTracking: CGFloat = 1.1

    // MARK: - Spacing scale

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 6
        static let m: CGFloat = 8
        static let l: CGFloat = 12
        static let xl: CGFloat = 16
    }

    // MARK: - Radii

    enum Radius {
        static let small: CGFloat = 3
        static let medium: CGFloat = 6
        static let large: CGFloat = 10
    }

    // MARK: - Bar and ring metrics

    enum Bar {
        /// The hero energy bar in the power meter.
        static let hero: CGFloat = 10
        /// A per-session token bar.
        static let row: CGFloat = 5
        /// An inline hint bar.
        static let micro: CGFloat = 3

        static let ringSize: CGFloat = 96
        static let ringStroke: CGFloat = 9

        static let sparklineHeight: CGFloat = 16
        /// A sparkline is a hint, not a chart: it gets a fixed, small footprint.
        static let sparklineWidth: CGFloat = 64
        static let sparklineStroke: CGFloat = 1.2
        /// Glyph size for a status dot.
        static let statusGlyph: CGFloat = 8
        /// Glyph size for a severity badge.
        static let severityGlyph: CGFloat = 11
    }

    // MARK: - Layout

    enum Layout {
        /// The popover is fixed at 300 pt; every component is designed to it.
        static let popoverWidth: CGFloat = 300
        /// Shared, narrow real estate. Mirrors the domain constant.
        static let menuBarMaxWidth: CGFloat = Constants.Performance.maxMenuBarWidth
        /// Horizontal padding used by the popover, so components can compute
        /// their own available width when they need to.
        static let popoverPadding: CGFloat = 14
        static var contentWidth: CGFloat { popoverWidth - popoverPadding * 2 }
    }

    // MARK: - Motion
    //
    // Animation communicates a state change and nothing else. Every call site
    // routes through `animation(_:reduceMotion:)`, which returns nil when the
    // user has asked for reduced motion, making values snap instead of glide.

    enum Motion {
        static var valueChange: Animation { .easeOut(duration: 0.35) }
        static var disclosure: Animation { .easeInOut(duration: 0.18) }
        static var pulse: Animation { .easeInOut(duration: 1.1).repeatForever(autoreverses: true) }
        /// How far an active glyph dims at the bottom of its pulse. Gentle by
        /// design: motion should register peripherally, not demand attention.
        static let pulseMinOpacity: Double = 0.35
        /// Rotation applied to a disclosure chevron when open.
        static let disclosureRotation: Double = 90
    }

    static func animation(_ base: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : base
    }
}
