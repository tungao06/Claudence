import Foundation
import ClaudenceCore

/// `Claudence --diagnose` prints what the adapters actually see on this machine.
/// This is how the real set of registry `status` values gets enumerated, which
/// spec section 6 requires before any further session state can ship.
enum Diagnose {
    static func run() {
        // `--diagnose --counters [seconds]` answers the idle-cost question with
        // numbers: it starts the real watcher and the real engine headless, so
        // whatever it reports is the pipeline's cost with no UI attached.
        if CommandLine.arguments.contains("--counters") {
            DiagnoseCounters.run()
            return
        }
        let store = ClaudenceStore()
        let registry = SessionRegistryAdapter()
        // A memory cursor, not the persistent one: a diagnostic should read
        // every transcript in full so the numbers it prints are comparable to
        // each other. The live app resumes from the stored offset instead.
        let reader = TranscriptReader(cursorStore: TranscriptMemoryCursorStore())

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

            // The parent transcript contains none of its subagents' records.
            let locator = SubagentLocator()
            let subs = locator.subagents(
                forSession: session.id,
                workingDirectory: session.workingDirectory
            )
            if subs.isEmpty {
                print("  subagents:  none")
            } else {
                var subTotal = TokenUsage.zero
                print("  subagents:  \(subs.count)")
                for descriptor in subs {
                    let subDelta = reader.readIncremental(
                        atPath: descriptor.transcriptPath,
                        // The same key production uses. Keyed on the bare id
                        // here until 2026-09-03, which was a second namespace
                        // for one fact: harmless while this path uses an
                        // in-memory cursor store, and a silent full re-read the
                        // moment it does not.
                        cursorKey: SubagentTracker.cursorKey(for: descriptor)
                    )
                    subTotal += subDelta.usage
                    let type = descriptor.agentType ?? "unknown"
                    let task = descriptor.taskDescription ?? ""
                    print("    \(Format.tokens(subDelta.usage.total).padding(toLength: 8, withPad: " ", startingAt: 0))"
                          + "\(type.padding(toLength: 17, withPad: " ", startingAt: 0)) \(task)")
                }
                let combined = delta.usage.total + subTotal.total
                let share = combined > 0 ? Int(100.0 * Double(subTotal.total) / Double(combined)) : 0
                print("  subagent tokens: \(Format.tokens(subTotal.total)) (\(share)% of this session's true total)")
                print("  COMBINED:   \(Format.tokens(combined))")
            }
            if let activity = delta.latestActivity {
                print("  activity:   \(activity.display)")
            }
            let mix = delta.toolCounts
                .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                .prefix(6)
                .map { "\($0.key) \($0.value)" }
                .joined(separator: "  ")
            if !mix.isEmpty { print("  tool mix:   \(mix)") }
            if !delta.filePaths.isEmpty {
                let names = delta.filePaths.suffix(5).map { ($0 as NSString).lastPathComponent }
                print("  files:      \(names.joined(separator: "  "))")
            }
            if let tier = delta.serviceTier { print("  tier:       \(tier)") }
            if !delta.activityTrail.isEmpty {
                print("  timeline:   \(delta.activityTrail.count) entries, newest: \(delta.activityTrail.last?.activity.display ?? "")")
            }
            if let model = delta.latestModel {
                print("  model:      \(model)")
            }
            print("")
        }

        // The usage call is the only network request the application makes.
        // Two requests, not one: the usage GET, and a conditional token refresh
        // when the access token has expired. An earlier version of this line
        // claimed one, which was wrong.
        print("usage (the only outbound path, at most two requests):")
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var state: UsageState = .unavailable(reason: .untranslated("not run"))
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

/// `Claudence --diagnose --raw-usage` prints the shape of the usage response so
/// the parser can be matched to what the account actually returns. Usage
/// figures are not secrets; the token is never printed, and only structure plus
/// numeric values are shown.
enum DiagnoseRawUsage {
    static func run() {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var text = "(no result)"
        Task.detached {
            text = await fetchShape()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 30)
        print(text)
    }

