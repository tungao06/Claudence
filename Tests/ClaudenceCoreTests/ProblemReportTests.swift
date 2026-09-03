import Foundation
import Testing

@testable import ClaudenceCore

/// The file a user sends by hand. Nothing sends it, so the tests are about what
/// is in it: enough for the maintainer to read a defect out of, and nothing the
/// sender would be surprised to have handed over.
@Suite("Problem report")
struct ProblemReportTests {

    private func makeEnvironment(
        databasePath: String? = nil,
        health: StoreHealth = .healthy,
        storedSessions: Int? = 42
    ) -> ProblemReport.Environment {
        ProblemReport.Environment(
            appVersion: "0.1.0",
            appBuild: "1",
            operatingSystem: "26.6.2",
            storeHealth: health,
            isLiveOnly: false,
            databasePath: databasePath,
            databaseSizeBytes: 118_784,
            claudeCodeVersion: "2.1.257",
            liveSessionCount: 3,
            storedSessionCount: storedSessions,
            usageSampleCount: 300,
            rollupDayCount: 17,
            subagentTotalCount: 8
        )
    }

    @Test("the report names the home directory as a tilde and never as a person")
    func homeDirectoryIsAbbreviated() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let report = ProblemReport(
            environment: makeEnvironment(
                databasePath: home + "/Library/Application Support/Claudence/claudence.db"
            ),
            counters: EngineCounters.Reading()
        )
        let text = report.text()

        #expect(text.contains("~/Library/Application Support/Claudence/claudence.db"))
        #expect(!text.contains(home))
    }

    /// A count the store could not answer has to read as unavailable. A zero
    /// there is the same fabrication the interface refuses, moved into a file
    /// the maintainer will trust more than the screen.
    @Test("a count the store could not answer is absent, not zero")
    func unavailableCountsSaySo() {
        let report = ProblemReport(
            environment: makeEnvironment(
                health: .degraded(reason: "read sessions failed: disk I/O error"),
                storedSessions: nil
            ),
            counters: EngineCounters.Reading()
        )
        let text = report.text()

        #expect(text.contains("sessions:       unavailable"))
        #expect(text.contains("degraded (read sessions failed: disk I/O error)"))
        #expect(!text.contains("sessions:       0"))
    }

    /// The counters are the reason the file is worth sending: they say whether
    /// a store read was skipped, which is invisible on screen by design.
    @Test("every engine counter reaches the file")
    func countersAreIncluded() {
        var counters = EngineCounters.Reading()
        counters.skippedUnreadCursors = 4
        counters.withheldSubagentListings = 2
        counters.compactedSamples = 900
        let report = ProblemReport(environment: makeEnvironment(), counters: counters)
        let text = report.text()

        #expect(text.contains("skipped cursors"))
        #expect(text.contains("4"))
        #expect(text.contains("subagent listings"))
        #expect(text.contains("samples compacted"))
    }

    /// The file name sorts by time and says what it is, because the friend has
    /// to find it in Downloads and attach it to a message.
    @Test("the file name carries the moment it was written")
    func fileNameIsSortable() {
        let report = ProblemReport(
            environment: makeEnvironment(),
            counters: EngineCounters.Reading(),
            generatedAt: Date(timeIntervalSince1970: 1_788_000_000)
        )
        #expect(report.suggestedFileName.hasPrefix("claudence-report-"))
        #expect(report.suggestedFileName.hasSuffix(".txt"))
        #expect(report.suggestedFileName.contains("2026-"))
    }

    /// English whatever the interface language, and explicit about what it does
    /// not carry, because the person deciding whether to send it reads it first.
    @Test("the report says what it does not contain")
    func reportStatesItsOwnLimits() {
        let text = ProblemReport(
            environment: makeEnvironment(),
            counters: EngineCounters.Reading()
        ).text()

        #expect(text.contains("No message text, no tool results, no command strings"))
        #expect(text.contains("Nothing was sent anywhere"))
    }
}
