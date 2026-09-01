import SwiftUI
import ClaudenceCore

/// Circular variant of `PowerBar`, for the dashboard where there is room for it.
///
/// Same inputs, same thresholds, same refusal to draw an unknown value.
struct EnergyRing: View {
    let title: String
    let percentUsed: Double?
    let resetsAt: Date?
    let size: CGFloat
    let stroke: CGFloat
    let unavailableMessage: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        title: String,
        percentUsed: Double?,
        resetsAt: Date? = nil,
        size: CGFloat = Theme.Bar.ringSize,
        stroke: CGFloat = Theme.Bar.ringStroke,
        unavailableMessage: String = "Usage unavailable"
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
            Text(title)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)

            if let percent = clampedPercent, let severity {
                ring(percent: percent, severity: severity)
                if let time = Format.timeUntil(resetsAt) {
                    Text("Reset in \(time)")
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
        .accessibilityLabel(spokenLabel)
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
                .animation(
                    Theme.animation(Theme.Motion.valueChange, reduceMotion: reduceMotion),
                    value: percent
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
                Text(Theme.name(for: severity))
                    .font(Theme.Typography.caption)
            }
            .foregroundStyle(Theme.color(for: severity))
            .lineLimit(1)
        }
        // Keep the label inside the inner circle at any ring size.
        .frame(width: max(0, size - stroke * 3))
    }

    private var spokenLabel: String {
        guard let percent = clampedPercent, let severity else {
            return "\(title). \(unavailableMessage)."
        }
        var parts = ["\(title). \(Format.percent(percent)) used. \(Theme.name(for: severity))."]
        if let time = Format.timeUntil(resetsAt) {
            parts.append("Resets in \(time).")
        }
        return parts.joined(separator: " ")
    }
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
