import Foundation
import Testing
@testable import ClaudenceCore

// MARK: - Fixtures

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

private func makeSession(
    _ id: String,
    status: SessionStatus = .running,
    tokens: Int = 0,
    startedAt: Date = t0,
    lastActivityAt: Date = t0
) -> AISession {
    AISession(
        id: id,
        pid: 100,
        procStart: "Tue Sep  1 19:27:02 2026",
        projectName: id,
        workingDirectory: "/tmp/\(id)",
        status: status,
        startedAt: startedAt,
        lastActivityAt: lastActivityAt,
        usage: TokenUsage(freshInput: tokens)
    )
}

private func makeSnapshot(
    at instant: Date,
    sessions: [AISession] = [],
    windows: [UsageWindow]? = nil
) -> MonitorSnapshot {
    MonitorSnapshot(
        sessions: sessions,
        usage: windows.map { .available(windows: $0, fetchedAt: instant) }
            ?? .unavailable(reason: .untranslated("test")),
        todayUsage: .zero,
        updatedAt: instant
    )
}

private func window(_ name: String, _ percent: Double?, resetsAt: Date? = nil) -> UsageWindow {
    UsageWindow(name: name, usedPercent: percent, resetsAt: resetsAt)
}

/// Mutable clock so the throttle tests never sleep.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { self.current = start }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(_ interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }
}

/// Flips the liveness answer the deriver sees, so the "process is still alive"
/// branch can be driven without touching a real process.
private final class LivenessStub: @unchecked Sendable {
    private let lock = NSLock()
    private var alive: Bool

    init(alive: Bool) { self.alive = alive }

    var probe: @Sendable (AISession) -> Bool {
        { [self] _ in
            lock.lock(); defer { lock.unlock() }
            return alive
        }
    }

    func set(alive value: Bool) {
        lock.lock(); defer { lock.unlock() }
        alive = value
    }
}

/// A deriver whose vanished sessions are backed by processes that are gone,
/// which is the ordinary "the session finished" case.
private func makeDeriver(processesAlive: Bool = false) -> EventDeriver {
    EventDeriver(isProcessLive: { _ in processesAlive })
}

/// Feeds a chain of snapshots through one deriver and returns everything it
/// produced, which is how the "exactly once" assertions stay honest.
private func derive(_ snapshots: [MonitorSnapshot], with deriver: inout EventDeriver) -> [NotificationEvent] {
    var events: [NotificationEvent] = []
    for index in 1..<snapshots.count {
        events.append(contentsOf: deriver.events(from: snapshots[index - 1], to: snapshots[index]))
    }
    return events
}

// MARK: - Usage threshold

@Suite("Usage threshold events")
struct UsageThresholdTests {

    @Test("A window crossing 90% upward fires exactly once")
    func crossingFiresOnce() {
        var deriver = makeDeriver()
        let events = derive([
            makeSnapshot(at: at(0)),
            makeSnapshot(at: at(60), windows: [window("five_hour", 85)]),
            makeSnapshot(at: at(120), windows: [window("five_hour", 92)]),
            makeSnapshot(at: at(180), windows: [window("five_hour", 95)]),
        ], with: &deriver)

        #expect(events.count == 1)
        #expect(events.first == .usageThreshold(window: window("five_hour", 92)))
        #expect(deriver.isArmed(window: "five_hour") == false)
    }

    @Test("90.4% across ten consecutive refreshes fires exactly once")
    func hoveringDoesNotRepeat() {
        var deriver = makeDeriver()
        var chain = [
            makeSnapshot(at: at(0)),
            makeSnapshot(at: at(30), windows: [window("five_hour", 80)]),
        ]
        for step in 1...10 {
            chain.append(makeSnapshot(at: at(30 + Double(step) * 30), windows: [window("five_hour", 90.4)]))
        }

        let events = derive(chain, with: &deriver)
        #expect(events.count == 1)
    }

    @Test("Dropping below the re-arm boundary and crossing again fires a second time")
    func hysteresisRearms() {
        var deriver = makeDeriver()
        let events = derive([
            makeSnapshot(at: at(0)),
            makeSnapshot(at: at(30), windows: [window("five_hour", 80)]),
            makeSnapshot(at: at(60), windows: [window("five_hour", 92)]),   // fires
            makeSnapshot(at: at(90), windows: [window("five_hour", 84)]),   // below 85: re-arms
            makeSnapshot(at: at(120), windows: [window("five_hour", 92)]),  // fires again
        ], with: &deriver)

        #expect(events.count == 2)
    }

