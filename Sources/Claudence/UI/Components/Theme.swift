import SwiftUI
import AppKit
import ClaudenceCore

/// The single definition of the visual language.
///
/// Every colour, size, font and duration used by a component comes from here.
/// No component file contains a colour literal, and no state colour is chosen
/// anywhere but in `Theme.color(for:)`. See spec section 12.
///
/// The palette is the design's: a warm cream ground with a terracotta accent.
/// It is taken from `Design/Claudence-UI.dc.html` section `1a`, which is the
/// design itself; `Design/UI-CONTRACT.md` is a transcription of that file and
/// is lossy, so where the two disagree the HTML wins and the token says which
/// declaration it came from. Four things in this file are *not* transcription,
/// and each says so where it is defined:
///
/// 1. the entire dark appearance, which the design never draws;
/// 2. the Attention, Warning and Critical severities, which the design names
///    in tooltip prose but never paints, including their `mark(for:)` glyphs;
/// 3. the Idle and Waiting status glyphs, for the same reason;
/// 4. the mint sparkline, which the design leaves as an em dash.
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

    /// The four severity inks as raw stops.
    ///
    /// Written once here because two things read them: the discrete tokens
    /// below, and `severityRamp(percent:)`, which walks between them. Two
    /// hand-kept copies of these numbers would eventually disagree, and the
    /// place they would disagree is exactly a threshold boundary, where a ring
    /// and the word beside it would then be saying different things.
    enum SeverityInk {
        static let healthy = (light: UInt32(0x4E8A6B), dark: UInt32(0x7FBF9B))
        static let attention = (light: UInt32(0xB08536), dark: UInt32(0xDFAE5C))
        static let warning = (light: UInt32(0xBF5E24), dark: UInt32(0xE8894A))
        static let critical = (light: UInt32(0xA32E24), dark: UInt32(0xE3665A))
    }

    /// Mint. The one severity the design actually paints.
    static var healthy: Color {
        adaptive(light: SeverityInk.healthy.light, dark: SeverityInk.healthy.dark)
    }

    /// Amber. OURS, from the design's cost-tile ink lifted into a signal.
    static var attention: Color {
        adaptive(light: SeverityInk.attention.light, dark: SeverityInk.attention.dark)
    }

    /// Burnt orange. OURS. Sits between the amber and the terracotta.
    static var warning: Color {
        adaptive(light: SeverityInk.warning.light, dark: SeverityInk.warning.dark)
    }

    /// Deep red. OURS. Darkest and reddest of the ramp, so it reads as an end
    /// state rather than as a louder warning.
    static var critical: Color {
        adaptive(light: SeverityInk.critical.light, dark: SeverityInk.critical.dark)
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

    /// A link under the pointer. HTML `a:hover { color: 0xA24F37 }`.
    static var accentHover: Color {
        adaptive(light: 0xA24F37, dark: 0xF5C7AB)
    }

    /// Ink for the `\u{2713} Healthy` pill in the popover hero.
    ///
    /// Distinct from `healthy` on purpose, and this is not a rounding error in
    /// the transcription: the design paints the popover pill `0x7E9E86` and the
    /// dashboard's healthy banner `0x4E8A6B`, because the pill sits on a small
    /// mint tint and the banner sits on a large one. Both values are in the
    /// HTML, three thousand bytes apart.
    static var healthyInk: Color {
        adaptive(light: 0x7E9E86, dark: 0x8FBF9E)
    }

    /// The second line of the dashboard's healthy banner, quieter than its
    /// heading. HTML `color: 0x5D7F6B`.
    static var healthyInkSoft: Color {
        adaptive(light: 0x5D7F6B, dark: 0x9CC7AC)
    }

    /// The healthy banner's border. HTML `border: 1px solid 0xD4E7DA`.
    static var healthyBorder: Color {
        adaptive(light: 0xD4E7DA, dark: 0x2F4438)
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

    // The design does not use one border colour. It uses five, and the
    // difference between them is what stops a popover, a card inside it and a
    // row inside that from reading as three concentric versions of the same
    // box. `separator` above is the workhorse; the four below are the ones the
    // HTML actually paints at each nesting level, taken from the inline styles
    // in `Design/Claudence-UI.dc.html` section `1a`.

    /// A card's own border: the popover session row, a dashboard sub-card.
    /// HTML `border: 1px solid 0xEDE6DA`.
    static var borderCard: Color {
        adaptive(light: 0xEDE6DA, dark: 0x38322C)
    }

    /// The outermost border of a floating surface: popover, settings card,
    /// dashboard shell, detail sheet. HTML `border: 1px solid 0xE9E1D4`.
    static var borderShell: Color {
        adaptive(light: 0xE9E1D4, dark: 0x413A33)
    }

    /// The dashboard power tube's border. HTML `border: 1px solid 0xEBE2D4`.
    static var borderTube: Color {
        adaptive(light: 0xEBE2D4, dark: 0x3E3830)
    }

    /// A tile's border under the pointer. HTML `border-color: 0xE5DACB`.
    static var borderHover: Color {
        adaptive(light: 0xE5DACB, dark: 0x4A4239)
    }

    /// The rule between stacked rows inside a panel: activity rows and cost
    /// rows in the detail sheet. Quieter than `separator`, which is what keeps
    /// a list of eight rows from reading as eight cards.
    /// HTML `border-bottom: 1px solid 0xF3EDE3`.
    static var hairlineRow: Color {
        adaptive(light: 0xF3EDE3, dark: 0x332E28)
    }

    /// The faintest rule in the product: a chart gridline. HTML `0xF1EAE0`.
    static var hairlineChart: Color {
        adaptive(light: 0xF1EAE0, dark: 0x322D27)
    }

    /// The popover's bottom strip, one step back from `surface` so the exit
    /// row reads as chrome rather than as content. HTML `background: 0xFBF8F2`.
    static var surfaceFooter: Color {
        adaptive(light: 0xFBF8F2, dark: 0x1F1C18)
    }

    /// The dashboard power tube's empty column. HTML `background: 0xF5EFE6`.
    static var surfaceTube: Color {
        adaptive(light: 0xF5EFE6, dark: 0x2C2823)
    }

    /// A switch in its off position. HTML `background: 0xE6DED2`.
    static var surfaceToggleOff: Color {
        adaptive(light: 0xE6DED2, dark: 0x453D35)
    }

    /// The power hero's empty track, which the design paints warmer than every
    /// other track in the file. HTML `background: 0xF1E3D8`.
    static var heroTrack: Color {
        adaptive(light: 0xF1E3D8, dark: 0x3A2E27)
    }

    /// The dotted rule under a tooltip trigger. HTML `0xD6CCBF`.
    static var dottedUnderline: Color {
        adaptive(light: 0xD6CCBF, dark: 0x5A5147)
    }

    /// The dotted rule under a tooltip trigger set on the warm hero panel,
    /// where the neutral one disappears. HTML `0xC9B7A8`.
    static var dottedUnderlineWarm: Color {
        adaptive(light: 0xC9B7A8, dark: 0x6B5C50)
    }

    /// The dashboard's four stat tiles, each with its own ground, border and
    /// ink, exactly as the HTML paints them.
    ///
    /// A separate family from the severity ramp on purpose. The tiles are
    /// identity, not state: the cost tile is amber whether the cost is small or
    /// large. An earlier build borrowed `attention` for the cost tile and
    /// `healthy` for the sessions tile, which put the severity ramp to
    /// decorative work and left `attention` meaning two different things on one
    /// screen.
    ///
    /// Dark values are ours — the design has no dark mode. Each ground is the
    /// hue carried down to sit just above `surface`, each ink the same hue
    /// lifted until it reads on that ground.
    enum Tile {
        static var warmFill: Color { adaptive(light: 0xFBEDE4, dark: 0x33261F) }
        static var warmBorder: Color { adaptive(light: 0xF3DFD2, dark: 0x45332A) }
        static var warmInk: Color { adaptive(light: 0xA0715C, dark: 0xD9A88C) }

        static var lavenderFill: Color { adaptive(light: 0xEEEAFA, dark: 0x272338) }
        static var lavenderBorder: Color { adaptive(light: 0xE1DBF5, dark: 0x363050) }
        static var lavenderInk: Color { adaptive(light: 0x6A5CB0, dark: 0xB3A7EA) }

        static var mintFill: Color { adaptive(light: 0xE3F0E7, dark: 0x1F2E26) }
        static var mintBorder: Color { adaptive(light: 0xD4E7DA, dark: 0x2C4034) }
        static var mintInk: Color { adaptive(light: 0x4E8A6B, dark: 0x7FBF9B) }

        static var amberFill: Color { adaptive(light: 0xF8F1DC, dark: 0x332C1B) }
        static var amberBorder: Color { adaptive(light: 0xEEE4C9, dark: 0x453C26) }
        static var amberInk: Color { adaptive(light: 0x957C3C, dark: 0xD8BC77) }
    }

    /// The dotted rule under a trigger inside the detail sheet, whose warm
    /// inset panel is a shade darker than the popover's. HTML `0xC6BBAF`.
    static var dottedUnderlineSheet: Color {
        adaptive(light: 0xC6BBAF, dark: 0x67584C)
    }

    /// The tooltip bubble's ground. HTML `0x2E2924`.
    ///
    /// The one colour in the product that is deliberately the SAME in both
    /// appearances. Everything else here inverts, and this must not: a tooltip
    /// is a transient overlay that has to read as sitting above the surface it
    /// covers, and the design's is dark against a cream page. Inverting it in
    /// dark mode would make it cream on near-black, which reads as another
    /// panel rather than as something floating over one.
    static var tooltipSurface: Color {
        adaptive(light: 0x2E2924, dark: 0x2E2924)
    }

    /// The tooltip bubble's ink. HTML `0xF6F1E9`. Fixed for the same reason.
    static var tooltipInk: Color {
        adaptive(light: 0xF6F1E9, dark: 0xF6F1E9)
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

    /// Body ink softened by one step. The design uses it for the event text in
    /// the detail sheet's activity list. HTML `color: 0x4C443E`.
    static var textPrimarySoft: Color {
        adaptive(light: 0x4C443E, dark: 0xE6DDD2)
    }

    /// The quietest text in the design: the dashboard's tagline, and nothing
    /// else. HTML `color: 0xB5AAA0`.
    static var textQuinary: Color {
        adaptive(light: 0xB5AAA0, dark: 0x6A6058)
    }

    /// Chevrons and the `\u{00B7}` separators between meta values. Not a text
    /// colour so much as a punctuation colour: it is what a glyph that is
    /// structure rather than content is painted. HTML `color: 0xC6BBAF`.
    static var textDisabled: Color {
        adaptive(light: 0xC6BBAF, dark: 0x6E645C)
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

    /// The severity ramp as a continuous reading rather than four steps.
    ///
    /// Used by the menu bar mark, where the arc is a gauge and the four-step
    /// colour made it lie about its own resolution: an arc that grows smoothly
    /// from 59% to 61% while its ink jumps from mint to amber says the jump
    /// happened at that instant, when what actually happened is that a boundary
    /// the user cannot see was crossed. A continuous ink says "getting fuller",
    /// which is what the glance from across the room is asking.
    ///
    /// ## Where the stops sit, and why exactly there
    ///
    /// Each token lands precisely on the threshold that names it:
    ///
    /// ```
    ///   0%  mint          healthy
    ///  60%  amber         attention  (Constants.UsageThreshold.attention)
    ///  80%  burnt orange  warning    (Constants.UsageThreshold.warning)
    ///  90%  deep red      critical   (Constants.UsageThreshold.critical)
    /// 100%  deep red
    /// ```
    ///
    /// So the ramp and `Constants.UsageThreshold.severity(forPercent:)` agree
    /// at every boundary, and the only thing the ramp adds between them is
    /// anticipation: at 55% the ring is already warming, which is a true
    /// statement about a window that is more than half spent and is the whole
    /// reason a gauge is a gauge and not a light.
    ///
    /// Interpolated in sRGB, not in a perceptual space. The four stops were
    /// chosen to separate by hue *and* by darkness, so a straight line between
    /// two of them keeps both of those moving in the right direction; the
    /// cost is that the midpoints are a touch duller than a perceptual blend
    /// would give, which on an 8-to-14 pt ring is not a difference anyone can
    /// see.
    ///
    /// Colour is never the only cue. The arc length carries the same reading,
    /// the label beside it prints the number, and the accessibility label
    /// speaks it.
    static func severityRamp(percent: Double) -> Color {
        let stops: [(percent: Double, ink: (light: UInt32, dark: UInt32))] = [
            (0, SeverityInk.healthy),
            (Constants.UsageThreshold.attention, SeverityInk.attention),
            (Constants.UsageThreshold.warning, SeverityInk.warning),
            (Constants.UsageThreshold.critical, SeverityInk.critical),
        ]

        // A source reporting 104% cannot walk past the end of the ramp, the
        // same clamp the arc itself applies to its own length.
        let value = min(100, max(0, percent))

        guard let upper = stops.firstIndex(where: { value < $0.percent }) else {
            return critical
        }
        guard upper > 0 else { return healthy }

        let low = stops[upper - 1]
        let high = stops[upper]
        let span = high.percent - low.percent
        let t = span > 0 ? (value - low.percent) / span : 0

        return adaptive(
            light: blend(rgb(low.ink.light, 1), rgb(high.ink.light, 1), t),
            dark: blend(rgb(low.ink.dark, 1), rgb(high.ink.dark, 1), t)
        )
    }

    private static func blend(
        _ from: (r: Double, g: Double, b: Double, a: Double),
        _ to: (r: Double, g: Double, b: Double, a: Double),
        _ t: Double
    ) -> (r: Double, g: Double, b: Double, a: Double) {
        (
            r: from.r + (to.r - from.r) * t,
            g: from.g + (to.g - from.g) * t,
            b: from.b + (to.b - from.b) * t,
            a: from.a + (to.a - from.a) * t
        )
    }

    /// Background for a severity pill.
    ///
    /// OURS. The design paints exactly one severity tint, the mint behind
    /// `Healthy`, and names the other three only in prose, so a hand-picked
    /// table of four would be three inventions and one transcription. Deriving
    /// the tint from the severity's own colour keeps all four in step with the
    /// ramp above for free and keeps this file the only place a colour is
    /// decided. The pill still carries a glyph and a word, so the tint is never
    /// the thing being read.
    static func tint(for severity: Severity) -> Color {
        color(for: severity).opacity(0.16)
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

    /// The design's own glyph for a severity, as a text character.
    ///
    /// Every "icon" in `Design/Claudence-UI.dc.html` is a text glyph, not an
    /// asset: `\u{2713}`, `\u{25CF}`, `\u{27F3}`, `\u{203A}`, `\u{2192}`,
    /// `\u{2715}`. The SF Symbol table above stays, because the dashboard and
    /// the detail sheet render at sizes where a symbol is the better shape and
    /// because the menu bar mark is drawn, not typed. This table is for the two
    /// pills the design actually sets in type, where substituting a symbol
    /// changes the string a reader sees.
    ///
    /// `\u{2713} Healthy` is the design's. The other three are OURS, for the
    /// same reason the colours are: the design names Attention, Warning and
    /// Critical in tooltip prose and never draws one. They are chosen to differ
    /// by silhouette rather than by weight, so the ramp survives being read at
    /// 11 pt without colour.
    static func mark(for severity: Severity) -> String {
        switch severity {
        case .healthy: return "\u{2713}"     // check
        case .attention: return "\u{25C6}"   // filled diamond
        case .warning: return "\u{25B2}"     // filled triangle
        case .critical: return "\u{2715}"    // cross
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

    /// The design's own glyph for a session state, as a text character.
    ///
    /// The HTML sets exactly two of these: `\u{25CF} Working` on a live row and
    /// `\u{2713} Completed` on a finished one, plus a templated
    /// `\u{25CF} {{ status }}` which shows the dot is the design's default for
    /// "a session in some state". Idle therefore takes a hollow ring rather
    /// than a second filled dot, so live and idle differ in silhouette and not
    /// only in ink; the two non-derivable states take a question mark, which is
    /// what they are. Both of those are OURS.
    static func mark(for status: SessionStatus) -> String {
        guard status.isDerivable else { return "?" }
        switch status {
        case .running: return "\u{25CF}"     // filled dot, the design's
        case .idle: return "\u{25CB}"        // hollow ring, OURS
        case .completed: return "\u{2713}"   // check, the design's
        case .waiting: return "\u{25D0}"     // half-filled dot, OURS
        default: return "?"
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

    // MARK: - Power hero panel
    //
    // The popover's hero sits on its own warm gradient rather than on
    // `surface`. That is what separates the meter from the list below it
    // without a rule, and it is the only panel in the product that gets a
    // gradient at all, which is how the eye finds the reading first. Design
    // section 5.2. Dark is OURS, on the same principle as the surface stack:
    // the hue family is held and the lightness flipped, so the panel still
    // reads as one step warmer than the surface behind it.

    enum Hero {
        static var panelTop: Color { adaptive(light: 0xFBEDE4, dark: 0x2F2721) }
        static var panelBottom: Color { adaptive(light: 0xF7EFE9, dark: 0x282320) }
        static var panelBorder: Color { adaptive(light: 0xF0DFD2, dark: 0x3B322B) }
    }

    // MARK: - Ring mark
    //
    // The Claudence glyph, design section 3.7. Every number is a fraction of
    // the design's 96-unit box, so one table drives the mark at both sizes it
    // is drawn at here (the menu bar reading and the popover header) instead of
    // one table per size.
    //
    // The mark is a gauge, not decoration: the arc length is the 5-hour
    // window's reading. The design breathes that arc with `arcHeadBreathe`,
    // which is a repeating animation applied to the menu bar label itself, the
    // single worst place in the process for one. The arc here is static.

    // Fractions are of the mark's *outer* diameter rather than of the design's
    // box, so a caller sizes the mark by the space it will actually occupy.
    // The design's outer extent is `2 * r33 + w16 = 82` units of the 96-unit
    // box, and every fraction below is written over that 82.

    enum Mark {
        /// The design thickens the stroke as the mark shrinks, from `w10` at
        /// 104 px to `w18` at 15 px. Both sizes drawn here are at the small
        /// end, so the small end's weight is the one taken.
        static let strokeFraction: CGFloat = 16.0 / 82
        /// Diameter of the lavender core dot: the design's `r5`.
        static let coreFraction: CGFloat = 10.0 / 82
        /// Degrees clockwise from three o'clock where the gauge starts. This is
        /// the design's `rotate(132 48 48)`, and section 9.2 calls it out
        /// explicitly as a structural constant rather than sample data.
        static let arcStart: Double = 132
        /// Dash pattern for the track when the reading is unknown, in multiples
        /// of the stroke so it holds at any size. The broken ring is a *shape*
        /// difference from the measured state's continuous one, which is what
        /// lets the two be told apart with the colour removed, and unlike "arc
        /// present or absent" it still holds at a measured zero percent.
        static let unknownDashMultiples: [CGFloat] = [0.9, 1.2]
        /// The lavender core dot. The one part of the mark that is identity
        /// rather than a reading, which is why it is dropped at menu bar size
        /// where every point of width is contested.
        static var core: Color { adaptive(light: 0x8B7BD8, dark: 0xA395E6) }
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

    /// The identity a usage window is painted in.
    ///
    /// The design gives each of the three windows its own gradient rather than
    /// one severity ramp shared between them: the 5-hour hero is coral
    /// (`0xF0B694 \u{2192} 0xD2775A`), the 7-day bar is lavender
    /// (`0xC6BCEC \u{2192} 0x8B7BD8`) and the model-scoped bar is mint
    /// (`0xA8D8C0 \u{2192} 0x5FA37E`). Those are, exactly, the three session
    /// identities above, so this is a lookup rather than a fourth palette.
    ///
    /// Why identity and not severity for the fill: a window is a *place*, and
    /// its colour answers "which of the three limits am I looking at" across a
    /// stack of bars whose lengths are the actual reading. Severity is still
    /// resolved, still rendered, and still the thing the hero states out loud;
    /// it lives in the `\u{2713} Healthy` pill, where it arrives as a glyph, a
    /// word and a tint together. That is the arrangement the design draws and
    /// it is also the one that satisfies "never colour alone": no reader has to
    /// distinguish a coral fill from an amber one to learn anything.
    static func identity(forWindowNamed name: String) -> SessionIdentity {
        switch name {
        case "five_hour": return identities[0]
        case "seven_day": return identities[1]
        default: return identities[2]
        }
    }

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
        /// A card under the pointer. Deeper and further down than the card's
        /// resting shadow, which is what makes it read as *lifted* rather than
        /// as merely darker: a surface that rises casts a longer shadow.
        static var cardHover: ShadowToken { token(radius: 20, y: 16, lightAlpha: 0.26, darkAlpha: 0.5) }
    }

    /// How far a surface rises under the pointer.
    ///
    /// Depth is drawn with a shadow and a translation rather than with a scale.
    /// A scaled card resamples its own text for as long as the pointer is over
    /// it, which is both visibly soft and the only part of a hover that costs
    /// anything; two points of vertical offset costs a compositor move and
    /// reads as the same gesture.
    ///
    /// Everything here is driven by the pointer, so it is motion that exists
    /// only while someone is causing it. That is the distinction the project's
    /// no-repeating-animation rule is actually about: an idle window with no
    /// pointer in it runs nothing.
    enum Elevation {
        /// Vertical rise of a card under the pointer.
        static let cardLift: CGFloat = -2
        /// Vertical rise of a row under the pointer. Smaller, because a row is
        /// one of many and a list that heaved would be worse than a flat one.
        static let rowLift: CGFloat = -1
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
        /// The emphasised span inside a body line: the filename in an activity
        /// line, and nothing else so far. Same size as `body` on purpose, so
        /// the emphasis reads as weight rather than as a second sentence.
        static var bodyEmphasis: Font { .system(size: 12, weight: .semibold) }
        /// A tooltip's title line. HTML 12 px / 700, a step above `bodyEmphasis`
        /// because the bubble's body sits at 0.72 opacity beneath it and the
        /// two have to separate on a dark ground.
        static var tooltipTitle: Font { .system(size: 12, weight: .bold) }
        static var label: Font { .system(size: 11, weight: .semibold) }
        /// Explanatory line under a control. Same size as `label`, lighter, so
        /// the two never compete for the same reading.
        static var help: Font { .system(size: 11, weight: .regular) }
        static var caption: Font { .system(size: 10, weight: .regular) }
        /// Aligned numerals for breakdown tables, paths and byte offsets.
        static var numeric: Font { .system(size: 11, weight: .regular, design: .monospaced) }
        /// The smallest machine value: durations, axis dates, version stamps.
        static var micro: Font { .system(size: 10, weight: .regular, design: .monospaced) }
        /// `micro` at the weight the design gives one cell in a row of them:
        /// the chart's final axis label, which reads `Today`.
        static var microEmphasis: Font { .system(size: 10, weight: .semibold, design: .monospaced) }
        /// Uppercase section header. Pair with `Theme.sectionTracking`.
        static var section: Font { .system(size: 11, weight: .bold) }

        // The cells below were in the design all along and had no constant, so
        // call sites were rounding onto `numeric`, `caption` or `micro` at the
        // wrong size or weight. Each one names where the HTML sets it.

        /// The detail sheet's session name. HTML 19 px / 700 sans.
        static var sheetTitle: Font { .system(size: 19, weight: .bold) }
        /// The dashboard shell's wordmark. HTML 16 px / 700 sans.
        static var windowTitle: Font { .system(size: 16, weight: .bold) }
        /// The detail sheet's grand total. HTML mono 34 px / 600.
        static var sheetTotal: Font { .system(size: 34, weight: .semibold, design: .monospaced) }
        /// A power tube's percentage. HTML mono 20 px / 600.
        static var tubeValue: Font { .system(size: 20, weight: .semibold, design: .monospaced) }
        /// The detail sheet's energy-panel total. HTML mono 16 px / 600.
        static var panelValue: Font { .system(size: 16, weight: .semibold, design: .monospaced) }
        /// A session row's token total. HTML mono 13 px / 600.
        static var rowValue: Font { .system(size: 13, weight: .semibold, design: .monospaced) }
        /// A count pill: the `2` beside ACTIVE SESSIONS. HTML mono 12 px / 600.
        static var countPill: Font { .system(size: 12, weight: .semibold, design: .monospaced) }
        /// A secondary window's name, and a settings row's label.
        /// HTML 13 px / 600 sans.
        static var rowLabel: Font { .system(size: 13, weight: .semibold) }
        /// A label that is doing work: the hero's window name, `Dashboard
        /// \u{2192}`, an action button, the healthy pill. HTML 12 px / 600 sans.
        static var labelEmphasis: Font { .system(size: 12, weight: .semibold) }
        /// An activity event's text in the detail sheet. HTML 12.5 px sans.
        static var eventBody: Font { .system(size: 12.5, weight: .regular) }
        /// A fact tile's value. HTML mono 12.5 px / 500.
        static var factValue: Font { .system(size: 12.5, weight: .medium, design: .monospaced) }
        /// A tool-mix name and count. HTML mono 11.5 px.
        static var toolValue: Font { .system(size: 11.5, weight: .regular, design: .monospaced) }
        /// A fact tile's name, the smallest label in the product.
        /// HTML 10.5 px sans.
        static var tileLabel: Font { .system(size: 10.5, weight: .regular) }
        /// A row's disclosure chevron, which the design sets as the character
        /// `\u{203A}` in the text run rather than as an icon. HTML 13 px sans.
        static var chevron: Font { .system(size: 13, weight: .regular) }
        /// The figure in the popover's today strip. HTML mono 14 px / 600.
        static var stripValue: Font { .system(size: 14, weight: .semibold, design: .monospaced) }
    }

    /// 0.14em at 11 pt, the design's section-eyebrow tracking.
    static let sectionTracking: CGFloat = 1.54

    /// 0.04em at 12 pt, the tracking on the hero's `Claude Power \u{00B7} 5h
    /// window` label. Small enough to be missed and large enough that the label
    /// stops reading as body text, which is the whole job it does.
    static let heroLabelTracking: CGFloat = 0.48

    // MARK: - Glyph vocabulary
    //
    // Every icon in the design is a character. Collected here rather than typed
    // at each call site so a reader can see the whole set at once, and so no
    // view file contains a bare escape sequence whose shape has to be guessed.

    enum Glyph {
        /// Refresh. HTML `\u{27F3}` in the popover header and the dashboard.
        static let refresh = "\u{27F3}"
        /// Row disclosure. HTML `\u{203A}`.
        static let chevron = "\u{203A}"
        /// Navigation out of the popover. HTML `Dashboard \u{2192}`.
        static let arrowRight = "\u{2192}"
        /// Close. HTML `\u{2715}`.
        static let close = "\u{2715}"
        /// The separator between meta values on one line. HTML `\u{00B7}`.
        static let separator = "\u{00B7}"
    }

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
        /// A dashboard power tube. HTML `border-radius: 28px` on a 56 pt wide
        /// column, so the cap is a half-circle rather than a rounded corner.
        static let tube: CGFloat = 28
        /// The dashboard's healthy banner and an action button. HTML 11 px.
        static let banner: CGFloat = 11
        /// A breakdown row's hover target. HTML 9 px.
        static let hoverTarget: CGFloat = 9

        /// A chart column, which the design rounds only at the top.
        /// HTML `border-radius: 10px 10px 4px 4px`.
        enum ChartColumn {
            static let top: CGFloat = 10
            static let bottom: CGFloat = 4
        }
    }

    // MARK: - Bar and ring metrics

    enum Bar {
        /// The hero energy bar in the power meter.
        static let hero: CGFloat = 14
        /// A per-session token bar.
        static let row: CGFloat = 8
        /// The energy bar inside the detail sheet's panel. HTML `height: 12px`
        /// — between the popover row's 8 and the hero's 14, and neither.
        static let sheet: CGFloat = 12
        /// An inline hint bar: a breakdown row, a tool-mix row.
        static let micro: CGFloat = 6

        /// The ring is the Claudence mark, not the meter: the design meters
        /// with bars and tubes and uses the ring as identity. These are the
        /// mark's own geometry, drawn against the design's 96-unit viewBox.
        static let ringSize: CGFloat = 96
        static let ringStroke: CGFloat = 10
        /// The ring mark in the popover header, at the design's 22 px.
        static let markHeader: CGFloat = 22

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
        /// The same rule for a tube, in points rather than as a fraction.
        ///
        /// A tube's fill is clipped to the tube, whose bottom 28 pt is a curve,
        /// so the design's 2% floor - 3.7 pt of 186 - lands where the tube is
        /// still narrowing and reads as a hairline. At 8 pt the clipped fill is
        /// 39 pt of the tube's 56 and reads as a fill. The floor is a display
        /// convention, not a measurement: the percentage above the tube is
        /// always the figure that was actually reported.
        static let minimumVisibleTubeFill: CGFloat = 8
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
        /// How tall the session detail may grow before it scrolls.
        ///
        /// The detail replaces the popover's content rather than floating over
        /// it, so this is also the popover's height while a session is open. A
        /// `ScrollView` has no ideal height and the popover sizes itself to its
        /// content, so without a stated height the two agreed on a strip: the
        /// panel opened a few rows tall with everything else behind a scroll,
        /// on a screen with most of its height unused.
        ///
        /// 620 pt fits under the menu bar on every display this runs on, which
        /// a value tuned to this machine's 1019 pt would not. `RenderableScrollView`
        /// takes the smaller of this and the measured content, so a short
        /// detail still sizes to itself.
        /// How tall the detail's scrolling body may grow before it scrolls.
        ///
        /// One number, because there were two. `RenderableScrollView` was given
        /// 620 here and `SessionDetailView` then clamped the result with
        /// `.frame(maxHeight: 520)`, so the taller sheet asked for was 520 and
        /// the 620 never applied. The header and the action bar are now pinned
        /// outside this, so the figure is the reading area alone.
        static let detailScrollHeight: CGFloat = 560
        /// A tooltip wraps at this width and no wider.
        static let tooltipMaxWidth: CGFloat = 320
        /// The tooltip bubble's own padding. HTML `padding: 11px 13px`, which
        /// is between two steps of the spacing ladder in both directions.
        static let tooltipPaddingVertical: CGFloat = 11
        static let tooltipPaddingHorizontal: CGFloat = 13
    }

    // MARK: - Popover rhythm
    //
    // Design section 3.3, transcribed top to bottom. The popover is the one
    // surface whose vertical rhythm is uneven on purpose, so it gets a table
    // rather than a walk down the `Space` scale: chrome and rules sit on the
    // wide 20 pt gutter while the hero panel and the session cards sit inboard
    // on 14 pt, and that inset is what makes a card read as a card instead of
    // as another band of the popover. Values that coincide with a `Space` step
    // are still spelled out here, because the thing being preserved is the
    // design's table, not an agreement with the scale.

    enum Popover {
        /// Header, dividers, and both strips.
        static let gutter: CGFloat = 20
        /// Hero panel and session list.
        static let margin: CGFloat = 14

        static let headerTop: CGFloat = 16
        static let headerBottom: CGFloat = 12

        static let heroPaddingTop: CGFloat = 18
        static let heroPaddingBottom: CGFloat = 16
        /// Between the hero's top row and its bar.
        static let heroGap: CGFloat = 12

        /// Between the two secondary windows.
        static let secondaryGap: CGFloat = 12
        /// Between a secondary window's baseline row and its track.
        static let secondaryInnerGap: CGFloat = 6
        static let secondaryBottom: CGFloat = 16

        static let sessionsHeaderTop: CGFloat = 14
        static let sessionsHeaderBottom: CGFloat = 10
        /// Between session cards.
        static let listGap: CGFloat = 8
        static let listBottom: CGFloat = 6

        static let rowPaddingVertical: CGFloat = 12
        static let rowPaddingHorizontal: CGFloat = 14
        /// Between the session card's five rows.
        static let rowGap: CGFloat = 9

        static let todayStrip: CGFloat = 13
        static let footerTop: CGFloat = 10
        static let footerBottom: CGFloat = 14
        /// The rule above the sessions header, which the design gives more air
        /// below the list than above the strip.
        static let dividerTop: CGFloat = 8

        // Horizontal rhythm. Every value below is a `gap` or a `padding` read
        // off an inline style in section `1a` of the design file, named for the
        // row it belongs to rather than folded onto the `Space` scale, because
        // the thing being preserved is the design's table.

        /// Ring mark to wordmark, and the session card's header row.
        /// HTML `gap: 9px`.
        static let headerMarkGap: CGFloat = 9
        /// Freshness stamp to refresh button. HTML `gap: 10px`.
        static let headerTrailingGap: CGFloat = 10
        /// The header's refresh button. HTML `width/height: 24px; radius: 8px`.
        static let refreshButton: CGFloat = 24

        /// The hero's label to its reading. HTML `gap: 4px`.
        static let heroLabelGap: CGFloat = 4
        /// Number, unit and pill on the hero's baseline. HTML `gap: 8px`.
        static let heroReadingGap: CGFloat = 8
        /// `Resets in` to its value. HTML `gap: 3px`.
        static let heroResetGap: CGFloat = 3

        /// A scoped window's name to its `weekly scoped` caption.
        /// HTML `gap: 7px`.
        static let secondaryCaptionGap: CGFloat = 7
        /// A secondary window's percentage to its rollover hint.
        /// HTML `gap: 8px`.
        static let secondaryValueGap: CGFloat = 8

        /// A session card's path row. HTML `gap: 8px`.
        static let rowPathGap: CGFloat = 8
        /// A session card's energy row: bar to total. HTML `gap: 10px`.
        static let rowEnergyGap: CGFloat = 10
        /// A session card's meta row: duration, rate, sparkline.
        /// HTML `gap: 14px`, and no separator glyph between them.
        static let rowMetaGap: CGFloat = 14

        /// The today strip's `Today`, figure and caption. HTML `gap: 10px`.
        static let todayGap: CGFloat = 10

        /// A status or severity pill. HTML `padding: 3px 9px` on the hero's
        /// `\u{2713} Healthy` and `3px 8px` on a row's `\u{25CF} Working`; the
        /// wider of the two is used for both, because at these sizes the 1 pt
        /// difference is below what the renderer resolves and two tokens would
        /// only invite one of them to drift.
        static let pillPaddingHorizontal: CGFloat = 9
        static let pillPaddingVertical: CGFloat = 3
        /// The count pill beside ACTIVE SESSIONS. HTML `padding: 2px 9px`.
        static let countPillPaddingHorizontal: CGFloat = 9
        static let countPillPaddingVertical: CGFloat = 2

        /// How often the header's freshness stamp recomputes, in seconds.
        ///
        /// This is the one scheduled repeat in the popover and it is not an
        /// animation. The rule the rest of this file obeys is about a
        /// `.repeatForever` driving a layout pass at the display's refresh
        /// rate, for the life of a process whose content stays mounted; a
        /// `TimelineView` on a five-second period relays one `Text` twelve
        /// times a minute, which is four orders of magnitude less work and is
        /// the only way "30s ago" can be true rather than be the age the
        /// snapshot had when something else last invalidated this view.
        ///
        /// The stamp is rounded to this same period, so every tick changes the
        /// string it draws and none of them is wasted. Nothing animates on it.
        static let freshnessTick: TimeInterval = 5
    }

    // MARK: - Dashboard metrics
    //
    // Transcribed from the `DASHBOARD` block of section `1a`. Held here rather
    // than in the dashboard's own files for the same reason the popover's table
    // is: the numbers are the design's, and a view that spells one out inline
    // is a number nobody can find again.

    enum Dashboard {
        /// HTML `padding: 22px 28px` on the shell header, `22px 28px 28px` on
        /// its body.
        static let headerVertical: CGFloat = 22
        static let horizontal: CGFloat = 28
        static let bodyBottom: CGFloat = 28
        /// Between the shell's stacked sections. HTML `gap: 18px`.
        static let sectionGap: CGFloat = 18
        /// The ring mark in the shell header. HTML `<svg width="30">`.
        static let headerMark: CGFloat = 30

        /// The four stat tiles. HTML `repeat(4, 1fr)`, `gap: 14px`,
        /// `padding: 15px 17px`, `border-radius: 14px`.
        static let statTileGap: CGFloat = 14
        static let statTilePaddingVertical: CGFloat = 15
        static let statTilePaddingHorizontal: CGFloat = 17

        /// The second row: power tubes beside the chart.
        /// HTML `grid-template-columns: 372px 1fr; gap: 18px`.
        static let tubeColumnWidth: CGFloat = 372
        static let rowTwoGap: CGFloat = 18

        /// A sub-card. HTML `padding: 20px; border-radius: 16px;
        /// border: 1px solid 0xEDE6DA; gap: 18px`.
        static let subCardPadding: CGFloat = 20
        static let subCardGap: CGFloat = 18

        /// Between the three tubes. HTML `gap: 10px`, and `gap: 11px` between a
        /// tube and the caption block under it.
        static let tubeGap: CGFloat = 10
        static let tubeCaptionGap: CGFloat = 11

        /// The chart's plot area. HTML `height: 218px`.
        static let chartPlotHeight: CGFloat = 218
        /// A day column. HTML `repeat(7, 1fr)`.
        static let chartColumns = 7

        /// The sessions table.
        /// HTML `grid-template-columns: 1fr 132px 96px 84px; gap: 16px;
        /// padding: 14px 16px; border-radius: 13px`, rows `gap: 10px` apart.
        static let tableTokensColumn: CGFloat = 132
        static let tableRateColumn: CGFloat = 96
        static let tableTrendColumn: CGFloat = 84
        static let tableColumnGap: CGFloat = 16
        static let tableRowGap: CGFloat = 10
        static let tableRowPaddingVertical: CGFloat = 14
        static let tableRowPaddingHorizontal: CGFloat = 16

        /// A dashboard sparkline. HTML `<svg width="84" height="18">`.
        static let sparklineWidth: CGFloat = 84
        static let sparklineHeight: CGFloat = 18

        /// The healthy banner under the tubes.
        /// HTML `padding: 10px 12px; border-radius: 11px`.
        static let bannerPaddingVertical: CGFloat = 10
        static let bannerPaddingHorizontal: CGFloat = 12
    }

    // MARK: - Detail sheet metrics

    enum DetailSheet {
        /// HTML `padding: 24px 26px 18px` on the header,
        /// `20px 26px 26px` on the body, which are `gap: 18px` apart inside.
        static let headerTop: CGFloat = 24
        static let horizontal: CGFloat = 26
        static let headerBottom: CGFloat = 18
        static let bodyTop: CGFloat = 20
        static let bodyBottom: CGFloat = 26
        static let bodyGap: CGFloat = 18
        /// Title block to close button. HTML `gap: 20px`.
        static let headerGap: CGFloat = 20

        /// The hit target of the bar's round controls, back and close alike.
        ///
        /// It was `Theme.Bar.severityGlyph * 2`, which is 22 pt: derived from a
        /// glyph size rather than chosen as a target, and small enough that
        /// both buttons were reported as hard to hit. 28 pt is the smallest
        /// comfortable pointer target on this platform, and the two controls
        /// share it so neither is the fiddly one.
        static let barButtonSize: CGFloat = 28

        /// The glyph inside those controls. `Bar.statusGlyph` is 8 pt, which is
        /// a status dot's size, not a symbol's.
        static let barGlyph: CGFloat = Theme.Bar.severityGlyph

        /// The inset ground of the pinned bars above and below the scroll.
        ///
        /// They carry their own surface because they used to share the sheet's,
        /// which made the title and the action row read as the first and last
        /// items of the scroll rather than as the chrome around it.
        static let barPadding: CGFloat = Theme.Space.l
        static let barRadius: CGFloat = Theme.Radius.panel

        /// The energy panel. HTML `padding: 18px 20px; border-radius: 16px;
        /// background: 0xFAF7F1`.
        static let energyPaddingVertical: CGFloat = 18
        static let energyPaddingHorizontal: CGFloat = 20

        /// The token breakdown's two right-hand columns, both measured rather
        /// than chosen. `194.5M` at 11 pt monospaced is 40.8 pt and `100%` at
        /// caption size is 29.4 pt; these are those figures with a little
        /// slack. Fixed, so the four values and the four shares each line up
        /// into a column a reader can compare down.
        static let breakdownValueColumn: CGFloat = 46
        static let breakdownShareColumn: CGFloat = 34

        /// The subagent list.
        /// HTML `grid-template-columns: 1fr 116px 78px 22px; gap: 14px`.
        static let subagentTokensColumn: CGFloat = 116
        static let subagentShareColumn: CGFloat = 78
        static let subagentChevronColumn: CGFloat = 22
        static let subagentColumnGap: CGFloat = 14
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
        /// The status mark. Sized against the system's own menu bar icons,
        /// which run 15 to 16 pt on macOS 26, rather than against the 8 pt dot
        /// this replaced: at 8 pt the mark was a third the size of everything
        /// beside it, and in the `.minimal` style, where it is the whole label,
        /// it was the only thing there was to aim a click at.
        static let glyphSize: CGFloat = 14
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
        /// A surface answering the pointer. Short, because the gesture has
        /// already happened by the time it is seen and a slow hover feels
        /// like lag rather than like weight.
        static var hover: Animation { eased(0.16) }
        /// A control being pressed. Shorter still.
        static var press: Animation { eased(0.1) }
        /// The chart's columns arriving at their heights, once per series.
        ///
        /// Slower than `grow` and paired with `chartGrowStagger`, because the
        /// columns arrive as a sweep rather than together: the last column
        /// starts after the first has nearly finished, so the eye is led left
        /// to right across the range the chart is drawing.
        static var chartGrow: Animation { eased(0.9) }
        /// The share of the growth animation spent staggering the columns.
        ///
        /// 0 lands them all at once; 1 would leave no time for the last one to
        /// actually move. 0.55 gives the sweep a clear direction and still
        /// leaves every column most of the duration to travel in.
        static let chartGrowStagger: Double = 0.55
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
