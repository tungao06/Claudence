import Foundation

/// The complete set of things Claudence will interrupt a human for.
///
/// Spec section 10 lists four events. Two of those ship, plus a fifth the spec
/// table does not name; the two absentees are absent for the same reason.
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
///
/// ## Why `sessionIdle` exists when the spec's table does not list it
///
/// Settings ships a switch for it, so the question was whether the event can be
/// honest rather than whether anyone wants it. `SessionStatus.idle` returning
/// true from `isDerivable` is not on its own an answer: derivable is not the
/// same as eventable, and a state that is only ever computed from a staleness
/// threshold changes when the clock moves rather than when anything happens.
/// This application has no timer to hang that on and does not want one.
///
/// Measured on Claude Code 2.1.258 by watching `~/.claude/sessions/<pid>.json`
/// through a live session. It writes real status transitions to the file, each
/// with a fresh `updatedAt` and `statusUpdatedAt`, and the sequence observed
/// was `busy -> waiting -> busy -> idle`. Both `waiting` and `idle` are now
/// mapped directly from that string; the clock-derived branch below survives
/// only for a status this build does not recognise, or none at all.
///
/// `idle` is a string the registry
/// writes, `SessionRegistryAdapter.mapStatus` maps it directly, and spec
/// section 6 states the rule plainly: `updatedAt` governs only the fallback for
/// an unknown or missing status, never the mapping of a known one. So the
/// transition into `.idle` is a filesystem event Claudence already watches for,
/// not a deadline it would have to wait out.
///
/// The contamination is real but bounded, and `EventDeriver` fences it off. Two
/// branches of `mapStatus` do produce `.idle` from the clock: an unknown status
/// string and a missing one, both
/// routed by `now - updatedAt < Constants.Watch.idleThreshold`. The deriver
/// tells those apart without needing the raw string, which it never receives:
/// a registry-written idle arrives with `lastActivityAt` advanced, because the
/// write that set the status set `updatedAt` too, while a clock-derived idle
/// arrives with `lastActivityAt` unchanged, because no file was written at all.
/// The two cannot be confused in either direction, since a record that was just
/// rewritten is by definition recent and the recency branch returns `.running`
/// for it. See `EventDeriver.idleEvents`.
public enum NotificationEvent: Sendable, Equatable {
    /// A usage window crossed `Constants.UsageThreshold.critical` upward.
    case usageThreshold(window: UsageWindow)
    /// A session that was being monitored is gone and its absence is confirmed.
    case sessionCompleted(session: AISession)
    /// A session the registry reported as working now reports itself idle, and
    /// said so by rewriting its own record rather than by going stale.
    case sessionIdle(session: AISession)
    /// A session is waiting on the person: it has asked something and cannot
    /// continue until it is answered.
    ///
    /// This is the one event where an unread notification costs the user real
    /// time, because the session does no work at all until it is answered. It
    /// is also the best evidenced: `waiting` is a literal string Claude Code
    /// 2.1.258 writes into `~/.claude/sessions/<pid>.json`, observed in the
    /// sequence `busy -> waiting -> busy -> idle` while watching a live
    /// session, and `SessionRegistryAdapter.mapStatus` maps it directly with no
    /// clock involved on either branch.
    case sessionNeedsInput(session: AISession)

    // MARK: - Identity

    /// Coarse type, used as half of the throttle key. Separate from the payload
    /// so two different windows do not suppress each other.
    public enum Kind: String, Sendable, CaseIterable {
        case usageThreshold
        case sessionCompleted
        case sessionIdle
        case sessionNeedsInput
    }

    public var kind: Kind {
        switch self {
        case .usageThreshold: return .usageThreshold
        case .sessionCompleted: return .sessionCompleted
        case .sessionIdle: return .sessionIdle
        case .sessionNeedsInput: return .sessionNeedsInput
        }
    }

    /// The subject the event is about: a window name or a session id.
    public var subjectID: String {
        switch self {
        case .usageThreshold(let window): return window.name
        case .sessionCompleted(let session): return session.id
        case .sessionIdle(let session): return session.id
        case .sessionNeedsInput(let session): return session.id
        }
    }

    /// `(kind, subject)`. Deduplication and rate limiting are both per key, so
    /// a noisy five-hour window can never mute a session completion.
    public var throttleKey: String { "\(kind.rawValue):\(subjectID)" }