    @Test("A dip that stays inside the band does not re-arm")
    func shallowDipDoesNotRearm() {
        var deriver = makeDeriver()
        let events = derive([
            makeSnapshot(at: at(0)),
            makeSnapshot(at: at(30), windows: [window("five_hour", 80)]),
            makeSnapshot(at: at(60), windows: [window("five_hour", 92)]),   // fires
            makeSnapshot(at: at(90), windows: [window("five_hour", 86)]),   // still inside the band
            makeSnapshot(at: at(120), windows: [window("five_hour", 92)]),  // must not fire
        ], with: &deriver)

        #expect(events.count == 1)
    }

    @Test("A passed resetsAt re-arms the window even when the percentage never left the band")
    func passedResetRearms() {
        let firstReset = at(3_600)
        let secondReset = at(7_200)
        var deriver = makeDeriver()

        // 91% fires. The next period opens at 88%, which is above the 85%
        // re-arm boundary, so only the passed reset point can re-arm it.
        let events = derive([
            makeSnapshot(at: at(0)),
            makeSnapshot(at: at(60), windows: [window("seven_day", 91, resetsAt: firstReset)]),
            makeSnapshot(at: at(120), windows: [window("seven_day", 88, resetsAt: firstReset)]),
            makeSnapshot(at: at(3_660), windows: [window("seven_day", 88, resetsAt: secondReset)]),
            makeSnapshot(at: at(3_720), windows: [window("seven_day", 91, resetsAt: secondReset)]),
        ], with: &deriver)

        #expect(events.count == 2)
    }

    @Test("A passed reset with a still-high percentage does not re-fire the period that ended")
    func staleResetDoesNotRefire() {
        let reset = at(3_600)
        var deriver = makeDeriver()

        // The reset point has passed but the usage API has not refreshed, so it
        // still reports 92% for the window that just closed. That is a stale
        // reading, not a new window.
        let events = derive([
            makeSnapshot(at: at(0)),
            makeSnapshot(at: at(60), windows: [window("five_hour", 92, resetsAt: reset)]),
            makeSnapshot(at: at(3_660), windows: [window("five_hour", 92, resetsAt: reset)]),
            makeSnapshot(at: at(3_720), windows: [window("five_hour", 92, resetsAt: reset)]),
        ], with: &deriver)

        #expect(events.count == 1)
    }

    @Test("Unavailable usage produces nothing and does not re-arm")
    func unavailableUsageIsSilent() {
        var deriver = makeDeriver()
        let events = derive([
            makeSnapshot(at: at(0)),
            makeSnapshot(at: at(30), windows: [window("five_hour", 92)]),  // fires
            makeSnapshot(at: at(60)),                                      // unavailable
            makeSnapshot(at: at(90)),                                      // unavailable
            makeSnapshot(at: at(120), windows: [window("five_hour", 93)]), // must not fire
        ], with: &deriver)

        #expect(events.count == 1)
    }

    @Test("A window with no measured percentage is never treated as zero")
    func missingPercentIsSkipped() {
        var deriver = makeDeriver()
        let events = derive([
            makeSnapshot(at: at(0)),
            makeSnapshot(at: at(30), windows: [window("five_hour", nil)]),
            makeSnapshot(at: at(60), windows: [window("five_hour", nil)]),
        ], with: &deriver)

        #expect(events.isEmpty)
        #expect(deriver.isArmed(window: "five_hour"))
    }

    @Test("Separate windows arm and fire independently")
    func windowsAreIndependent() {
        var deriver = makeDeriver()
        let events = derive([
            makeSnapshot(at: at(0)),
            makeSnapshot(at: at(30), windows: [window("five_hour", 92), window("seven_day", 20)]),
            makeSnapshot(at: at(60), windows: [window("five_hour", 93), window("seven_day", 91)]),
        ], with: &deriver)

        #expect(events.count == 2)
        #expect(events[0].subjectID == "five_hour")
        #expect(events[1].subjectID == "seven_day")
    }
}

// MARK: - Session completion

@Suite("Session completion events")
struct SessionCompletionTests {

    @Test("A session disappearing yields exactly one completion event")
    func disappearanceFiresOnce() {
        var deriver = makeDeriver()
        let alpha = makeSession("alpha", tokens: 1_200, lastActivityAt: at(300))

        let events = derive([
            makeSnapshot(at: at(0), sessions: [alpha]),
            makeSnapshot(at: at(30), sessions: []),
            makeSnapshot(at: at(60), sessions: []),
            makeSnapshot(at: at(90), sessions: []),
        ], with: &deriver)

        #expect(events.count == 1)
        #expect(events.first == .sessionCompleted(session: alpha))
    }

    @Test("A vanished session whose process is still alive is not reported as completed")
    func liveProcessIsNotACompletion() {
        var deriver = makeDeriver(processesAlive: true)
        let events = derive([
            makeSnapshot(at: at(0), sessions: [makeSession("alpha")]),
            makeSnapshot(at: at(30), sessions: []),
            makeSnapshot(at: at(60), sessions: []),
            makeSnapshot(at: at(90), sessions: []),
        ], with: &deriver)

        #expect(events.isEmpty)
        #expect(deriver.pendingCompletionIDs == ["alpha"])
    }

