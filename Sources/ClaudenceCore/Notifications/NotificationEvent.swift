import Foundation

/// The complete set of things Claudence will interrupt a human for.
///
/// Spec section 10 lists four events. Only two of them ship:
///
/// - `Permission required` is excluded because `SessionStatus.permission`
///   returns `false` from `isDerivable`; section 6 records that no data source
///   produces it. A notification case for a state nothing can emit is code that
///   can never fire.
/// - `Session failed` is excluded for the same reason. `SessionStatus.error` is
///   not derivable, and the registry carries no exit condition: a session that
///   crashed and a session that finished cleanly both leave by having their
///   `~/.claude/sessions/<pid>.json` file removed. There is no exit code, no
///   signal, and no terminal status string anywhere in the snapshot, so
///   "failed" cannot be told apart from "completed" without fabricating it.
///
/// Both come back the moment a source is proven, and the throttle and deriver
/// need no change to carry them.
public enum NotificationEvent: Sendable, Equatable {
    /// A usage window crossed `Constants.UsageThreshold.critical` upward.
    case usageThreshold(window: UsageWindow)
    /// A session that was being monitored is gone and its absence is confirmed.
    case sessionCompleted(session: AISession)

    // MARK: - Identity

    /// Coarse type, used as half of the throttle key. Separate from the payload
    /// so two different windows do not suppress each other.
    public enum Kind: String, Sendable, CaseIterable {
        case usageThreshold
        case sessionCompleted
    }

    public var kind: Kind {
        switch self {
        case .usageThreshold: return .usageThreshold
        case .sessionCompleted: return .sessionCompleted
        }
    }

    /// The subject the event is about: a window name or a session id.
    public var subjectID: String {
        switch self {
        case .usageThreshold(let window): return window.name
        case .sessionCompleted(let session): return session.id
        }
    }

    /// `(kind, subject)`. Deduplication and rate limiting are both per key, so
    /// a noisy five-hour window can never mute a session completion.
    public var throttleKey: String { "\(kind.rawValue):\(subjectID)" }

    // MARK: - Wording

    /// Titles come from the spec section 10 table verbatim. They name the event,
    /// not the instance, so Notification Center groups them sensibly.
    public var title: String {
        switch self {
        case .usageThreshold: return "Usage at 90%"
        case .sessionCompleted: return "Session completed"
        }
    }

    /// Plain English, and never a fabricated number: anything the snapshot did
    /// not supply is simply left out of the sentence rather than defaulted.
    /// See spec section 9.4.
    public func body(now: Date = Date()) -> String {
        switch self {
        case .usageThreshold(let window):
            var sentence = "\(window.displayName) window: "
            if let remaining = window.remainingPercent {
                // "About" is load-bearing. The API reports a rounded percentage
                // and the window keeps moving while the notification is queued.
                sentence += "about \(Format.percent(remaining)) left."
            } else {
                sentence += "limit reached."
            }
            if let until = Format.timeUntil(window.resetsAt, now: now) {
                sentence += " Resets in \(until)."
            }
            return sentence

        case .sessionCompleted(let session):
            let elapsed = max(0, session.lastActivityAt.timeIntervalSince(session.startedAt))
            let tokens = session.usage.total
            if tokens > 0 {
                return "\(session.projectName) ran for \(Format.duration(elapsed)) "
                    + "and used \(Format.tokens(tokens)) tokens."
            }
            return "\(session.projectName) ran for \(Format.duration(elapsed))."
        }
    }
}
