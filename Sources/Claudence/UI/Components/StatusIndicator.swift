import SwiftUI
import ClaudenceCore

/// A session's state as a glyph plus a word.
///
/// Three states have a proven data source: running, idle, completed. The other
/// three exist in the provider contract but nothing can derive them yet, so
/// they render an explicit fallback instead of a state we cannot prove.
/// Designing UI for a state with no source produces a display that silently
/// lies. See spec section 6.
struct StatusIndicator: View {
    let status: SessionStatus
    let showsText: Bool
    let glyphSize: CGFloat
    /// Changes when the session did something. Each change fires one dip.
    /// Nil means the caller has nothing to report, and the glyph never moves.
    let activityToken: AnyHashable?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    init(
        _ status: SessionStatus,
        showsText: Bool = true,
        glyphSize: CGFloat = Theme.Bar.statusGlyph,
        activityToken: AnyHashable? = nil
    ) {
        self.status = status
        self.showsText = showsText
        self.glyphSize = glyphSize
        self.activityToken = activityToken
    }

    /// Only an active state pulses, and never under Reduce Motion. Motion here
    /// means "this just happened", nothing else.
    private var mayPulse: Bool {
        status == .running && !reduceMotion && activityToken != nil
    }

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: Theme.glyph(for: status))
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(Theme.color(for: status))
                .opacity(isPulsing ? Theme.Motion.pulseMinOpacity : 1)
                .animation(Theme.animation(Theme.Motion.pulse, reduceMotion: reduceMotion), value: isPulsing)
            if showsText {
                Text(Theme.name(for: status))
                    .font(Theme.Typography.label)
                    .foregroundStyle(status.isDerivable ? Theme.textSecondary : Theme.textTertiary)
                    .lineLimit(1)
            }
        }
        // One dip per observed change, then still. Nothing repeats, so an idle
        // popover — mounted but invisible, which is its normal state — costs
        // nothing. See Theme.Motion.pulse for the measurement that forced this.
        .task(id: activityToken) {
            guard mayPulse else {
                isPulsing = false
                return
            }
            isPulsing = true
            try? await Task.sleep(for: .milliseconds(550))
            isPulsing = false
        }
        // Turning Reduce Motion on mid-run snaps the glyph back to full opacity.
        .task(id: reduceMotion) {
            if reduceMotion { isPulsing = false }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    private var spokenLabel: String {
        guard status.isDerivable else {
            return "Session state unsupported. No data source reports this state."
        }
        return Theme.name(for: status)
    }
}
