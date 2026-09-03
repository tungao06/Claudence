import SwiftUI
import ClaudenceCore

/// Circular variant of `PowerBar`, for the dashboard where there is room for it.
///
/// Same inputs, same thresholds, same refusal to draw an unknown value.
struct EnergyRing: View {
    let title: Phrase
    let percentUsed: Double?
    let resetsAt: Date?
    let size: CGFloat
    let stroke: CGFloat
    let unavailableMessage: Phrase

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.liveIndicators) private var liveIndicators
    @Environment(\.appLanguage) private var language

    /// For a caller that has not yet converted its own strings to `Phrase`.
    /// See `PowerHero`'s own note for why this keeps the default and the
    /// `Phrase` overload does not.
    init(
        title: String,
        percentUsed: Double?,
        resetsAt: Date? = nil,
        size: CGFloat = Theme.Bar.ringSize,
        stroke: CGFloat = Theme.Bar.ringStroke,
        unavailableMessage: String = "Usage unavailable"
    ) {
        self.title = .untranslated(title)
        self.percentUsed = percentUsed
        self.resetsAt = resetsAt
        self.size = size
        self.stroke = stroke
        self.unavailableMessage = .untranslated(unavailableMessage)
    }

    init(
        title: Phrase,
        percentUsed: Double?,
        resetsAt: Date? = nil,
        size: CGFloat = Theme.Bar.ringSize,
        stroke: CGFloat = Theme.Bar.ringStroke,
        unavailableMessage: Phrase = UnavailableView.usageUnavailable
    ) {
        self.title = title
        self.percentUsed = percentUsed
        self.resetsAt = resetsAt
        self.size = size
        self.stroke = stroke
        self.unavailableMessage = unavailableMessage
    }

    private var clampedPercent: Double? {
        percentUsed.map { min(100, max(0, $0)) }
    }

    private var severity: Severity? {
        clampedPercent.map { Constants.UsageThreshold.severity(forPercent: $0) }
    }

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            PhraseText(title)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)

            if let percent = clampedPercent, let severity {
                ring(percent: percent, severity: severity)
                if let time = Format.timeUntil(resetsAt) {
                    PhraseText(Strings.resetIn, time)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            } else {
                // No fill, no dimmed placeholder ring: an empty track would read
                // as zero percent, which is a number we do not have.
                UnavailableView(unavailableMessage)
                    .frame(width: size)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel, in: language)
    }

    private func ring(percent: Double, severity: Severity) -> some View {
        ZStack {
            RingArc()
                .stroke(Theme.track, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
            RingArc()
                .trim(from: 0, to: percent / 100)
                .stroke(
                    Theme.color(for: severity),
                    style: StrokeStyle(lineWidth: stroke, lineCap: .round)
                )
                // Quantised to whole percent, like `RingMark` below and like
                // every bar fill in the product. `percent` is clamped but not
                // rounded, and the usage poll moves it far more often than the
                // arc can visibly move; animating on the raw value restarts a
                // 0.35 s interpolation before the previous one finishes, so it
                // never finishes.
                .animation(
                    Theme.valueAnimation(reduceMotion: reduceMotion, liveIndicators: liveIndicators),
                    value: percent.rounded()
                )
            centre(percent: percent, severity: severity)
        }
        // Inset by half the stroke so the round cap is not clipped by the frame.
        .padding(stroke / 2)
        .frame(width: size, height: size)
    }

    private func centre(percent: Double, severity: Severity) -> some View {
        VStack(spacing: Theme.Space.xxs) {
            Text(Format.percent(percent))
                .font(Theme.Typography.hero)
                .foregroundStyle(Theme.textPrimary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            HStack(spacing: Theme.Space.xxs) {
                Image(systemName: Theme.glyph(for: severity))
                    .font(.system(size: Theme.Bar.statusGlyph))
                PhraseText(Theme.namePhrase(for: severity))
                    .font(Theme.Typography.caption)
            }
            .foregroundStyle(Theme.color(for: severity))
            .lineLimit(1)
        }
        // Keep the label inside the inner circle at any ring size.
        .frame(width: max(0, size - stroke * 3))
    }

    private var spokenLabel: Phrase {
        guard let percent = clampedPercent, let severity else {
            return Phrase(
                en: "\(title.en). \(unavailableMessage.en).",
                th: "\(title.th) \(unavailableMessage.th)"
            )
        }
        let usedPercent = Format.percent(percent)
        let name = Theme.namePhrase(for: severity)
        var en = "\(title.en). \(usedPercent) used. \(name.en)."
        var th = "\(title.th) ใช้ไป \(usedPercent) \(name.th)"
        if let time = Format.timeUntil(resetsAt) {
            en += " Resets in \(time)."
            th += " รีเซ็ตใน \(time)"
        }
        return Phrase(en: en, th: th)
    }
}

/// Words this file glues around a caller's own numbers.
private enum Strings {
    static let resetIn = Phrase(en: "Reset in %@", th: "รีเซ็ตใน %@")
}

/// A full circle drawn as an explicit path so `trim` starts at twelve o'clock
/// and runs clockwise, which is how a meter is read.
private struct RingArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(rect.width, rect.height) / 2
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: radius,
            startAngle: .degrees(-90),
            endAngle: .degrees(270),
            clockwise: false
        )
        return path
    }
}