    @Test("A session that vanishes and is re-discovered does not fire")
    func briefDiscoveryFailureIsSilent() {
        var deriver = makeDeriver(processesAlive: true)
        let alpha = makeSession("alpha")

        let events = derive([
            makeSnapshot(at: at(0), sessions: [alpha]),
            makeSnapshot(at: at(30), sessions: []),        // discovery blip
            makeSnapshot(at: at(60), sessions: [alpha]),   // back
            makeSnapshot(at: at(90), sessions: [alpha]),
        ], with: &deriver)

        #expect(events.isEmpty)
        #expect(deriver.pendingCompletionIDs.isEmpty)
    }

    @Test("A held session fires once, and only once, when its process finally exits")
    func heldSessionFiresWhenProcessExits() {
        let liveness = LivenessStub(alive: true)
        var deriver = EventDeriver(isProcessLive: liveness.probe)
        let alpha = makeSession("alpha")

        var events = deriver.events(
            from: makeSnapshot(at: at(0), sessions: [alpha]),
            to: makeSnapshot(at: at(30), sessions: [])
        )
        #expect(events.isEmpty)
        #expect(deriver.pendingCompletionIDs == ["alpha"])

        liveness.set(alive: false)
        events = deriver.events(
            from: makeSnapshot(at: at(30), sessions: []),
            to: makeSnapshot(at: at(60), sessions: [])
        )
        #expect(events.count == 1)

        events = deriver.events(
            from: makeSnapshot(at: at(60), sessions: []),
            to: makeSnapshot(at: at(90), sessions: [])
        )
        #expect(events.isEmpty)
        #expect(deriver.pendingCompletionIDs.isEmpty)
    }

    @Test("A completed session that is re-discovered and vanishes again does not double-fire")
    func completionIsRememberedAcrossRediscovery() {
        var deriver = makeDeriver()
        let alpha = makeSession("alpha")

        let events = derive([
            makeSnapshot(at: at(0), sessions: [alpha]),
            makeSnapshot(at: at(30), sessions: []),        // fires
            makeSnapshot(at: at(60), sessions: [alpha]),   // same id back
            makeSnapshot(at: at(90), sessions: []),        // must not fire again
            makeSnapshot(at: at(120), sessions: []),
        ], with: &deriver)

        #expect(events.count == 1)
    }

    @Test("A stale snapshot is not evidence that a session ended")
    func staleSnapshotIsNotEvidence() {
        var deriver = makeDeriver()
        let alpha = makeSession("alpha")
        let live = makeSnapshot(at: at(60), sessions: [alpha])
        let gone = makeSnapshot(at: at(30), sessions: [])

        // `updatedAt` went backwards, so this snapshot decides nothing.
        #expect(deriver.events(from: live, to: gone).isEmpty)
        // Same snapshot republished: no advance, no decision.
        #expect(deriver.events(from: gone, to: gone).isEmpty)
    }

    @Test("Several sessions ending together each fire once")
    func concurrentCompletions() {
        var deriver = makeDeriver()
        let events = derive([
            makeSnapshot(at: at(0), sessions: [makeSession("alpha"), makeSession("beta")]),
            makeSnapshot(at: at(30), sessions: []),
            makeSnapshot(at: at(60), sessions: []),
        ], with: &deriver)

        #expect(events.count == 2)
        #expect(Set(events.map(\.subjectID)) == ["alpha", "beta"])
    }

    @Test("One session ending while another keeps running fires only for the one that ended")
    func partialCompletion() {
        var deriver = makeDeriver()
        let beta = makeSession("beta")
        let events = derive([
            makeSnapshot(at: at(0), sessions: [makeSession("alpha"), beta]),
            makeSnapshot(at: at(30), sessions: [beta]),
            makeSnapshot(at: at(60), sessions: [beta]),
        ], with: &deriver)

        #expect(events.count == 1)
        #expect(events.first?.subjectID == "alpha")
    }
}

// MARK: - Derivable states only

@Suite("Non-derivable states")
struct DerivableStateTests {

    @Test("No event is produced for a session status that is not derivable")
    func nonDerivableStatesProduceNothing() {
        // `waiting` used to be in this list. It is derivable now, because the
        // registry writes the status rather than it being inferred, so only
        // permission and error remain unproven.
        for status in [SessionStatus.permission, .error] {
            #expect(status.isDerivable == false)

            var deriver = makeDeriver()
            let events = derive([
                makeSnapshot(at: at(0), sessions: [makeSession("ghost", status: status)]),
                makeSnapshot(at: at(30), sessions: []),
                makeSnapshot(at: at(60), sessions: []),
                makeSnapshot(at: at(90), sessions: []),
            ], with: &deriver)

            #expect(events.isEmpty, "\(status.rawValue) must not produce an event")
            #expect(deriver.pendingCompletionIDs.isEmpty)
        }
    }