    // MARK: - Wording

    /// Titles come from the spec section 10 table verbatim, in English. They
    /// name the event, not the instance, so Notification Center groups them
    /// sensibly.
    public func title(in language: AppLanguage) -> String {
        switch self {
        // Built from the constant the deriver fires on, so the notification and
        // the settings row that switches it on cannot name different numbers.
        case .usageThreshold:
            return Words.usageAt.format(in: language, "\(Int(Constants.UsageThreshold.critical))")
        case .sessionCompleted: return Words.sessionCompleted.string(in: language)
        // Not in the section 10 table, so it is named to sit beside the row
        // that is: the state, not the instance, in the same two words.
        case .sessionIdle: return Words.sessionIdle.string(in: language)
        // Names who is being waited on rather than what the session is doing,
        // for the same reason `Theme.namePhrase(for:)` renders this state as
        // "Needs you": a title reading "Session waiting" sits directly above
        // "Session idle" in Notification Center and the two would not separate.
        case .sessionNeedsInput: return Words.sessionNeedsYou.string(in: language)
        }
    }

    /// Plain English, and never a fabricated number: anything the snapshot did
    /// not supply is simply left out of the sentence rather than defaulted.
    /// See spec section 9.4.
    public func body(in language: AppLanguage, now: Date = Date()) -> String {
        switch self {
        case .usageThreshold(let window):
            var sentence: String
            if let remaining = window.remainingPercent {
                // "About" is load-bearing. The API reports a rounded percentage
                // and the window keeps moving while the notification is queued.
                sentence = Words.windowAboutLeft.format(
                    in: language,
                    window.displayName,
                    Format.percent(remaining)
                )
            } else {
                sentence = Words.windowLimitReached.format(in: language, window.displayName)
            }
            if let until = Format.timeUntil(window.resetsAt, now: now) {
                sentence += Words.resetsIn.format(in: language, until)
            }
            return sentence

        case .sessionCompleted(let session):
            let elapsed = max(0, session.lastActivityAt.timeIntervalSince(session.startedAt))
            let tokens = session.usage.total
            if tokens > 0 {
                return Words.ranForAndUsed.format(
                    in: language,
                    session.projectName,
                    Format.duration(elapsed),
                    Format.tokens(tokens)
                )
            }
            return Words.ranFor.format(in: language, session.projectName, Format.duration(elapsed))

        case .sessionIdle(let session):
            // Same three facts as a completion, and deliberately no fourth. The
            // useful thing to say here would be what the session stopped on,
            // and that is exactly what the privacy allowlist keeps out: the
            // project name, an elapsed time and a token count are the whole
            // vocabulary. Worded as an observation rather than as "waiting for
            // you", because idle means the session is not working, not that it
            // has asked anyone a question.
            let elapsed = max(0, session.lastActivityAt.timeIntervalSince(session.startedAt))
            let tokens = session.usage.total
            if tokens > 0 {
                return Words.stoppedAfterAnd.format(
                    in: language,
                    session.projectName,
                    Format.duration(elapsed),
                    Format.tokens(tokens)
                )
            }
            return Words.stoppedAfter.format(
                in: language,
                session.projectName,
                Format.duration(elapsed)
            )

        case .sessionNeedsInput(let session):
            // The one thing a reader wants here is what was asked, and that is
            // exactly what the privacy allowlist keeps out: the question lives
            // in `content[].text`, which this application never reads. So the
            // sentence says that an answer is owed and which project owes it,
            // and stops. Time elapsed is deliberately omitted -- the interval
            // since the session started says nothing about how long the
            // question has been sitting there, and printing it would invite
            // exactly that reading.
            return Words.waitingForAnswer.format(in: language, session.projectName)
        }
    }

    /// The wording, both languages, in one place.
    ///
    /// Substitution is per language rather than by assembling an English
    /// sentence and translating the pieces, because Thai does not put the
    /// project name, the duration and the token count where English does.
    enum Words {
        static let usageAt = Phrase(en: "Usage at %@%", th: "ใช้งานถึง %@%")
        static let sessionCompleted = Phrase(en: "Session completed", th: "Session เสร็จแล้ว")
        static let sessionIdle = Phrase(en: "Session idle", th: "Session ว่างอยู่")
        static let sessionNeedsYou = Phrase(en: "Session needs you", th: "Session ต้องการคุณ")

