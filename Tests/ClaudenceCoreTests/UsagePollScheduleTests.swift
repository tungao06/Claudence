import Foundation
import Testing

@testable import ClaudenceCore

/// When the usage loop wakes, and why.
///
/// The defect this arithmetic exists to prevent is silent: with the refresh
/// interval on five minutes and a request rate limited, the provider's backoff
/// expires and the reading is available again, but nothing asks for it until
/// the next ordinary tick. The screen keeps saying `Usage unavailable` for
/// minutes after it stopped being true, and the only way to find out is to
/// press refresh -- which is the behaviour a monitor must not have.
@Suite("Usage poll schedule")
struct UsagePollScheduleTests {

    private let now = Date(timeIntervalSince1970: 1_788_000_000)

    @Test("with no backoff, the ordinary interval is the whole story")
    func noBackoffKeepsTheInterval() {
        let wake = UsagePollSchedule.next(interval: 300, retryAt: nil, now: now)
        #expect(wake == .interval(300))
        #expect(!wake.isRetry)
    }

    @Test("a backoff ending before the next tick brings the loop back early")
    func backoffWinsWhenItIsSooner() {
        let wake = UsagePollSchedule.next(
            interval: 300,
            retryAt: now.addingTimeInterval(20),
            now: now
        )
        #expect(wake == .retry(20))
        #expect(wake.isRetry)
    }

    /// The engine keeps its own rate limit, and an early wake that honoured it
    /// would arrive on time and then decline to ask. The flag is what makes
    /// the early wake worth anything.
    @Test("an early wake is marked as a retry so the caller can bypass its rate limit")
    func retryIsDistinguishable() {
        #expect(UsagePollSchedule.next(interval: 60, retryAt: now.addingTimeInterval(5), now: now).isRetry)
        #expect(!UsagePollSchedule.next(interval: 60, retryAt: nil, now: now).isRetry)
    }

    /// A backoff longer than the interval needs no early wake: the ordinary
    /// tick lands first, the provider declines the request itself at no cost,
    /// and one clock stays in charge of the common case.
    @Test("a backoff further out than the next tick changes nothing")
    func distantBackoffIsIgnored() {
        let wake = UsagePollSchedule.next(
            interval: 30,
            retryAt: now.addingTimeInterval(300),
            now: now
        )
        #expect(wake == .interval(30))
    }

    /// The loop must not spin. A deadline already behind us still costs one
    /// short sleep before the next attempt.
    @Test("a deadline in the past still sleeps, so the loop cannot spin")
    func pastDeadlineStillSleeps() {
        let wake = UsagePollSchedule.next(
            interval: 300,
            retryAt: now.addingTimeInterval(-90),
            now: now
        )
        #expect(wake == .retry(UsagePollSchedule.minimumDelay))
        #expect(wake.delay >= UsagePollSchedule.minimumDelay)
    }

    @Test("a nonsensical interval is floored rather than obeyed")
    func intervalIsFloored() {
        #expect(UsagePollSchedule.next(interval: 0, retryAt: nil, now: now) == .interval(1))
        #expect(UsagePollSchedule.next(interval: -5, retryAt: nil, now: now) == .interval(1))
    }

    /// Every wake this type can produce sleeps for something. A zero would put
    /// the refresh loop into a tight loop over the network, which is the one
    /// failure mode worse than a stale reading.
    @Test("no schedule ever returns a zero delay")
    func noZeroDelays() {
        let deadlines: [Date?] = [
            nil,
            now.addingTimeInterval(-3_600),
            now,
            now.addingTimeInterval(0.1),
            now.addingTimeInterval(3_600),
        ]
        for interval in [0.0, 1, 30, 60, 300] {
            for deadline in deadlines {
                let wake = UsagePollSchedule.next(interval: interval, retryAt: deadline, now: now)
                #expect(wake.delay >= UsagePollSchedule.minimumDelay)
            }
        }
    }
}
