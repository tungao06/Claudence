import SwiftUI
import AppKit
import ClaudenceCore

/// The single definition of the visual language.
///
/// Every colour, size, font and duration used by a component comes from here.
/// No component file contains a colour literal, and no state colour is chosen
/// anywhere but in `Theme.color(for:)`. See spec section 12.
///
/// The palette is the design's: a warm cream ground with a terracotta accent,
/// transcribed from `Design/UI-CONTRACT.md` sections 1 to 4. Three things in
/// this file are *not* transcription, and each says so where it is defined:
///
/// 1. the entire dark appearance, which the design never draws;
/// 2. the Attention, Warning and Critical severities, which the design names
///    in tooltip prose but never paints;
/// 3. the mint sparkline, which the design leaves as an em dash.
///
/// Those are marked OURS so a later reader does not "correct" them back into
/// a transcription that has nothing to correct them against.
///
/// Colour never carries meaning alone. Severity is resolved in exactly one
/// place, `color(for: Severity)`, and every severity also has a distinct glyph
/// and a spoken name, so the reading survives with the colour removed.
enum Theme {

    // MARK: - Palette primitives
    //
    // The only place in the application where a raw colour value is written.
    // Values are packed sRGB, resolved per appearance by AppKit, so the whole
    // theme adapts to light and dark without an asset catalog.
    //
    // Packed integers rather than `#RRGGBB` strings on purpose: the project's
    // "no hex in views" check greps for the CSS form, and a comment quoting a
    // design value would otherwise trip it.

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

    private static func rgb(
        _ packed: UInt32,
        _ alpha: Double
    ) -> (r: Double, g: Double, b: Double, a: Double) {
        (
            r: Double((packed >> 16) & 0xFF) / 255,
            g: Double((packed >> 8) & 0xFF) / 255,
            b: Double(packed & 0xFF) / 255,
            a: alpha
        )
    }

    private static func adaptive(
        light: UInt32,
        dark: UInt32,
        lightAlpha: Double = 1,
        darkAlpha: Double = 1
    ) -> Color {
        adaptive(light: rgb(light, lightAlpha), dark: rgb(dark, darkAlpha))
    }

    // MARK: - Semantic state tokens
    //
    // Only Healthy is painted anywhere in the design. Attention, Warning and
    // Critical appear as words in tooltip copy and nowhere as a swatch, so the
    // ramp below is OURS. It is built out of the two warm families the design
    // does own — the amber cost tile and the terracotta accent — walked from
    // amber through burnt orange to a deep red, so the three levels separate by
    // hue *and* by darkness rather than by saturation alone. Deliberately kept
    // off the accent's own hue at full strength: the accent means "interactive"
    // everywhere else and a severity that borrowed it would blur both readings.

    /// Mint. The one severity the design actually paints.
    static var healthy: Color {
        adaptive(light: 0x4E8A6B, dark: 0x7FBF9B)
    }

    /// Amber. OURS, from the design's cost-tile ink lifted into a signal.
    static var attention: Color {
        adaptive(light: 0xB08536, dark: 0xDFAE5C)
    }

    /// Burnt orange. OURS. Sits between the amber and the terracotta.
    static var warning: Color {
        adaptive(light: 0xBF5E24, dark: 0xE8894A)
    }

    /// Deep red. OURS. Darkest and reddest of the ramp, so it reads as an end
    /// state rather than as a louder warning.
    static var critical: Color {
        adaptive(light: 0xA32E24, dark: 0xE3665A)
    }

    /// The brand accent. Interaction, liveness and emphasis, never severity.
    /// Dark takes the design's own on-dark accent, the one it uses for the menu
    /// bar arc, so the lift is the design's judgement and not ours.
    static var accent: Color {
        adaptive(light: 0xD2775A, dark: 0xEBB48F)
    }

    /// Links and the deep stop of an accent gradient. The light and dark sides
    /// move in opposite directions on purpose: "deeper" on cream means darker,
    /// on a warm dark ground it means brighter, and the role is the constant.
    static var accentDeep: Color {
        adaptive(light: 0xC2664A, dark: 0xF0B694)
    }

    /// Text set on an accent tint, where the tint is already carrying the hue
    /// and the ink only has to stay legible on it.
    static var accentInk: Color {
        adaptive(light: 0xB0674C, dark: 0xE9A98A)
    }