    @Test("Only derivable states are eligible, and all of them are covered")
    func derivableStatesFire() {
        for status in [SessionStatus.running, .idle, .completed] {
            #expect(status.isDerivable)

            var deriver = makeDeriver()
            let events = derive([
                makeSnapshot(at: at(0), sessions: [makeSession("alpha", status: status)]),
                makeSnapshot(at: at(30), sessions: []),
                makeSnapshot(at: at(60), sessions: []),
            ], with: &deriver)

            #expect(events.count == 1, "\(status.rawValue) should complete")
        }
    }

    @Test("The shipped event set carries no permission or failure case")
    func shippedEventSetIsMinimal() {
        // Spec section 10 lists four events. Two of them describe states that
        // section 6 marks as not derivable, so they are not modelled at all:
        // `permission` and `error` both return false from `isDerivable`, and
        // this test exists to keep them out.
        //
        // Two kinds the table does not list are here anyway, and both earn it
        // from the same source. Claude Code 2.1.258 writes real status strings
        // into `~/.claude/sessions/<pid>.json`, observed as
        // `busy -> waiting -> busy -> idle`, and `mapStatus` maps `waiting` and
        // `idle` directly from those strings rather than from a clock. The
        // reasoning for each is on `NotificationEvent` itself.
        #expect(NotificationEvent.Kind.allCases.count == 4)
        #expect(Set(NotificationEvent.Kind.allCases.map(\.rawValue))
            == ["usageThreshold", "sessionCompleted", "sessionIdle", "sessionNeedsInput"])
    }
}

// MARK: - Session needs an answer

@Suite("Session needs input events")
struct SessionNeedsInputTests {

    private func reported(_ id: String, _ status: SessionStatus, at instant: Date) -> AISession {
        makeSession(id, status: status, lastActivityAt: instant)
    }

    @Test("A session that starts waiting on the person fires exactly once")
    func waitingFiresOnce() {
        var deriver = makeDeriver()
        let events = derive([
            makeSnapshot(at: at(0), sessions: [reported("alpha", .running, at: at(0))]),
            makeSnapshot(at: at(30), sessions: [reported("alpha", .waiting, at: at(30))]),
            makeSnapshot(at: at(60), sessions: [reported("alpha", .waiting, at: at(30))]),
            makeSnapshot(at: at(90), sessions: [reported("alpha", .waiting, at: at(30))]),
        ], with: &deriver)

        #expect(events.count == 1)
        #expect(events.first?.kind == .sessionNeedsInput)
        #expect(events.first?.subjectID == "alpha")
    }

    @Test("A session first seen already waiting is history, not a transition")
    func firstSightingIsNotATransition() {
        var deriver = makeDeriver()
        let events = derive([
            makeSnapshot(at: at(0), sessions: []),
            makeSnapshot(at: at(30), sessions: [reported("alpha", .waiting, at: at(30))]),
            makeSnapshot(at: at(60), sessions: [reported("alpha", .waiting, at: at(30))]),
        ], with: &deriver)

        #expect(events.isEmpty)
    }

    @Test("Answering and being asked again is a second real transition")
    func waitingAfterResumingFiresAgain() {
        var deriver = makeDeriver()
        let events = derive([
            makeSnapshot(at: at(0), sessions: [reported("alpha", .running, at: at(0))]),
            makeSnapshot(at: at(30), sessions: [reported("alpha", .waiting, at: at(30))]),
            makeSnapshot(at: at(60), sessions: [reported("alpha", .running, at: at(60))]),
            makeSnapshot(at: at(90), sessions: [reported("alpha", .waiting, at: at(90))]),
        ], with: &deriver)

        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.kind == .sessionNeedsInput })
    }

    /// The one deliberate difference from `idleEvents`, pinned so nobody
    /// "fixes" it into symmetry later. `.waiting` is produced only by a direct
    /// read of the literal registry string, never by the recency fallback, so
    /// there is no clock-derived case to fence off and requiring an advanced
    /// `lastActivityAt` could only suppress a real notification.
    @Test("A waiting whose lastActivityAt did not move still fires")
    func waitingWithUnchangedActivityStillFires() {
        var deriver = makeDeriver()
        let events = derive([
            makeSnapshot(at: at(0), sessions: [reported("alpha", .running, at: at(0))]),
            makeSnapshot(at: at(30), sessions: [reported("alpha", .waiting, at: at(0))]),
        ], with: &deriver)

        #expect(events.count == 1)
        #expect(events.first?.kind == .sessionNeedsInput)
    }

    @Test("A replayed snapshot is not evidence")
    func staleSnapshotDoesNotFire() {
        var deriver = makeDeriver()
        let events = derive([
            makeSnapshot(at: at(30), sessions: [reported("alpha", .running, at: at(0))]),
            makeSnapshot(at: at(30), sessions: [reported("alpha", .waiting, at: at(30))]),
        ], with: &deriver)

        #expect(events.isEmpty)
    }

    @Test("The switch for it suppresses it and nothing else")
    func filterSuppressesOnlyThisKind() {
        let session = makeSession("alpha", status: .waiting)
        let needsInput = NotificationEvent.sessionNeedsInput(session: session)
        let completed = NotificationEvent.sessionCompleted(session: session)

        let filter = NotificationFilter(
            isEnabled: true,
            allowedKinds: Set(NotificationEvent.Kind.allCases).subtracting([.sessionNeedsInput])
        )

        #expect(filter.allows(needsInput) == false)
        #expect(filter.allows(completed))
    }

    /// The body names the project and states that an answer is owed. It must
    /// never carry the question: that lives in `content[].text`, which the
    /// privacy allowlist keeps out of this application entirely.
    @Test("The wording names the project and asks for nothing else")
    func wordingStaysInsideTheAllowlist() {
        let session = makeSession("alpha", status: .waiting)
        let event = NotificationEvent.sessionNeedsInput(session: session)

        #expect(event.title(in: .english) == "Session needs you")
        #expect(event.body(in: .english).contains(session.projectName))
        #expect(event.body(in: .english).contains("waiting for your answer"))
    }
}