        static let windowAboutLeft = Phrase(
            en: "%@ window: about %@ left.",
            th: "หน้าต่าง %@: เหลือประมาณ %@"
        )
        static let windowLimitReached = Phrase(
            en: "%@ window: limit reached.",
            th: "หน้าต่าง %@: ถึงขีดจำกัดแล้ว"
        )
        static let resetsIn = Phrase(en: " Resets in %@.", th: " รีเซ็ตอีก %@")

        static let ranForAndUsed = Phrase(
            en: "%@ ran for %@ and used %@ tokens.",
            th: "%@ ทำงาน %@ ใช้ไป %@ token"
        )
        static let ranFor = Phrase(en: "%@ ran for %@.", th: "%@ ทำงาน %@")

        static let stoppedAfterAnd = Phrase(
            en: "%@ stopped working after %@ and %@ tokens.",
            th: "%@ หยุดทำงานหลังจาก %@ และ %@ token"
        )
        static let stoppedAfter = Phrase(
            en: "%@ stopped working after %@.",
            th: "%@ หยุดทำงานหลังจาก %@"
        )

        static let waitingForAnswer = Phrase(
            en: "%@ is waiting for your answer.",
            th: "%@ กำลังรอคำตอบจากคุณ"
        )
    }
}

// MARK: - Preference filter

/// Which of the shipped events the user actually wants, as one value.
///
/// The switches themselves live in `Preferences`, which is `@MainActor`,
/// `@Observable`, and in the app target. Handing that object to the
/// notification path would drag the whole settings model into `ClaudenceCore`
/// and put an actor hop in front of a decision taken on whatever thread the
/// engine published from. So the composition root pushes this value down
/// instead of the notification path pulling preferences up, which is the shape
/// `NotificationBridge.isEnabled` already had; this only widens it from one
/// flag to the whole policy.
///
/// The master switch is part of the value rather than a flag standing beside
/// it. "Notifications are off" and "this kind is off" are then one decision
/// with one place to test, instead of two gates that can quietly disagree about
/// which of them was consulted first.
public struct NotificationFilter: Sendable, Equatable {

    /// The outer gate. Off means nothing is posted, whatever `allowedKinds`
    /// holds, and the per-kind switches are kept rather than cleared so
    /// turning it back on restores the choices.
    public var isEnabled: Bool

    /// The kinds left switched on. A kind absent from the set is suppressed.
    ///
    /// A set of the kinds to keep, not of the kinds to drop, so the default is
    /// "everything" and a `NotificationEvent.Kind` added later is delivered
    /// until someone deliberately writes a switch for it. The opposite default
    /// would make a new event type silently undeliverable, which is the harder
    /// failure to notice.
    public var allowedKinds: Set<NotificationEvent.Kind>

    public init(
        isEnabled: Bool = true,
        allowedKinds: Set<NotificationEvent.Kind> = Set(NotificationEvent.Kind.allCases)
    ) {
        self.isEnabled = isEnabled
        self.allowedKinds = allowedKinds
    }

    /// Everything on, which is the state a fresh install is in.
    public static let all = NotificationFilter()

    /// Nothing at all, by either gate.
    public static let silent = NotificationFilter(isEnabled: false, allowedKinds: [])

    // MARK: - Application

    public func allows(_ event: NotificationEvent) -> Bool {
        isEnabled && allowedKinds.contains(event.kind)
    }

    /// Preserves order, like `NotificationThrottle.admit`.
    public func apply(to events: [NotificationEvent]) -> [NotificationEvent] {
        events.filter { allows($0) }
    }

    /// The preference gate and the throttle, in that order, as a single call.
    ///
    /// The order is the whole point, so it is not left to a caller to get
    /// right. The throttle's global ceiling is a budget: five notifications per
    /// ten minutes, shared by every kind. Admitting first and filtering after
    /// would let an event the user switched off spend a slot on its way to
    /// being discarded, and the notification they did want would be dropped as
    /// a burst overflow, silently, because of a preference that was supposed to
    /// make the app quieter rather than lossier.
    public func admissible(
        _ events: [NotificationEvent],
        through throttle: NotificationThrottle
    ) -> [NotificationEvent] {
        throttle.admit(apply(to: events))
    }
}
