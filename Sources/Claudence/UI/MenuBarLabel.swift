import SwiftUI
import ClaudenceCore

/// Menu bar rendering. Width is a hard constraint: the menu bar is shared and
/// narrow on a single display, and `Constants.Performance.maxMenuBarWidth` (60
/// pt) is a real requirement, not a suggestion. See spec section 7.1 and design
/// section 5.1.
///
/// Meaning is never carried by colour alone. Two redundant cues do that work and
/// both survive every style:
///
/// - the mark's silhouette is whole for a measured value and broken for an
///   unknown one, so "usage unavailable" is legible without reading a number or
///   seeing a hue;
/// - the reading itself is a number or a word, and the accessibility label spells
///   out the percentage and the session count in full regardless of which style
///   is showing.
///
/// ## The mark, and what happened to the hollow dot
///
/// The dot became the ring mark, which is the same glyph the popover header
/// carries and the design's own gauge: the arc length is the 5-hour reading.
/// The unknown state used to be the hollow dot against the measured state's
/// filled one. It is now a *broken* ring, dashed all the way round, against a
/// measured reading's continuous one. "Arc drawn" against "no arc" would have
/// been the obvious swap and is wrong: a measured zero percent also draws no
/// arc, so the two honest states would have shared one silhouette.
///
/// The design wraps the label in a translucent pill, `padding: 4px 10px`. That
/// pill is not reproduced. It costs 20 pt of a 60 pt budget to draw a shape the
/// real menu bar already provides, and it would push the common reading into
/// the shrink described below for decoration. The mark is drawn at the dot's
/// own 8 pt, so the measurements below stand as an upper bound rather than
/// needing to be retaken.
///
/// ## Fitting `combined` into 60 pt
///
/// Re-measured with `NSString.size(withAttributes:)` after the reading moved
/// from the system font with monospaced digits onto SF Mono proper, which is
/// what every other machine-derived value in the product is set in. SF Mono is
/// *narrower* than the system font here, so the headroom went up rather than
/// down. Totals below add the 14 pt ring mark and the 3 pt gap beside it. The
/// mark was 8 pt when these were first taken; the 6 pt it grew by is carried
/// straight through, and `Theme.MenuBar.glyphSize` says why it grew.
///
/// ```
/// "100%"      12 pt   46.7 pt total   widest .usage reading
/// "12"        12 pt   31.8 pt total   widest plausible .sessions reading
/// "2\u{00B7}24%"     12 pt   54.1 pt total   an ordinary .combined reading
/// "12\u{00B7}100%"   12 pt   68.9 pt total   widest plausible .combined reading, over budget
/// "12\u{00B7}100%"   9.6 pt  58.5 pt total   the same reading at the shrink floor
/// ```
///
/// So the count and the percentage together still do **not** fit at the shared
/// 12 pt once the count reaches two digits and the window is near full, though
/// the overflow is 8.9 pt. Two ways out were available: shrink the whole
/// style, which makes every everyday reading harder to read to buy
/// headroom for a rare one; or let the label shrink only when it has to. The
/// second is what ships. `minimumScaleFactor(0.8)` allows 9.6 pt, which is
/// comfortably past what the widest reading needs, so "2\u{00B7}24%" renders at
/// full size and "12\u{00B7}100%" tightens instead of truncating. Truncation was
/// never an option: a clipped percentage is a wrong number, and this project
/// treats a wrong number as a defect.
///
/// The separator is a tight middle dot rather than the design's spaced
/// `2 \u{00B7} 24%`. The two spaces cost 6.5 pt, which is the difference between
/// the common case rendering at full size and rendering shrunk.
struct MenuBarLabel: View {
    let model: MonitorViewModel

    /// Optional so `ClaudenceApp` compiles whether or not it has been wired yet.
    /// Absent, the label renders `.usage`, which is what it has always rendered.
    var preferences: Preferences?

    @Environment(\.appLanguage) private var language