// MARK: - Session idle

@Suite("Session idle events")
struct SessionIdleTests {

    /// The registry-written case: the file was rewritten, so the status moved
    /// and `lastActivityAt` moved with it.
    private func reported(_ id: String, _ status: SessionStatus, at instant: Date) -> AISession {
        makeSession(id, status: status, lastActivityAt: instant)
    }

    @Test("A session the registry reports as idle fires exactly once")
    func reportedIdleFiresOnce() {
        var deriver = makeDeriver()
        let events = derive([
            makeSnapshot(at: at(0), sessions: [reported("alpha", .running, at: at(0))]),
            makeSnapshot(at: at(30), sessions: [reported("alpha", .idle, at: at(30))]),
            makeSnapshot(at: at(60), sessions: [reported("alpha", .idle, at: at(30))]),
            makeSnapshot(at: at(90), sessions: [reported("alpha", .idle, at: at(30))]),
        ], with: &deriver)

        #expect(events.count == 1)
        #expect(events.first?.kind == .sessionIdle)
        #expect(events.first?.subjectID == "alpha")
    }

    @Test("An idle reached by the clock rather than by the registry does not fire")
    func staleIdleDoesNotFire() {
        // `SessionRegistryAdapter.mapStatus` routes an unknown or missing status
        // by recency, so a record nobody wrote flips to `.idle` once it is older
        // than `Constants.Watch.idleThreshold`. The tell is that
        // `lastActivityAt` did not move: no file was written, nothing happened,
        // only the clock advanced.
        var deriver = makeDeriver()
        let events = derive([
            makeSnapshot(at: at(0), sessions: [reported("alpha", .running, at: at(0))]),
            makeSnapshot(at: at(120), sessions: [reported("alpha", .idle, at: at(0))]),
            makeSnapshot(at: at(180), sessions: [reported("alpha", .idle, at: at(0))]),
        ], with: &deriver)

        #expect(events.isEmpty)
    }

    @Test("A session first seen already idle is history, not a transition")
    func firstSightingIsNotATransition() {
        var deriver = makeDeriver()
        let events = derive([
            makeSnapshot(at: at(0), sessions: []),
            makeSnapshot(at: at(30), sessions: [reported("alpha", .idle, at: at(30))]),
            makeSnapshot(at: at(60), sessions: [reported("alpha", .idle, at: at(30))]),
        ], with: &deriver)

        #expect(events.isEmpty)
    }

    @Test("Going back to work and idling again is a second real transition")
    func idleAfterResumingFiresAgain() {
        var deriver = makeDeriver()
        let events = derive([
            makeSnapshot(at: at(0), sessions: [reported("alpha", .running, at: at(0))]),
            makeSnapshot(at: at(30), sessions: [reported("alpha", .idle, at: at(30))]),
            makeSnapshot(at: at(60), sessions: [reported("alpha", .running, at: at(60))]),
            makeSnapshot(at: at(90), sessions: [reported("alpha", .idle, at: at(90))]),
        ], with: &deriver)

        // Two genuine transitions. Suppressing a session that flaps is the
        // throttle's job, not the deriver's, and its per-key cooling period
        // already covers `sessionIdle:alpha`.
        #expect(events.count == 2)
    }