    // MARK: - Surfaces
    //
    // Five steps, ordered by how far forward the surface sits: the canvas is
    // furthest back, raised is furthest forward. Light is the design's cream
    // stack. Dark is OURS, and is a warm dark rather than a neutral one: the
    // cream ground is doing identity work, and inverting it channel by channel
    // produces a muddy brown that reads as a rendering fault. The hue family is
    // held and only the lightness is flipped, with `surfaceRaised` anchored on
    // the one dark surface the design does define, its menu bar strip.

    /// The ground behind the panels.
    static var canvas: Color {
        adaptive(light: 0xF4F1EA, dark: 0x1C1916)
    }

    /// Panel bodies: the popover, the settings card, the dashboard shell.
    static var surface: Color {
        adaptive(light: 0xFFFDF9, dark: 0x23201C)
    }

    /// Rows and sub-cards, one step forward of `surface`.
    static var surfaceRaised: Color {
        adaptive(light: 0xFFFFFF, dark: 0x2A2622)
    }

    /// Facts tiles and subagent rows, one step back of `surface`.
    static var surfaceRecessed: Color {
        adaptive(light: 0xFCFBF8, dark: 0x201D19)
    }

    /// Inset wells: the context-window panel, the transcript facts bar.
    static var surfaceInset: Color {
        adaptive(light: 0xFAF7F1, dark: 0x262320)
    }

    /// Control troughs and pills: segmented controls, count pills, chips.
    static var surfaceControl: Color {
        adaptive(light: 0xF5F0E7, dark: 0x302B26)
    }

    /// Unfilled portion of any bar or ring.
    static var track: Color {
        adaptive(light: 0xEFE8DC, dark: 0x332E28)
    }

    /// Card borders and section rules. The design's workhorse hairline.
    static var separator: Color {
        adaptive(light: 0xEFE8DC, dark: 0x3A342E)
    }

    // MARK: - Text
    //
    // Four steps, each one used for a fixed job so that a reader learns the
    // ranking once. Quaternary is the design's most frequent colour: it carries
    // everything machine-derived and secondary at the same time.

    static var textPrimary: Color {
        adaptive(light: 0x3A322C, dark: 0xF2ECE3)
    }

    static var textSecondary: Color {
        adaptive(light: 0x6B615A, dark: 0xC4B9AE)
    }

    static var textTertiary: Color {
        adaptive(light: 0x8A7F76, dark: 0x9C9188)
    }