    private static func fetchShape() async -> String {
        let store = CredentialStore()
        let credentials: OAuthCredentials
        do {
            credentials = try store.load()
        } catch {
            return "credentials unavailable: \(error)"
        }

        var request = URLRequest(url: Constants.Usage.endpoint)
        request.setValue("Bearer \(credentials.accessToken.value)", forHTTPHeaderField: "Authorization")
        request.setValue(Constants.Usage.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Constants.Usage.requestTimeout

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return "HTTP \(status): body is not a JSON object"
            }
            return "HTTP \(status)\n" + describe(object, indent: 0)
        } catch {
            return "request failed: \(error.localizedDescription)"
        }
    }

    /// Prints keys and value shapes. Strings are shown only when short, so a
    /// long opaque field cannot spill anything unexpected into the terminal.
    private static func describe(_ value: Any, indent: Int) -> String {
        let pad = String(repeating: "  ", count: indent)
        switch value {
        case let dictionary as [String: Any]:
            return dictionary.keys.sorted().map { key in
                "\(pad)\(key): " + describe(dictionary[key]!, indent: indent + 1)
                    .trimmingCharacters(in: .whitespaces)
            }.joined(separator: "\n")
        case let array as [Any]:
            guard !array.isEmpty else { return "[]" }
            return "[\(array.count)]\n" + array.enumerated().map { index, element in
                "\(pad)  [\(index)]\n" + describe(element, indent: indent + 2)
            }.joined(separator: "\n")
        case let number as NSNumber:
            return number.stringValue
        case let string as String:
            return string.count <= 40 ? "\"\(string)\"" : "<string \(string.count) chars>"
        case is NSNull:
            return "null"
        default:
            return "\(value)"
        }
    }
}


/// `Claudence --diagnose --counters [seconds]` runs the real registry watcher
/// and the real engine, with no window and no menu bar item, for a while.
///
/// It prints how many FSEvents callbacks arrived, how many survived the
/// debounce, how much work each refresh did, and how many of the resulting
/// snapshots were actually published. The process's own CPU time over the same
/// window is printed alongside, so the event pipeline's idle cost can be read
/// without the UI in the way. See spec section 13.
enum DiagnoseCounters {
    static func run() {
        let seconds = parseSeconds() ?? 120

        let store = ClaudenceStore()
        let engine = MonitorEngine(
            discovery: SessionRegistryAdapter(),
            transcripts: TranscriptReader(cursorStore: store),
            usageProvider: nil,   // No network: this measures the local pipeline.
            store: store
        )
        let watcher = RegistryWatcher()

        print("Claudence counters")
        print("watching:  \(Constants.sessionsDirectory.path)")
        print("debounce:  \(Constants.Watch.debounce)")
        print("window:    \(Int(seconds))s")
        print("")

        // One refresh up front so steady-state numbers are not distorted by the
        // cold pass (first transcript read, first store query).
        let ready = DispatchSemaphore(value: 0)
        Task.detached {
            await engine.refreshSessions()
            ready.signal()
        }
        _ = ready.wait(timeout: .now() + 30)

        EngineCounters.shared.reset()
        let startCPU = processCPUSeconds()
        let startWall = Date()

        _ = watcher.start { @Sendable in
            await engine.refreshSessions()
        }

        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        watcher.stop()

        let wall = Date().timeIntervalSince(startWall)
        let cpu = processCPUSeconds() - startCPU
        let reading = EngineCounters.shared.snapshot

        print("elapsed:   \(String(format: "%.1f", wall))s")
        print("cpu:       \(String(format: "%.2f", cpu))s"
              + "   (\(String(format: "%.2f", cpu / max(wall, 0.001) * 100))% of one core)")
        print("")
        for line in reading.lines(over: wall) {
            print(line)
        }
    }

    /// The first bare number after `--counters`, if any.
    private static func parseSeconds() -> TimeInterval? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--counters"), index + 1 < args.count else {
            return nil
        }
        return TimeInterval(args[index + 1]).map { max(1, $0) }
    }

    /// User plus system CPU consumed by this process so far.
    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func seconds(_ tv: timeval) -> Double {
            Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
        }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}