    @Test("A stale snapshot is not evidence that a session went idle")
    func staleSnapshotIsNotEvidence() {
        var deriver = makeDeriver()
        let working = makeSnapshot(at: at(60), sessions: [reported("alpha", .running, at: at(0))])
        let quiet = makeSnapshot(at: at(30), sessions: [reported("alpha", .idle, at: at(30))])

        #expect(deriver.events(from: working, to: quiet).isEmpty)
    }

    @Test("A non-derivable status before the transition produces nothing")
    func nonDerivablePredecessorProducesNothing() {
        for status in [SessionStatus.permission, .error] {
            var deriver = makeDeriver()
            let events = derive([
                makeSnapshot(at: at(0), sessions: [reported("alpha", status, at: at(0))]),
                makeSnapshot(at: at(30), sessions: [reported("alpha", .idle, at: at(30))]),
            ], with: &deriver)

            #expect(events.isEmpty, "\(status.rawValue) must not lead into an idle event")
        }
    }

    @Test("Only the session that went idle is reported")
    func othersAreUnaffected() {
        var deriver = makeDeriver()
        let events = derive([
            makeSnapshot(at: at(0), sessions: [
                reported("alpha", .running, at: at(0)),
                reported("beta", .running, at: at(0)),
            ]),
            makeSnapshot(at: at(30), sessions: [
                reported("alpha", .idle, at: at(30)),
                reported("beta", .running, at: at(30)),
            ]),
        ], with: &deriver)

        #expect(events.count == 1)
        #expect(events.first?.subjectID == "alpha")
    }

    @Test("A session that goes idle and later ends produces both events, in order")
    func idleThenCompletion() {
        var deriver = makeDeriver()
        let events = derive([
            makeSnapshot(at: at(0), sessions: [reported("alpha", .running, at: at(0))]),
            makeSnapshot(at: at(30), sessions: [reported("alpha", .idle, at: at(30))]),
            makeSnapshot(at: at(60), sessions: []),
        ], with: &deriver)

        #expect(events.map(\.kind) == [.sessionIdle, .sessionCompleted])
    }
}

// MARK: - Throttle

@Suite("Notification throttle")
struct NotificationThrottleTests {

    @Test("The per-key cooling period is enforced against the injected clock")
    func coolingPeriodPerKey() {
        let clock = TestClock(t0)
        let throttle = NotificationThrottle(
            coolingPeriod: 600,
            globalLimit: 100,
            globalWindow: 3_600,
            clock: { clock.now }
        )
        let usage = NotificationEvent.usageThreshold(window: window("five_hour", 92))

        #expect(throttle.admit(usage))
        #expect(throttle.admit(usage) == false)

        clock.advance(599)
        #expect(throttle.admit(usage) == false)

        clock.advance(2)
        #expect(throttle.admit(usage))
        #expect(throttle.suppressedCount == 2)
    }

    @Test("A cooling key does not mute a different key")
    func keysAreIndependent() {
        let clock = TestClock(t0)
        let throttle = NotificationThrottle(coolingPeriod: 600, clock: { clock.now })

        #expect(throttle.admit(.usageThreshold(window: window("five_hour", 92))))
        #expect(throttle.admit(.usageThreshold(window: window("five_hour", 93))) == false)
        // Different window, and a different kind entirely: both still get through.
        #expect(throttle.admit(.usageThreshold(window: window("seven_day", 91))))
        #expect(throttle.admit(.sessionCompleted(session: makeSession("alpha"))))
    }

    @Test("The global ceiling caps a burst")
    func globalCeilingCapsBurst() {
        let clock = TestClock(t0)
        let throttle = NotificationThrottle(
            coolingPeriod: 600,
            globalLimit: 3,
            globalWindow: 600,
            clock: { clock.now }
        )

        // Ten distinct keys, so nothing is stopped by the per-key rule.
        let burst = (0..<10).map { NotificationEvent.sessionCompleted(session: makeSession("s\($0)")) }
        let admitted = throttle.admit(burst)

        #expect(admitted.count == 3)
        #expect(throttle.suppressedCount == 7)
        #expect(throttle.admittedInWindow == 3)

        // The ceiling is a rolling window, not a bucket someone has to empty.
        clock.advance(601)
        #expect(throttle.admittedInWindow == 0)
        #expect(throttle.admit(.sessionCompleted(session: makeSession("s99"))))
    }

    @Test("A burst-suppressed event is admitted normally once the burst drains")
    func burstSuppressionIsNotACoolingPeriod() {
        let clock = TestClock(t0)
        let throttle = NotificationThrottle(
            coolingPeriod: 600,
            globalLimit: 1,
            globalWindow: 600,
            clock: { clock.now }
        )
        let late = NotificationEvent.sessionCompleted(session: makeSession("beta"))

        #expect(throttle.admit(.sessionCompleted(session: makeSession("alpha"))))
        #expect(throttle.admit(late) == false)

        clock.advance(601)
        #expect(throttle.admit(late))
    }