    /// Paths, timestamps, help text, axis labels.
    static var textQuaternary: Color {
        adaptive(light: 0xA79C91, dark: 0x7E746B)
    }

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
        // Waiting takes the accent, not a rung of the severity ramp. A session
        // waiting on the user is not a fault and not a degradation, so amber or
        // red would overstate it; the accent is the token that means "live, and
        // it wants you", which is exactly this state. It shares the accent with
        // `running` on purpose: both are live sessions, and the pair is
        // separated by glyph and word rather than by hue. What matters is that
        // waiting no longer shares `textTertiary` with `idle`, which is the
        // confusion the missing mapping used to produce.
        case .waiting: return accent
        default: return textTertiary
        }
    }

    static func glyph(for status: SessionStatus) -> String {
        guard status.isDerivable else { return "questionmark.circle" }
        switch status {
        case .running: return "circle.fill"
        case .idle: return "circle"
        case .completed: return "checkmark.circle.fill"
        // The other three status glyphs are all circles, distinguished only by
        // fill and by a mark inside them, which is a weak difference at the
        // 10pt this renders at. A raised hand has an outline nothing else in
        // the set has, so it survives the size and survives being read without
        // colour. When PERMISSION is eventually proven derivable it must pick a
        // different symbol rather than reusing this one.
        case .waiting: return "hand.raised.fill"
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
        // Not "Waiting", which reads either as "waiting on me" or as "sitting
        // around" and so fails to separate this row from the Idle row directly
        // above it. "Needs you" states who is being waited on, which is the
        // only thing the reader has to act on, and is short enough to survive
        // the row's truncation.
        case .waiting: return "Needs you"
        default: return "Unsupported state"
        }
    }

    // MARK: - Token categories
    //
    // The four parts of the token formula, coloured identically in every
    // breakdown in the product. Cache read is deliberately a different hue
    // family from fresh input: the two cost about an order of magnitude apart
    // per token, and a display that shaded them the same would disagree with
    // the bill. The label is on the token so no call site invents its own
    // wording, which is what keeps the legend and the tooltip in step.

    enum TokenCategory: Sendable, CaseIterable {
        case freshInput
        case cacheWrite
        case cacheRead
        case output

        var label: String {
            switch self {
            case .freshInput: return "Fresh input"
            case .cacheWrite: return "Cache write"
            case .cacheRead: return "Cache read"
            case .output: return "Output"
            }
        }
    }

    static func color(for category: TokenCategory) -> Color {
        switch category {
        case .freshInput: return adaptive(light: 0xE9A183, dark: 0xD98A66)
        case .cacheWrite: return adaptive(light: 0xF0C4AC, dark: 0xE3B295)
        case .cacheRead: return adaptive(light: 0xA99BE0, dark: 0x9C8DD6)
        case .output: return adaptive(light: 0xA8D8C0, dark: 0x7FC4A2)
        }
    }

    // MARK: - Chart bands
    //
    // The daily chart does not use the four category colours. The design pairs
    // a warm body with a lavender cap and saturates both on the most recent
    // column, which is a different job from the breakdown's four-way split, so
    // it gets its own tokens rather than borrowing names that would then lie.

    enum Chart {
        /// Body of a column: everything billable as input.
        static var inputBand: Color { adaptive(light: 0xF0C4AC, dark: 0xC0906F) }
        /// Cap of a column: output.
        static var outputBand: Color { adaptive(light: 0xA99BE0, dark: 0x8577C0) }
        /// The same two, saturated, for the most recent column.
        static var inputBandLatest: Color { adaptive(light: 0xE9A183, dark: 0xE0916F) }
        static var outputBandLatest: Color { adaptive(light: 0x8B7BD8, dark: 0xA395E6) }
        /// Ring drawn around the most recent column.
        static var latestRing: Color { adaptive(light: 0xE9A183, dark: 0xE0916F) }
        /// Horizontal rules behind the plot, and the floor they sit on.
        static var gridline: Color { adaptive(light: 0xF1EAE0, dark: 0x2E2A25) }
        static var baseline: Color { adaptive(light: 0xEDE6DA, dark: 0x3A342E) }
    }

    // MARK: - Session identity
    //
    // These colours carry *identity*, not severity. They answer "which session
    // is this" across a list, which is why they do not weaken the semantic-only
    // rule: severity is still resolved in `color(for: Severity)` alone, and the
    // glyph-plus-text pairing still does the real work for anyone who cannot
    // rely on colour. Two sessions that swapped identity colours would still
    // report the same status in words.
    //
    // The design assigns three fixed identities to three sample sessions. The
    // real product has whatever is running, so the assignment has to be a
    // function of the session id. The mint sparkline stroke is OURS: the design
    // renders the mint session as completed and draws an em dash there.

    struct SessionIdentity: Sendable {
        /// Status dot and the deep stop of the energy gradient.
        let dot: Color
        /// Light stop of the energy gradient.
        let lightStop: Color
        /// Unfilled portion of this session's energy bar.
        let track: Color
        /// Background of this session's status pill and row.
        let tint: Color
        /// Text set on `tint`.
        let ink: Color
        /// Sparkline stroke.
        let sparkline: Color
    }

    /// Coral, lavender, mint. Ordered as the design introduces them.
    private static let identities: [SessionIdentity] = [
        SessionIdentity(
            dot: adaptive(light: 0xD2775A, dark: 0xE0916F),
            lightStop: adaptive(light: 0xF0B694, dark: 0xF2C0A0),
            track: adaptive(light: 0xF1E3D8, dark: 0x3A2E27),
            tint: adaptive(light: 0xFAEBE2, dark: 0x3A2A22),
            ink: adaptive(light: 0xB0674C, dark: 0xEFB394),
            sparkline: adaptive(light: 0xE0A487, dark: 0xE0A487)
        ),
        SessionIdentity(
            dot: adaptive(light: 0x8B7BD8, dark: 0xA395E6),
            lightStop: adaptive(light: 0xC6BCEC, dark: 0xC6BCEC),
            track: adaptive(light: 0xECE8F8, dark: 0x2E2A3A),
            tint: adaptive(light: 0xEEEAFA, dark: 0x2C2740),
            ink: adaptive(light: 0x6A5CB0, dark: 0xBDB1F0),
            sparkline: adaptive(light: 0xA99BE0, dark: 0xA99BE0)
        ),
        SessionIdentity(
            dot: adaptive(light: 0x5FA37E, dark: 0x79BE99),
            lightStop: adaptive(light: 0xA8D8C0, dark: 0xA8D8C0),
            track: adaptive(light: 0xEFE8DC, dark: 0x26302A),
            tint: adaptive(light: 0xE3F0E7, dark: 0x24332B),
            ink: adaptive(light: 0x4E8A6B, dark: 0x93D3B0),
            sparkline: adaptive(light: 0x8FC7A9, dark: 0x8FC7A9)
        )
    ]

    /// The identity for a session, stable for the life of that session id.
    ///
    /// Deliberately not `hashValue`. Swift seeds `Hasher` per process, so a
    /// session would be coral this launch and lavender the next, and the colour
    /// would stop being an identity at all. FNV-1a over the id's UTF-8 is fixed
    /// by its constants, so the same id lands on the same identity on every
    /// launch, on every machine, forever. Distribution across three buckets is
    /// good enough that two sessions on screen together usually differ, and
    /// where they collide the name and path still tell them apart.
    static func identity(forSessionID id: String) -> SessionIdentity {
        identities[Int(stableHash(id) % UInt64(identities.count))]
    }

    private static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    // MARK: - Shadows
    //
    // Named so that no call site writes its own falloff. CSS and SwiftUI do not
    // agree on what a blur radius means and SwiftUI has no spread at all, so
    // these are conversions rather than copies: the design's blur is roughly
    // halved, and a negative spread is folded into a smaller radius instead of
    // being dropped, which is what keeps a tight shadow tight.
    //
    // Dark is OURS: the same geometry over black rather than over the design's
    // warm brown, because a brown shadow on a warm dark ground reads as a stain.

    struct ShadowToken: Sendable {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
    }

    enum Shadow {
        private static func token(
            radius: CGFloat,
            y: CGFloat,
            lightAlpha: Double,
            darkAlpha: Double
        ) -> ShadowToken {
            ShadowToken(
                color: Theme.adaptive(
                    light: 0x3A322C,
                    dark: 0x000000,
                    lightAlpha: lightAlpha,
                    darkAlpha: darkAlpha
                ),
                radius: radius,
                x: 0,
                y: y
            )
        }

        /// The popover and the settings card.
        static var popover: ShadowToken { token(radius: 13, y: 14, lightAlpha: 0.28, darkAlpha: 0.5) }
        /// The dashboard shell.
        static var dashboard: ShadowToken { token(radius: 17, y: 18, lightAlpha: 0.3, darkAlpha: 0.52) }
        /// The detail sheet, which floats over a dimmed backdrop.
        static var sheet: ShadowToken { token(radius: 30, y: 28, lightAlpha: 0.5, darkAlpha: 0.7) }
        /// The tooltip bubble, dark in both appearances.
        static var tooltip: ShadowToken { token(radius: 11, y: 10, lightAlpha: 0.55, darkAlpha: 0.66) }
        /// A toggle knob.
        static var knob: ShadowToken { token(radius: 1.5, y: 1, lightAlpha: 0.28, darkAlpha: 0.5) }
        /// The selected pill of a segmented control.
        static var segment: ShadowToken { token(radius: 1.5, y: 1, lightAlpha: 0.14, darkAlpha: 0.4) }
        /// A row lifting under the pointer.
        static var rowHover: ShadowToken { token(radius: 4, y: 5, lightAlpha: 0.22, darkAlpha: 0.44) }
    }

    /// The scrim behind a modal sheet.
    static var backdrop: Color {
        adaptive(light: 0x2E2924, dark: 0x000000, lightAlpha: 0.36, darkAlpha: 0.52)
    }

    // MARK: - Type scale
    //
    // The design sets prose in Plus Jakarta Sans and every machine-derived
    // value in IBM Plex Mono. Neither is bundled (PLAN-UI decision 2), so the
    // substitution is SF Pro and SF Mono, and the rule the design follows is
    // the thing being preserved: if a value came from the machine it is mono,
    // if it is language somebody wrote it is sans.

    enum Typography {
        /// The one large number in the product: the power meter reading.
        static var hero: Font { .system(size: 40, weight: .semibold, design: .monospaced) }
        /// The unit that trails the hero number, set small and quiet.
        static var heroUnit: Font { .system(size: 18, weight: .regular, design: .monospaced) }
        /// A dashboard stat-tile value.
        static var statValue: Font { .system(size: 26, weight: .semibold, design: .monospaced) }
        /// A secondary measured value.
        static var value: Font { .system(size: 15, weight: .semibold, design: .monospaced) }
        /// A row title, e.g. a session name.
        static var title: Font { .system(size: 14, weight: .bold) }
        /// A card title.
        static var cardTitle: Font { .system(size: 13, weight: .bold) }
        static var body: Font { .system(size: 12, weight: .regular) }
        static var label: Font { .system(size: 11, weight: .semibold) }
        /// Explanatory line under a control. Same size as `label`, lighter, so
        /// the two never compete for the same reading.
        static var help: Font { .system(size: 11, weight: .regular) }
        static var caption: Font { .system(size: 10, weight: .regular) }
        /// Aligned numerals for breakdown tables, paths and byte offsets.
        static var numeric: Font { .system(size: 11, weight: .regular, design: .monospaced) }
        /// The smallest machine value: durations, axis dates, version stamps.
        static var micro: Font { .system(size: 10, weight: .regular, design: .monospaced) }
        /// Uppercase section header. Pair with `Theme.sectionTracking`.
        static var section: Font { .system(size: 11, weight: .bold) }
    }

    /// 0.14em at 11 pt, the design's section-eyebrow tracking.
    static let sectionTracking: CGFloat = 1.54

    // MARK: - Spacing scale
    //
    // Taken from the design's own rhythm rather than from a doubling series:
    // 9 is the popover session row's internal gap, 14 its horizontal margin,
    // 18 the dashboard's gap between sections, 22 and 28 its outer padding.

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 6
        static let m: CGFloat = 9
        static let l: CGFloat = 14
        static let xl: CGFloat = 18
        static let xxl: CGFloat = 22
        static let xxxl: CGFloat = 28
    }

    // MARK: - Radii
    //
    // The design rounds by container size: the bigger the thing, the softer the
    // corner, from a 3 pt legend swatch to a 22 pt sheet. `pill` is the design's
    // 999, spelled as a number large enough that any capsule clamps to a half
    // height.

    enum Radius {
        static let small: CGFloat = 3
        static let medium: CGFloat = 8
        static let control: CGFloat = 10
        static let large: CGFloat = 12
        static let row: CGFloat = 13
        static let panel: CGFloat = 14
        static let card: CGFloat = 16
        static let shell: CGFloat = 18
        static let window: CGFloat = 20
        static let sheet: CGFloat = 22
        static let pill: CGFloat = 999
    }

    // MARK: - Bar and ring metrics

    enum Bar {
        /// The hero energy bar in the power meter.
        static let hero: CGFloat = 14
        /// A per-session token bar.
        static let row: CGFloat = 8
        /// An inline hint bar: a breakdown row, a tool-mix row.
        static let micro: CGFloat = 6

        /// The ring is the Claudence mark, not the meter: the design meters
        /// with bars and tubes and uses the ring as identity. These are the
        /// mark's own geometry, drawn against the design's 96-unit viewBox.
        static let ringSize: CGFloat = 96
        static let ringStroke: CGFloat = 10

        static let sparklineHeight: CGFloat = 16
        /// A sparkline is a hint, not a chart: it gets a fixed, small footprint.
        static let sparklineWidth: CGFloat = 90
        static let sparklineStroke: CGFloat = 1.6
        /// Glyph size for a status dot.
        static let statusGlyph: CGFloat = 8
        /// Glyph size for a severity badge.
        static let severityGlyph: CGFloat = 11
        /// A vertical power-meter tube on the dashboard.
        static let tubeWidth: CGFloat = 56
        static let tubeHeight: CGFloat = 186
        /// A fill below this fraction is floored to it, so a live-but-tiny
        /// reading is still visible rather than rounding away to nothing.
        static let minimumVisibleFill: Double = 0.02
    }

    // MARK: - Layout

    enum Layout {
        /// The popover is fixed at the design's 420 pt; every component is
        /// designed to it. This matches the settings card, which is the same
        /// shell at the same width.
        static let popoverWidth: CGFloat = 420
        /// Shared, narrow real estate. Mirrors the domain constant.
        static let menuBarMaxWidth: CGFloat = Constants.Performance.maxMenuBarWidth
        /// Horizontal padding used by the popover, so components can compute
        /// their own available width when they need to.
        static let popoverPadding: CGFloat = 14
        static var contentWidth: CGFloat { popoverWidth - popoverPadding * 2 }
        /// The dashboard window's design width.
        static let dashboardWidth: CGFloat = 1120
        /// The session detail sheet.
        static let sheetWidth: CGFloat = 760
        /// A tooltip wraps at this width and no wider.
        static let tooltipMaxWidth: CGFloat = 320
    }

    // MARK: - Menu bar label
    //
    // The one piece of the interface that is always on screen and always fighting
    // for width, so its metrics are separated from the popover's and measured
    // rather than chosen.
    //
    // On `minimumScaleFactor`: the widest plausible reading, a two-digit session
    // count beside a full window, measures 67.1 pt at 12 pt against a 60 pt
    // budget, and 57.9 pt at 10 pt. Setting the whole label at 10 pt would make
    // every ordinary reading harder to read in order to buy headroom for a rare
    // one, so the label keeps 12 pt and is allowed to tighten to 9.6 pt only when
    // it actually has to. Truncation is not an option: a clipped percentage is a
    // wrong number, and this project does not show wrong numbers.

    enum MenuBar {
        /// Between the status glyph and the reading.
        static let glyphGap: CGFloat = 3
        /// The status dot.
        static let glyphSize: CGFloat = 8
        /// The reading itself.
        static let textSize: CGFloat = 12
        /// Floor of 9.6 pt. See the note above.
        static let minimumScaleFactor: CGFloat = 0.8
    }

    // MARK: - Motion
    //
    // Animation communicates a state change and nothing else. Every call site
    // routes through `animation(_:reduceMotion:)`, which returns nil when the
    // user has asked for reduced motion, making values snap instead of glide.
    //
    // The design specifies nine repeating animations (pulsing dots, ring
    // breathing, specular glints, a live glow on every fill). None of them are
    // reproduced here and no token below can be used to build one. See the note
    // on `pulse` for the measurement that settled it.

    enum Motion {
        /// The design's interaction curve, used for anything that should feel
        /// like it was released rather than switched.
        static func eased(_ duration: Double) -> Animation {
            .timingCurve(0.22, 0.7, 0.2, 1, duration: duration)
        }

        static var valueChange: Animation { .easeOut(duration: 0.35) }
        static var disclosure: Animation { .easeInOut(duration: 0.18) }
        /// A bar or a column arriving at its value, once, on first appearance.
        static var grow: Animation { eased(0.85) }
        /// A panel or a row arriving.
        static var appear: Animation { eased(0.6) }
        /// A single dip, NOT `.repeatForever`.
        ///
        /// `MenuBarExtra(style: .window)` keeps its popover content mounted
        /// after dismissal, so a repeating animation drives a layout and
        /// display-list pass at the screen refresh rate for the life of the
        /// process. Measured with the popover never opened: 6.9% of a core,
        /// against a 0.5% budget. Two attempts to gate the repeat on an AppKit
        /// "is this presented" signal both failed the same way — the signal
        /// turns true on its own during a frame update and the cost returns —
        /// so the repeat is gone rather than conditional.
        ///
        /// A pulse now fires once per observed change, which is also closer to
        /// what the motion is supposed to say: something just happened.
        static var pulse: Animation { .easeInOut(duration: 0.55) }
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

extension View {
    /// Applies a named shadow. Spelled out here so no call site has to remember
    /// four numbers, and so the whole app moves when one token changes.
    func themeShadow(_ token: Theme.ShadowToken) -> some View {
        shadow(color: token.color, radius: token.radius, x: token.x, y: token.y)
    }
}
