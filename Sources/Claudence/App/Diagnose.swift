import Foundation
import ClaudenceCore

/// `Claudence --diagnose` prints what the adapters actually see on this machine.
/// This is how the real set of registry `status` values gets enumerated, which
/// spec section 6 requires before any further session state can ship.
enum Diagnose {
    static func run() {
        let store = ClaudenceStore()
        let registry = SessionRegistryAdapter()
        let reader = TranscriptReader(cursorStore: store)

        print("Claudence diagnose")
        print("claude home:  \(Constants.claudeHome.path)")
        print("store:        \(describe(store.health))")
        print("")

        let records = registry.loadRecords()
        let sessions = registry.discover()
        print("registry records: \(records.count)   live interactive sessions: \(sessions.count)")

        let kinds = Dictionary(grouping: records, by: { $0.kind ?? "nil" })
            .mapValues(\.count)
            .sorted { $0.key < $1.key }
        print("kinds:            \(kinds.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        print("status values:    \(SessionRegistryAdapter.observedStatusValuesInOrder.joined(separator: " "))")
        print("unparsed procStart: \(SessionRegistryAdapter.unparsedProcStartCount)")
        print("")

        if sessions.isEmpty {
            print("no live sessions (an ordinary state)")
        }

        for session in sessions {
            let started = Date().timeIntervalSince(session.startedAt)
            print("- \(session.projectName)  [\(session.status.rawValue)]  pid \(session.pid)")
            print("  \(session.displayPath)")
            print("  up \(Format.duration(started))   claude \(session.claudeCodeVersion ?? "unknown")")

            let clock = ContinuousClock()
            var delta = TranscriptDelta.empty
            let elapsed = clock.measure {
                delta = reader.readIncremental(
                    sessionID: session.id,
                    workingDirectory: session.workingDirectory
                )
            }
            print("  transcript: \(delta.recordsParsed) records, \(delta.recordsSkipped) skipped, \(elapsed)")
            print("  tokens:     fresh \(Format.tokens(delta.usage.freshInput))"
                  + "  cache-write \(Format.tokens(delta.usage.cacheCreation))"
                  + "  cache-read \(Format.tokens(delta.usage.cacheRead))"
                  + "  output \(Format.tokens(delta.usage.output))")
            print("  total:      \(Format.tokens(delta.usage.total))")
            if let activity = delta.latestActivity {
                print("  activity:   \(activity.display)")
            }
            if let model = delta.latestModel {
                print("  model:      \(model)")
            }
            print("")
        }

        // The usage call is the only network request the application makes.
        print("usage (the one outbound request):")
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var state: UsageState = .unavailable(reason: "not run")
        // Detached: an inherited main-actor context cannot run while the
        // main thread is parked on the semaphore.
        Task.detached {
            state = await UsageClient().fetch()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 20)

        switch state {
        case .unavailable(let reason):
            print("  unavailable: \(reason)")
        case .available(let windows, _):
            for window in windows {
                let reset = Format.timeUntil(window.resetsAt).map { " resets in \($0)" } ?? ""
                print("  \(window.displayName.padding(toLength: 14, withPad: " ", startingAt: 0))"
                      + "\(Format.percent(window.usedPercent)) used\(reset)")
            }
        }
    }

    private static func describe(_ health: StoreHealth) -> String {
        switch health {
        case .healthy: return "healthy"
        case .degraded(let reason): return "degraded (\(reason))"
        case .unavailable(let reason): return "unavailable (\(reason))"
        }
    }
}
