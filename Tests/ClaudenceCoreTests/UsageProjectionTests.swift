import Foundation
import Testing

@testable import ClaudenceCore

/// The meter shows a photograph where a trajectory is needed. These tests are
/// about the honesty around the division, because this is the feature most able
/// to print a number nobody measured.
@Suite("Usage projection")
struct UsageProjectionTests {

    private let start = Date(timeIntervalSince1970: 1_788_000_000)

    private func window(
        _ name: String = "five_hour",
        used: Double?,
        resetsIn hours: Double
    ) -> UsageWindow {
        UsageWindow(
            name: name,
            usedPercent: used,
            resetsAt: start.addingTimeInterval(hours * 3_600)
        )
    }

    @Test("one reading projects nothing")
    func oneReadingIsNotARate() {
        var projector = UsageProjector()
        projector.record(window(used: 20, resetsIn: 4), at: start)
        #expect(
            projector.projection(for: window(used: 20, resetsIn: 4), now: start)
                == .rateUnavailable(.notEnoughSamples)
        )
    }

    /// Two readings a minute apart, with the endpoint's own rounding step
    /// between them, produce a rate an order of magnitude out. The span floor is
    /// what stops that reaching the screen.
    @Test("two readings too close together project nothing")
    func spanFloor() {
        var projector = UsageProjector()
        projector.record(window(used: 20, resetsIn: 4), at: start)
        projector.record(window(used: 21, resetsIn: 4), at: start.addingTimeInterval(60))
        #expect(
            projector.projection(for: window(used: 21, resetsIn: 4), now: start.addingTimeInterval(60))
                == .rateUnavailable(.notEnoughSamples)
        )
    }

    @Test("a steady rate projects the moment the window empties")
    func projectsExhaustion() throws {
        var projector = UsageProjector()
        // Ten percent over twenty minutes: half a percent a minute.
        projector.record(window(used: 20, resetsIn: 4), at: start)
        projector.record(window(used: 30, resetsIn: 4), at: start.addingTimeInterval(20 * 60))

        let now = start.addingTimeInterval(20 * 60)
        let projection = projector.projection(for: window(used: 30, resetsIn: 4), now: now)
        let at = try #require(projection.date)
        // Seventy percent left at half a percent a minute is 140 minutes.
        #expect(abs(at.timeIntervalSince(now) - 140 * 60) < 1)
    }

    /// The reset is already on screen. A projection past it is not a warning,
    /// it is the ordinary case, and saying "empties at 3pm tomorrow" about a
    /// window that resets at 4pm today would be worse than saying nothing.
    @Test("a rate that does not empty the window before it resets says so")
    func holdsUntilReset() {
        var projector = UsageProjector()
        projector.record(window(used: 20, resetsIn: 1), at: start)
        projector.record(window(used: 21, resetsIn: 1), at: start.addingTimeInterval(30 * 60))
        #expect(
            projector.projection(for: window(used: 21, resetsIn: 1), now: start.addingTimeInterval(30 * 60))
                == .holdsUntilReset
        )
    }

    /// Spending nothing is not spending slowly. The two produce different
    /// sentences because they answer the user's question differently.
    @Test("a window that is not moving is distinguished from one that holds")
    func notMovingIsItsOwnAnswer() {
        var projector = UsageProjector()
        projector.record(window(used: 40, resetsIn: 4), at: start)
        projector.record(window(used: 40, resetsIn: 4), at: start.addingTimeInterval(30 * 60))
        #expect(
            projector.projection(for: window(used: 40, resetsIn: 4), now: start.addingTimeInterval(30 * 60))
                == .rateUnavailable(.notMoving)
        )
    }

    @Test("a window with no percentage or no reset projects nothing")
    func incompleteWindow() {
        let projector = UsageProjector()
        #expect(
            projector.projection(for: UsageWindow(name: "five_hour", usedPercent: nil, resetsAt: start), now: start)
                == .rateUnavailable(.windowIncomplete)
        )
        #expect(
            projector.projection(for: UsageWindow(name: "five_hour", usedPercent: 10, resetsAt: nil), now: start)
                == .rateUnavailable(.windowIncomplete)
        )
    }

    /// A fall in the share means the window reset between readings. That is a
    /// new window, not a negative rate, and the honest answer is that nothing is
    /// measured yet.
    @Test("a window that reset between readings projects nothing")
    func resetBetweenReadings() {
        var projector = UsageProjector()
        projector.record(window(used: 90, resetsIn: 4), at: start)
        projector.record(window(used: 2, resetsIn: 9), at: start.addingTimeInterval(30 * 60))
        #expect(
            projector.projection(for: window(used: 2, resetsIn: 9), now: start.addingTimeInterval(30 * 60))
                == .rateUnavailable(.notEnoughSamples)
        )
    }

    /// The whole point of naming a binding window: 21% on five hours and 66% on
    /// seven days are given equal weight today, and it is the seven-day one that
    /// ends the day.
    @Test("the window that empties first is the one that binds")
    func bindingWindowIsTheSoonest() throws {
        var projector = UsageProjector()
        let fiveHour = UsageWindow(name: "five_hour", usedPercent: 21, resetsAt: start.addingTimeInterval(4 * 3_600))
        let sevenDay = UsageWindow(name: "seven_day", usedPercent: 66, resetsAt: start.addingTimeInterval(3 * 24 * 3_600))

        projector.record(UsageWindow(name: "five_hour", usedPercent: 20, resetsAt: fiveHour.resetsAt), at: start)
        projector.record(UsageWindow(name: "seven_day", usedPercent: 64, resetsAt: sevenDay.resetsAt), at: start)
        let later = start.addingTimeInterval(30 * 60)
        projector.record(fiveHour, at: later)
        projector.record(sevenDay, at: later)

        let binding = try #require(projector.bindingWindow(among: [fiveHour, sevenDay], now: later))
        // Two percent in thirty minutes against seventy-nine percent of headroom
        // is faster to the wall than one percent in thirty against seventy-nine.
        #expect(binding.window.name == "seven_day")
    }

    @Test("no window with a projection means nothing binds")
    func nothingBinds() {
        let projector = UsageProjector()
        #expect(projector.bindingWindow(among: [window(used: 10, resetsIn: 4)], now: start) == nil)
    }

    /// The session responsible for the largest share of the current burn.
    @Test("the loudest session is named, with its share")
    func burnLeader() throws {
        let leader = try #require(
            BurnAttribution.leader(rates: ["a": 1_000, "b": 3_000, "c": 0])
        )
        #expect(leader.sessionID == "b")
        #expect(abs(leader.share - 0.75) < 0.0001)
    }

    @Test("nothing burning has no leader")
    func noLeaderWhenIdle() {
        #expect(BurnAttribution.leader(rates: [:]) == nil)
        #expect(BurnAttribution.leader(rates: ["a": 0, "b": 0]) == nil)
    }

    /// Two sessions at the same rate must not swap places between refreshes.
    @Test("a tie is broken deterministically")
    func tiesAreStable() throws {
        let first = try #require(BurnAttribution.leader(rates: ["b": 100, "a": 100]))
        let second = try #require(BurnAttribution.leader(rates: ["a": 100, "b": 100]))
        #expect(first.sessionID == second.sessionID)
    }
}
