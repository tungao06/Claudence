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
    ///
    /// Callers pass a coarse token, not a raw timestamp. A transcript event
    /// arrives about four times a second while a session streams, and a token
    /// that changed that often restarted the 0.55 s dip before it could finish,
    /// so `isPulsing` never returned to false and the glyph sat permanently
    /// dimmed. See `SessionRow.activityToken`.
    let activityToken: AnyHashable?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The user's `Live indicators` setting. Off means the glyph never moves,
    /// whatever the session is doing.
    ///
    /// Read from the environment rather than taken as a parameter. There used
    /// to be both: the popover threaded the preference down through
    /// `SessionRow` while the dashboard's own status pill omitted the argument
    /// and got the default, so the same switch stilled one surface and not the
    /// other. One delivery path cannot disagree with itself.
    @Environment(\.liveIndicators) private var liveIndicators
    @Environment(\.appLanguage) private var language
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
        status == .running && liveIndicators && !reduceMotion && activityToken != nil
    }

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: Theme.glyph(for: status))
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(Theme.color(for: status))
                .opacity(isPulsing ? Theme.Motion.pulseMinOpacity : 1)
                .animation(Theme.animation(Theme.Motion.pulse, reduceMotion: reduceMotion), value: isPulsing)
            if showsText {
                PhraseText(Theme.namePhrase(for: status))
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
        .accessibilityLabel(spokenLabel, in: language)
    }

    private var spokenLabel: Phrase {
        guard status.isDerivable else {
            return Phrase(
                en: "Session state unsupported. No data source reports this state.",
                th: "ไม่รองรับสถานะ session นี้ ไม่มีแหล่งข้อมูลใดรายงานสถานะนี้"
            )
        }
        return Theme.namePhrase(for: status)
    }
}
