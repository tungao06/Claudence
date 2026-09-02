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