    var body: some View {
        HStack(spacing: Theme.MenuBar.glyphGap) {
            // An image, not the `RingMark` view. Shapes render as nothing
            // inside a `MenuBarExtra` label; see `MenuBarMark` for the
            // measurement and for what that cost in the `.minimal` style.
            Image(nsImage: mark)
            if let reading {
                Text(reading)
                    // Mono, not the system font with monospaced digits. The
                    // design sets this reading in IBM Plex Mono at 600, and the
                    // project's own convention is that anything derived from
                    // the machine is mono; `monospacedDigit()` gave stable
                    // digit widths but left the `%` and the separator in the
                    // proportional face, which is a different typeface from
                    // every other percentage in the product.
                    .font(
                        .system(
                            size: Theme.MenuBar.textSize,
                            weight: .semibold,
                            design: .monospaced
                        )
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(Theme.MenuBar.minimumScaleFactor)
            }
        }
        .frame(maxWidth: Constants.Performance.maxMenuBarWidth)
        .accessibilityElement(children: .ignore)
        // Spoken and drawn have to agree. The switch is there so nothing about
        // usage is legible from the menu bar, and a label that reads the
        // percentage aloud is the same leak through a different channel.
        .accessibilityLabel(
            isQuiet
                ? Strings.liveReadingOff.string(in: language)
                : model.menuBarAccessibilityLabel
        )
    }

    /// The glyph, drawn into an image because a `Shape` is not carried
    /// through to the menu bar. See `MenuBarMark`.
    private var mark: NSImage {
        if isQuiet {
            return MenuBarMark.quiet(size: Theme.MenuBar.glyphSize)
        }
        return MenuBarMark.gauge(
            percentUsed: model.primaryWindow?.usedPercent,
            size: Theme.MenuBar.glyphSize,
            arcColor: glyphColor,
            // The design's own track is its arc colour at 28%. Taking the
            // track from the arc rather than from `Theme.track` is what keeps
            // the mark visible on a strip this application does not paint and
            // whose appearance it does not control.
            trackColor: glyphColor.opacity(0.28)
        )
    }

    // MARK: - Reading

    private var style: MenuBarStyle {
        preferences?.effectiveMenuBarStyle ?? .usage
    }

    /// The user turned the live reading off.
    ///
    /// Read from the switch itself rather than from `effectiveMenuBarStyle`,
    /// which collapses it onto `.minimal`. That collapse was the bug: `.minimal`
    /// is a *chosen* reading -- the severity ring with no text -- so turning the
    /// switch off left the arc and its severity colour on the menu bar, and the
    /// setting whose whole promise is "nothing about your usage is legible over
    /// your shoulder" changed nothing but the digits.
    private var isQuiet: Bool {
        preferences?.showMenuBarUsage == false
    }

    /// nil means the glyph stands alone.
    private var reading: String? {
        switch style {
        case .minimal:
            return nil
        case .usage:
            // The view model already owns this fallback chain, so the percentage
            // reading has one definition rather than two that can drift.
            return model.menuBarText
        case .sessions:
            return "\(model.activeCount)"
        case .combined:
            // An unmeasured window contributes nothing rather than a placeholder.
            // The hollow glyph is already saying the percentage is unknown, and
            // a second marker for it would only spend width.
            guard let percent = model.primaryWindow?.usedPercent else {
                return "\(model.activeCount)"
            }
            return "\(model.activeCount)\u{00B7}\(Format.percent(percent))"
        }
    }

    // MARK: - Glyph

    /// The mark's ink: a continuous walk along the severity ramp, mint through
    /// amber and burnt orange to deep red, positioned by the same percentage
    /// the arc length is drawing.
    ///
    /// Continuous rather than the four discrete tokens, because the mark is a
    /// gauge and the steps made it lie about its own resolution: the arc grows
    /// smoothly while the ink jumped at boundaries the user cannot see, so the
    /// jump read as an event. See `Theme.severityRamp(percent:)` for where the
    /// stops sit and why they land exactly on the thresholds.
    ///
    /// Unmeasured is not a point on the ramp and never gets one. It draws the
    /// neutral ink, and `MenuBarMark` turns that into a template so the system
    /// tints it; the broken ring is already saying by its shape that there is
    /// no reading, and putting it anywhere on a mint-to-red scale would be
    /// answering a question that has no answer.
    private var glyphColor: Color {
        guard let percent = model.primaryWindow?.usedPercent else { return Theme.textSecondary }
        return Theme.severityRamp(percent: percent)
    }
}

private enum Strings {
    static let liveReadingOff = Phrase(en: "Claudence, live reading off", th: "Claudence ปิดการอ่านค่าสด")
}