    @Test("Reset clears every record")
    func resetClears() {
        let throttle = NotificationThrottle(clock: { t0 })
        let usage = NotificationEvent.usageThreshold(window: window("five_hour", 92))
        #expect(throttle.admit(usage))
        #expect(throttle.admit(usage) == false)

        throttle.reset()
        #expect(throttle.suppressedCount == 0)
        #expect(throttle.admit(usage))
    }
}

// MARK: - Preference filter

@Suite("Notification preferences")
struct NotificationFilterTests {

    /// One event of every shipped kind, so a test that turns one switch off can
    /// assert on what survived rather than only on what did not.
    private var oneOfEach: [NotificationEvent] {
        [
            .usageThreshold(window: window("five_hour", 92)),
            .sessionCompleted(session: makeSession("alpha")),
            .sessionIdle(session: makeSession("beta", status: .idle)),
            .sessionNeedsInput(session: makeSession("gamma", status: .waiting)),
        ]
    }

    @Test("Every shipped kind has a switch, and the default leaves them all on")
    func defaultAllowsEveryKind() {
        #expect(NotificationFilter().allowedKinds == Set(NotificationEvent.Kind.allCases))
        #expect(NotificationFilter.all.apply(to: oneOfEach) == oneOfEach)
    }

    @Test("Each per-event switch suppresses only its own event")
    func perEventSwitchesAreIndependent() {
        let events = oneOfEach
        // Every kind is covered by construction, so a kind added later without
        // a switch fails here rather than shipping unfiltered.
        for kind in NotificationEvent.Kind.allCases {
            let off = NotificationFilter(
                isEnabled: true,
                allowedKinds: Set(NotificationEvent.Kind.allCases).subtracting([kind])
            )
            let survivors = off.apply(to: events)

            #expect(survivors.contains { $0.kind == kind } == false,
                    "\(kind.rawValue) should have been suppressed")
            #expect(survivors.count == events.count - 1,
                    "\(kind.rawValue) should not have taken anything else with it")
            #expect(survivors == events.filter { $0.kind != kind },
                    "order should survive the filter")
        }
    }

    @Test("Only the kind that is on gets through when the others are off")
    func aSingleKindLeftOn() {
        for kind in NotificationEvent.Kind.allCases {
            let only = NotificationFilter(isEnabled: true, allowedKinds: [kind])
            #expect(only.apply(to: oneOfEach).map(\.kind) == [kind])
        }
    }

    @Test("The master switch off suppresses every kind whatever the per-event switches say")
    func masterSwitchOverridesEveryKind() {
        let events = oneOfEach
        let off = NotificationFilter(
            isEnabled: false,
            allowedKinds: Set(NotificationEvent.Kind.allCases)
        )

        #expect(off.apply(to: events).isEmpty)
        #expect(NotificationFilter.silent.apply(to: events).isEmpty)

        // The per-event switches are kept rather than cleared, so turning the
        // master back on restores the choices instead of resetting them.
        var back = off
        back.isEnabled = true
        #expect(back.apply(to: events) == events)
    }

    @Test("An event suppressed by preference does not spend the throttle's budget")
    func preferenceSuppressionDoesNotConsumeThrottleBudget() {
        let clock = TestClock(t0)
        // A ceiling of one, so whatever reaches the throttle first takes the
        // only slot there is and anything behind it is visibly refused.
        let throttle = NotificationThrottle(
            coolingPeriod: 600,
            globalLimit: 1,
            globalWindow: 600,
            clock: { clock.now }
        )
        let filter = NotificationFilter(isEnabled: true, allowedKinds: [.sessionCompleted])

        let unwanted = NotificationEvent.usageThreshold(window: window("five_hour", 92))
        let wanted = NotificationEvent.sessionCompleted(session: makeSession("alpha"))

        // The unwanted event is first in the pass. Filtering after the throttle
        // instead of before it would let it take the single slot, and the event
        // the user actually asked for would be dropped as a burst overflow,
        // silently, because of a switch meant to make the app quieter.
        let admitted = filter.admissible([unwanted, wanted], through: throttle)

        #expect(admitted == [wanted])
        #expect(throttle.admittedInWindow == 1)
        // The sharp one: the throttle never saw the suppressed event at all, so
        // it did not even count it as something it refused.
        #expect(throttle.suppressedCount == 0)
    }

    @Test("The master switch off spends none of the throttle's budget either")
    func masterSwitchSpendsNoBudget() {
        let clock = TestClock(t0)
        let throttle = NotificationThrottle(
            coolingPeriod: 600,
            globalLimit: 5,
            globalWindow: 600,
            clock: { clock.now }
        )

        #expect(NotificationFilter.silent.admissible(oneOfEach, through: throttle).isEmpty)
        #expect(throttle.admittedInWindow == 0)
        #expect(throttle.suppressedCount == 0)

        // Turning it back on finds the budget untouched and the keys uncooled.
        let admitted = NotificationFilter.all.admissible(oneOfEach, through: throttle)
        #expect(admitted.count == oneOfEach.count)
    }

    @Test("An allowed event is still subject to the throttle")
    func filteringDoesNotBypassTheThrottle() {
        let clock = TestClock(t0)
        let throttle = NotificationThrottle(coolingPeriod: 600, clock: { clock.now })
        let filter = NotificationFilter.all
        let usage = NotificationEvent.usageThreshold(window: window("five_hour", 92))

        #expect(filter.admissible([usage], through: throttle) == [usage])
        #expect(filter.admissible([usage], through: throttle).isEmpty)
        #expect(throttle.suppressedCount == 1)

        clock.advance(601)
        #expect(filter.admissible([usage], through: throttle) == [usage])
    }
}

