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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    init(
        _ status: SessionStatus,
        showsText: Bool = true,
        glyphSize: CGFloat = Theme.Bar.statusGlyph
    ) {
        self.status = status
        self.showsText = showsText
        self.glyphSize = glyphSize
    }

    /// Only an active state pulses, and never under Reduce Motion. Motion here
    /// means "this is happening right now", nothing else.
    private var shouldPulse: Bool {
        status == .running && !reduceMotion
    }

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: Theme.glyph(for: status))
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(Theme.color(for: status))
                .opacity(isPulsing ? Theme.Motion.pulseMinOpacity : 1)
                .animation(shouldPulse ? Theme.Motion.pulse : nil, value: isPulsing)
            if showsText {
                Text(Theme.name(for: status))
                    .font(Theme.Typography.label)
                    .foregroundStyle(status.isDerivable ? Theme.textSecondary : Theme.textTertiary)
                    .lineLimit(1)
            }
        }
        // Recomputed whenever Reduce Motion changes, so switching it on mid-run
        // stops the pulse immediately and snaps the glyph back to full opacity.
        .task(id: shouldPulse) {
            isPulsing = shouldPulse
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
