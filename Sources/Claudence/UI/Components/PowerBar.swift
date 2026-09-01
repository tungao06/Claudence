import SwiftUI
import ClaudenceCore

/// The hero element: a horizontal energy bar for one usage window.
///
/// Sessions are machines, tokens are energy, and this is the battery. It is the
/// first thing read in the popover and carries the most visual weight of any
/// component. See spec sections 1.3 and 7.2.
struct PowerBar: View {
    /// Window name, e.g. "Claude Power" or `UsageWindow.displayName`.
    let title: String
    /// Percent of the window consumed. Nil means the value is not known and the
    /// bar refuses to draw rather than inventing a fill.
    let percentUsed: Double?
    /// When the window rolls over, if the source reported it.
    let resetsAt: Date?
    /// Bar thickness. Defaults to the hero size.
    let height: CGFloat
    /// Message shown in place of the bar when `percentUsed` is nil.
    let unavailableMessage: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        title: String,
        percentUsed: Double?,
        resetsAt: Date? = nil,
        height: CGFloat = Theme.Bar.hero,
        unavailableMessage: String = "Usage unavailable"
    ) {
        self.title = title
        self.percentUsed = percentUsed
        self.resetsAt = resetsAt
        self.height = height
        self.unavailableMessage = unavailableMessage
    }

    // Clamped so a source reporting 104% or -1% cannot break the layout.
    private var clampedPercent: Double? {
        percentUsed.map { min(100, max(0, $0)) }
    }

    private var severity: Severity? {
        clampedPercent.map { Constants.UsageThreshold.severity(forPercent: $0) }
    }

    private var resetCaption: String? {
        Format.timeUntil(resetsAt).map { "Reset in \($0)" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            header
            if let percent = clampedPercent, let severity {
                fill(percent: percent, severity: severity)
                if let resetCaption {
                    Text(resetCaption)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            } else {
                UnavailableView(unavailableMessage)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(title)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Theme.Space.xs)
            if let severity {
                // Glyph plus number: never colour alone.
                Image(systemName: Theme.glyph(for: severity))
                    .font(.system(size: Theme.Bar.severityGlyph))
                    .foregroundStyle(Theme.color(for: severity))
                Text(Format.percent(clampedPercent))
                    .font(Theme.Typography.value)
                    .foregroundStyle(Theme.textPrimary)
            } else {
                Text(Format.percent(nil))
                    .font(Theme.Typography.value)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func fill(percent: Double, severity: Severity) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Theme.track)
                Capsule(style: .continuous)
                    .fill(Theme.color(for: severity))
                    // A non-zero reading always shows at least a dot, so 0.4%
                    // is visibly different from 0%. Exactly zero draws nothing.
                    .frame(width: percent <= 0 ? 0 : max(height, geo.size.width * percent / 100))
            }
        }
        .frame(height: height)
        .animation(Theme.animation(Theme.Motion.valueChange, reduceMotion: reduceMotion), value: percent)
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