// MARK: - Ring mark

/// The Claudence glyph: the product's mark and its 5-hour reading at once.
///
/// It appears twice, in the menu bar label and in the popover header, and both
/// are the same gauge at different sizes. Geometry is the design's, section
/// 3.7: an arc of radius 33 in a 96 box, starting at 132 degrees clockwise from
/// three o'clock, sized here against its outer extent so a caller asks for the
/// space it will occupy rather than for a box it will sit inside.
///
/// Two things the design does that this does not.
///
/// The arc breathes, `arcHeadBreathe`, 4.5 s infinite, and it is applied to the
/// menu bar label, which is mounted for the entire life of the process. That is
/// the exact shape of the defect that cost 6.9% of a core here. The arc is
/// static and moves only when the reading does.
///
/// The mark with no reading in it at all: a plain, continuous ring in neutral
/// ink, drawn when the user has turned the menu bar reading off.
///
/// A third silhouette, and it has to be. `RingMark` already spends both of its
/// own: an arc over a continuous track is a measured reading, and a broken ring
/// is one that could not be measured. Reusing either here would say something
/// untrue -- that the usage is zero, or that it is unknown -- when the truth is
/// that the user asked not to be shown it. Nothing about the window reaches this
/// view, so there is no reading to leak whatever the severity behind it.
struct QuietMark: View {
    let size: CGFloat
    var color: Color = Theme.textSecondary

    private var stroke: CGFloat { size * Theme.Mark.strokeFraction }

    var body: some View {
        Circle()
            .strokeBorder(color, lineWidth: stroke)
            .padding(stroke / 2)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The design also draws no unknown state at all, so this one is ours. A
/// measured reading draws a continuous track with the arc laid over it; an
/// unknown one draws the track *broken*, as a dashed circle, with no arc. The
/// difference is a silhouette rather than a hue, which is what the filled and
/// hollow dots this replaces were for. It was tempting to say "arc present" and
/// "arc absent" instead, and that fails: a measured zero percent draws no arc
/// either, so the two honest states would have collapsed into one shape.
struct RingMark: View {
    /// Nil is the unknown reading, and draws a broken ring rather than an
    /// empty one. An empty track would read as a measured zero.
    let percentUsed: Double?
    /// Outer diameter of the mark.
    let size: CGFloat
    /// Arc colour. The caller owns this because the two call sites answer
    /// different questions with it: the menu bar carries the window's severity,
    /// the popover header carries the brand accent.
    let arcColor: Color
    /// The unfilled ring. Also the caller's, and for a harder reason than the
    /// arc's: the menu bar is not painted by this application, so `Theme.track`
    /// there is a cream hairline on a cream strip and the mark would vanish.
    let trackColor: Color
    /// The lavender core dot. Off at menu bar size, where the design drops it.
    let showsCore: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.liveIndicators) private var liveIndicators

    init(
        percentUsed: Double?,
        size: CGFloat,
        arcColor: Color = Theme.accent,
        trackColor: Color = Theme.track,
        showsCore: Bool = false
    ) {
        self.percentUsed = percentUsed
        self.size = size
        self.arcColor = arcColor
        self.trackColor = trackColor
        self.showsCore = showsCore
    }

    private var stroke: CGFloat { size * Theme.Mark.strokeFraction }

    /// Clamped so a source reporting 104% cannot wrap the arc past its start.
    private var fraction: Double? {
        percentUsed.map { min(1, max(0, $0 / 100)) }
    }

    var body: some View {
        ZStack {
            track
            if let fraction {
                GaugeArc()
                    .trim(from: 0, to: fraction)
                    .stroke(arcColor, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    // Quantised to whole percent, like every other fill in the
                    // product: the raw value moves far more often than the arc
                    // can visibly move, and an animation restarted before it
                    // finishes never finishes.
                    .animation(
                        Theme.valueAnimation(reduceMotion: reduceMotion, liveIndicators: liveIndicators),
                        value: (fraction * 100).rounded()
                    )
            }
            if showsCore {
                Circle()
                    .fill(Theme.Mark.core)
                    .frame(width: size * Theme.Mark.coreFraction)
            }
        }
        // The path is drawn on the centreline of the stroke, so half of it
        // falls outside the arc's radius and has to be paid for here.
        .padding(stroke / 2)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var track: some View {
        if fraction == nil {
            // The broken ring is drawn in the arc's ink rather than the track's.
            // It is the only mark on screen in this state, so it has to be as
            // legible as a reading would have been; the track's job of sitting
            // behind something does not exist here.
            GaugeArc().stroke(
                arcColor,
                style: StrokeStyle(
                    lineWidth: stroke,
                    lineCap: .butt,
                    dash: Theme.Mark.unknownDashMultiples.map { $0 * stroke }
                )
            )
        } else {
            GaugeArc().stroke(trackColor, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
        }
    }
}

/// The mark's circle, started where the design starts it so `trim` runs from
/// the gauge's zero rather than from twelve o'clock.
private struct GaugeArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: min(rect.width, rect.height) / 2,
            startAngle: .degrees(Theme.Mark.arcStart),
            endAngle: .degrees(Theme.Mark.arcStart + 360),
            clockwise: false
        )
        return path
    }
}