// MARK: - Wording

@Suite("Notification wording")
struct NotificationWordingTests {

    @Test("Titles come from the spec table")
    func titles() {
        #expect(NotificationEvent.usageThreshold(window: window("five_hour", 92)).title(in: .english) == "Usage at 90%")
        #expect(NotificationEvent.sessionCompleted(session: makeSession("alpha")).title(in: .english) == "Session completed")
        #expect(NotificationEvent.sessionIdle(session: makeSession("alpha")).title(in: .english) == "Session idle")
    }

    @Test("The idle body carries name, duration and tokens, and nothing else")
    func idleBody() {
        let session = makeSession("claudence-06", tokens: 128_000, startedAt: at(0), lastActivityAt: at(8_040))
        #expect(NotificationEvent.sessionIdle(session: session).body(in: .english)
            == "claudence-06 stopped working after 2h 14m and 128k tokens.")

        let silent = makeSession("scratch", tokens: 0, startedAt: at(0), lastActivityAt: at(90))
        #expect(NotificationEvent.sessionIdle(session: silent).body(in: .english)
            == "scratch stopped working after 1m 30s.")
    }

    @Test("The usage body reads as plain English and never invents a number")
    func usageBody() {
        let withReset = NotificationEvent.usageThreshold(
            window: window("five_hour", 92, resetsAt: at(4_500))
        )
        #expect(withReset.body(in: .english, now: at(0)) == "5 Hour window: about 8% left. Resets in 1h 15m.")

        // No reset point reported: the sentence simply stops rather than
        // guessing one.
        let withoutReset = NotificationEvent.usageThreshold(window: window("seven_day", 91))
        #expect(withoutReset.body(in: .english, now: at(0)) == "7 Day window: about 9% left.")
    }

    /// A notification is the one surface with no environment to read the
    /// language from, so the language is pushed to it. This pins that the
    /// wording actually follows the value pushed, in both halves of the
    /// sentence and not only in the title.
    @Test("notification wording follows the language it is given")
    func wordingFollowsLanguage() {
        let session = makeSession("claudence-06", tokens: 128_000, startedAt: at(0), lastActivityAt: at(8_040))
        let event = NotificationEvent.sessionCompleted(session: session)

        #expect(event.title(in: .english) == "Session completed")
        #expect(event.title(in: .thai) != event.title(in: .english))

        let thai = event.body(in: .thai)
        #expect(thai != event.body(in: .english))
        // The three substituted values are the same figures in both: a project
        // name, a duration and a token count are not translated, only placed.
        #expect(thai.contains("claudence-06"))
        #expect(thai.contains("2h 14m"))
        #expect(thai.contains("128k"))
    }

    @Test("The completion body carries name, duration and tokens")
    func completionBody() {
        let session = makeSession("claudence-06", tokens: 128_000, startedAt: at(0), lastActivityAt: at(8_040))
        let event = NotificationEvent.sessionCompleted(session: session)
        #expect(event.body(in: .english) == "claudence-06 ran for 2h 14m and used 128k tokens.")

        let silent = makeSession("scratch", tokens: 0, startedAt: at(0), lastActivityAt: at(90))
        #expect(NotificationEvent.sessionCompleted(session: silent).body(in: .english) == "scratch ran for 1m 30s.")
    }

    @Test("Throttle keys separate kind from subject")
    func throttleKeys() {
        #expect(NotificationEvent.usageThreshold(window: window("five_hour", 92)).throttleKey
            == "usageThreshold:five_hour")
        #expect(NotificationEvent.sessionCompleted(session: makeSession("alpha")).throttleKey
            == "sessionCompleted:alpha")
        // Same subject, different kind: a session that goes idle and later ends
        // must not have one of those muted by the other.
        #expect(NotificationEvent.sessionIdle(session: makeSession("alpha")).throttleKey
            == "sessionIdle:alpha")
    }
}
