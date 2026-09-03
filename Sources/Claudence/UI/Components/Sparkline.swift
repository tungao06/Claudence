import SwiftUI
import ClaudenceCore

/// A quiet micro-chart. No axes, no labels, no grid.
///
/// Secondary by design: it hints at a shape over time and never competes with
/// the power meter. Fewer than two points renders nothing at all, because a
/// single point has no trend and a zero-width path is a broken shape, not a
/// chart. See spec section 5.4.
struct Sparkline: View {
    enum Style {
        case line
        case bar
    }

    let values: [Double]
    let style: Style
    let height: CGFloat
    /// The stroke, or the bar fill.
    ///
    /// The design strokes each sparkline in the light stop of its row's own
    /// identity: `0xE0A487` on a coral session, `0xA99BE0` on a lavender one.
    /// `Theme.SessionIdentity.sparkline` has held exactly those two values
    /// since the palette was transcribed and had no consumer, because this
    /// parameter did not exist and every chart was drawn in `textTertiary`.
    /// The default stays neutral for the callers that have no identity to hand.
    let stroke: Color
    /// What the series measures, used in the spoken label, e.g. "Token rate".
    /// Spoken, so translated: this is the first thing VoiceOver says about the
    /// chart and it is the only thing that names what the numbers are.
    let label: Phrase

    @Environment(\.appLanguage) private var language

    /// The two labels this component's callers actually pass, kept here so a
    /// row and a table cell drawing the same series cannot name it differently.
    static let trend = Phrase(en: "Trend", th: "แนวโน้ม")
    static let tokenRate = Phrase(en: "Token rate", th: "อัตรา token")

    init(
        _ values: [Double],
        style: Style = .line,
        height: CGFloat = Theme.Bar.sparklineHeight,
        stroke: Color = Theme.textTertiary,
        label: Phrase = Sparkline.trend
    ) {
        self.values = values
        self.style = style
        self.height = height
        self.stroke = stroke
        self.label = label
    }

    /// Whether a series has enough points to be a trend at all. Exposed so a
    /// container can decide not to reserve space for a chart that will not draw.
    static func canRender(_ values: [Double]) -> Bool { values.count >= 2 }

    private var isRenderable: Bool { Sparkline.canRender(values) }

    var body: some View {
        if isRenderable {
            GeometryReader { geo in
                switch style {
                case .line:
                    linePath(in: geo.size)
                        .stroke(
                            stroke,
                            style: StrokeStyle(
                                lineWidth: Theme.Bar.sparklineStroke,
                                lineCap: .round,
                                lineJoin: .round
                            )
                        )
                case .bar:
                    bars(in: geo.size)
                }
            }
            .frame(height: height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenLabel)
        }
        // Nothing to draw: emit nothing rather than an empty frame that reads
        // as a measured flat line.
    }

    // MARK: - Geometry

    private var bounds: (min: Double, max: Double) {
        let lo = values.min() ?? 0
        let hi = values.max() ?? 0
        return (lo, hi)
    }

    /// Normalised vertical position, 0 at the top of the box.
    private func normalised(_ value: Double) -> Double {
        let (lo, hi) = bounds
        let span = hi - lo
        // A flat series is a real result: draw it down the middle, not at zero.
        guard span > 0 else { return 0.5 }
        return 1 - (value - lo) / span
    }

    private func linePath(in size: CGSize) -> Path {
        // Inset by the stroke radius so the top and bottom of the line are not
        // clipped by the frame.
        let inset = Theme.Bar.sparklineStroke / 2
        let usableHeight = max(0, size.height - inset * 2)
        let step = values.count > 1 ? size.width / Double(values.count - 1) : 0
        var path = Path()
        for (index, value) in values.enumerated() {
            let point = CGPoint(
                x: step * Double(index),
                y: inset + normalised(value) * usableHeight
            )
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    private func bars(in size: CGSize) -> some View {
        let count = Double(values.count)
        let spacing = min(2, max(0.5, size.width / count * 0.25))
        let barWidth = max(0.5, (size.width - spacing * (count - 1)) / count)
        return HStack(alignment: .bottom, spacing: spacing) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Capsule(style: .continuous)
                    .fill(stroke)
                    // Always at least a hairline so a low sample is visible.
                    .frame(
                        width: barWidth,
                        height: max(1, (1 - normalised(value)) * size.height)
                    )
            }
        }
        // A dense series can be wider than the box. Anchor to the trailing
        // edge and clip, so what survives is the most recent window rather than
        // a squashed or overflowing chart.
        .frame(width: size.width, height: size.height, alignment: .bottomTrailing)
        .clipped()
    }

    // MARK: - Accessibility

    private var spokenLabel: String {
        let (lo, hi) = bounds
        let latest = values.last ?? 0
        return Self.spoken.format(
            in: language,
            label.string(in: language),
            "\(values.count)",
            describe(latest),
            describe(lo),
            describe(hi)
        )
    }

    private static let spoken = Phrase(
        en: "%@. %@ samples. Latest %@. Range %@ to %@.",
        th: "%@ %@ ตัวอย่าง ล่าสุด %@ ช่วง %@ ถึง %@"
    )

    private func describe(_ value: Double) -> String {
        Format.tokens(Int(value.rounded()))
    }
}
