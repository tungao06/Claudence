import Foundation
import Testing

@testable import ClaudenceCore

// MARK: - Test doubles

/// Records every request and replays a scripted list of responses.
/// The network is never touched.
private actor StubTransport: HTTPTransport {
    struct Reply {
        let status: Int
        let body: Data

        static func json(_ text: String, status: Int = 200) -> Reply {
            Reply(status: status, body: Data(text.utf8))
        }
    }

    private var replies: [Reply]
    private let fallback: Reply?
    private let error: (any Error)?
    private(set) var requests: [URLRequest] = []
    private(set) var lastMaxBytes: Int?

    init(replies: [Reply] = [], fallback: Reply? = nil, error: (any Error)? = nil) {
        self.replies = replies
        self.fallback = fallback
        self.error = error
    }

    var requestCount: Int { requests.count }

    func urls() -> [String] { requests.compactMap { $0.url?.absoluteString } }

    func authorizationHeaders() -> [String] {
        requests.compactMap { $0.value(forHTTPHeaderField: "Authorization") }
    }

    func send(_ request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        lastMaxBytes = maxBytes
        if let error { throw error }
        let reply: Reply
        if replies.isEmpty {
            guard let fallback else {
                throw UsageFailure.transport("stub exhausted")
            }
            reply = fallback
        } else {
            reply = replies.removeFirst()
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: reply.status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (reply.body, response)
    }
}

private struct StubCredentials: CredentialProviding {
    var access = "access-token-AAAA"
    var refresh: String? = "refresh-token-BBBB"
    var error: CredentialError?

    func load() throws -> OAuthCredentials {
        if let error { throw error }
        return OAuthCredentials(accessToken: access, refreshToken: refresh)
    }
}

/// A clock the test moves by hand, so cache and backoff windows are exercised
/// without sleeping.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.instant = start
    }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return instant
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        instant = instant.addingTimeInterval(seconds)
    }

    var provider: @Sendable () -> Date { { [self] in now } }
}

// MARK: - Fixtures

private let fiveHourReset: TimeInterval = 1_756_000_000
private let sevenDayReset: TimeInterval = 1_756_400_000

private let realisticBody = """
{
  "five_hour":  { "used_percentage": 37.5, "resets_at": \(Int(fiveHourReset)) },
  "seven_day":  { "used_percentage": 12,   "resets_at": \(Int(sevenDayReset)) },
  "account_uuid": "not-a-window",
  "limits": [
    {
      "kind": "weekly_scoped",
      "scope": { "model": { "display_name": "Fable", "id": "claude-fable-5" } },
      "percent": 64.25,
      "resets_at": \(Int(sevenDayReset))
    },
    {
      "kind": "weekly_scoped",
      "scope": { "model": { "display_name": "Sonnet 4.6", "id": "claude-sonnet-4-6" } },
      "percent": 8,
      "resets_at": \(Int(sevenDayReset))
    }
  ]
}
"""

private func makeClient(
    transport: StubTransport,
    credentials: StubCredentials = StubCredentials(),
    clock: TestClock = TestClock(),
    endpoint: URL = Constants.Usage.endpoint
) -> UsageClient {
    UsageClient(
        credentials: credentials,
        transport: transport,
        endpoint: endpoint,
        now: clock.provider
    )
}

// MARK: - Parsing

@Suite("Usage response parsing")
struct UsageParsingTests {
    @Test("flat windows and limits[] both parse")
    func parsesRealisticResponse() throws {
        let windows = try UsageEnvelope.decode(Data(realisticBody.utf8))

        #expect(windows.map(\.name) == ["five_hour", "seven_day", "seven_day_fable", "seven_day_sonnet_4_6"])
        #expect(windows[0].usedPercent == 37.5)
        #expect(windows[1].usedPercent == 12)
        #expect(windows[2].usedPercent == 64.25)
        #expect(windows[3].usedPercent == 8)
        // No stray window from the unrelated `account_uuid` key.
        #expect(!windows.contains { $0.name == "account_uuid" })
    }

    @Test("the same payload nested under a top-level data key parses identically")
    func parsesNestedUnderData() throws {
        let flat = try UsageEnvelope.decode(Data(realisticBody.utf8))
        let nested = try UsageEnvelope.decode(Data("{\"data\": \(realisticBody)}".utf8))
        #expect(nested == flat)
    }

    @Test("model display names are slugged, not hard-coded")
    func slugsModelNames() throws {
        #expect(ScopedLimit.slug("Fable") == "fable")
        #expect(ScopedLimit.slug("Sonnet 4.6") == "sonnet_4_6")
        #expect(ScopedLimit.slug("Claude  Opus--4.5!") == "claude_opus_4_5")
        #expect(ScopedLimit.slug("!!!") == "")

        let windows = try UsageEnvelope.decode(Data(realisticBody.utf8))
        #expect(windows.contains { $0.name == "seven_day_fable" })
        #expect(windows.contains { $0.name == "seven_day_sonnet_4_6" })
    }

    @Test("an unsluggable model name is skipped, never emitted as a bare prefix")
    func skipsUnsluggableModel() throws {
        let body = """
        {
          "five_hour": { "used_percentage": 1, "resets_at": \(Int(fiveHourReset)) },
          "limits": [
            { "kind": "weekly_scoped", "scope": { "model": { "display_name": "!!!" } },
              "percent": 90, "resets_at": \(Int(sevenDayReset)) }
          ]
        }
        """
        let windows = try UsageEnvelope.decode(Data(body.utf8))
        #expect(windows.map(\.name) == ["five_hour"])
        #expect(!windows.contains { $0.name == "seven_day_" })
    }

    @Test("a flat window wins over a scoped entry of the same name")
    func flatWindowWinsOverScoped() throws {
        let body = """
        {
          "five_hour": { "used_percentage": 5, "resets_at": \(Int(fiveHourReset)) },
          "seven_day_opus": { "used_percentage": 42, "resets_at": \(Int(sevenDayReset)) },
          "limits": [
            { "kind": "weekly_scoped", "scope": { "model": { "display_name": "Opus" } },
              "percent": 99, "resets_at": \(Int(fiveHourReset)) }
          ]
        }
        """
        let windows = try UsageEnvelope.decode(Data(body.utf8))
        let opus = try #require(windows.first { $0.name == "seven_day_opus" })
        #expect(opus.usedPercent == 42)
        #expect(opus.resetsAt == Date(timeIntervalSince1970: sevenDayReset))
        #expect(windows.filter { $0.name == "seven_day_opus" }.count == 1)
    }

    @Test("resets_at is read as Unix epoch seconds")
    func convertsEpochSeconds() throws {
        let windows = try UsageEnvelope.decode(Data(realisticBody.utf8))
        #expect(windows[0].resetsAt == Date(timeIntervalSince1970: fiveHourReset))
        #expect(windows[1].resetsAt == Date(timeIntervalSince1970: sevenDayReset))
        // Not milliseconds, and not "now plus something".
        #expect(windows[0].resetsAt?.timeIntervalSince1970 == 1_756_000_000)
    }

    @Test("a non-weekly_scoped limit entry is ignored")
    func ignoresOtherLimitKinds() throws {
        let body = """
        {
          "five_hour": { "used_percentage": 1, "resets_at": \(Int(fiveHourReset)) },
          "limits": [
            { "kind": "something_else", "scope": { "model": { "display_name": "Fable" } },
              "percent": 90, "resets_at": \(Int(sevenDayReset)) }
          ]
        }
        """
        let windows = try UsageEnvelope.decode(Data(body.utf8))
        #expect(windows.map(\.name) == ["five_hour"])
    }
}

// MARK: - Client behaviour

@Suite("Usage client")
struct UsageClientTests {
    @Test("a successful fetch yields available windows")
    func fetchesWindows() async {
        let transport = StubTransport(replies: [.json(realisticBody)])
        let client = makeClient(transport: transport)

        let state = await client.fetch()
        guard case .available(let windows, _) = state else {
            Issue.record("expected available, got \(state)")
            return
        }
        #expect(windows.count == 4)
        #expect(await transport.requestCount == 1)
        #expect(await transport.lastMaxBytes == Constants.Usage.maxResponseBytes)
        #expect(await transport.authorizationHeaders() == ["Bearer access-token-AAAA"])
    }

    @Test("the beta header and Accept header are sent")
    func sendsRequiredHeaders() async {
        let transport = StubTransport(replies: [.json(realisticBody)])
        _ = await makeClient(transport: transport).fetch()

        let request = await transport.requests[0]
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == Constants.Usage.betaHeader)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.timeoutInterval == Constants.Usage.requestTimeout)
    }

    @Test("a successful response is cached for the TTL")
    func servesCacheWithinTTL() async {
        let clock = TestClock()
        let transport = StubTransport(replies: [.json(realisticBody)])
        let client = makeClient(transport: transport, clock: clock)

        _ = await client.fetch()
        clock.advance(Constants.Usage.cacheTTL - 1)
        let second = await client.fetch()

        #expect(await transport.requestCount == 1)
        #expect(second.windows.count == 4)
    }

    @Test("past the TTL the client goes back to the transport")
    func refetchesAfterTTL() async {
        let clock = TestClock()
        let transport = StubTransport(replies: [.json(realisticBody), .json(realisticBody)])
        let client = makeClient(transport: transport, clock: clock)

        _ = await client.fetch()
        clock.advance(Constants.Usage.cacheTTL + 1)
        _ = await client.fetch()

        #expect(await transport.requestCount == 2)
    }

    @Test("429 with a warm cache keeps serving the last good value")
    func rateLimitedWithWarmCache() async {
        let clock = TestClock()
        let transport = StubTransport(replies: [
            .json(realisticBody),
            .json("{\"error\":\"rate_limited\"}", status: 429),
        ])
        let client = makeClient(transport: transport, clock: clock)

        _ = await client.fetch()
        clock.advance(Constants.Usage.cacheTTL + 1)
        let state = await client.fetch()

        #expect(await transport.requestCount == 2)
        guard case .available(let windows, _) = state else {
            Issue.record("expected the cached value to survive a 429, got \(state)")
            return
        }
        #expect(windows.count == 4)
    }

    @Test("429 with a cold cache reports unavailable")
    func rateLimitedWithColdCache() async {
        let transport = StubTransport(replies: [.json("{}", status: 429)])
        let state = await makeClient(transport: transport).fetch()

        guard case .unavailable(let reason) = state else {
            Issue.record("expected unavailable, got \(state)")
            return
        }
        #expect(reason.en.localizedCaseInsensitiveContains("rate limited"))
        #expect(reason.th != reason.en)
    }

    @Test("failures back off: no second request until the delay elapses, then the delay grows")
    func backsOffWithIncreasingDelay() async {
        let clock = TestClock()
        let transport = StubTransport(fallback: .json("{}", status: 429))
        let client = makeClient(transport: transport, clock: clock)

        _ = await client.fetch()
        #expect(await transport.requestCount == 1)

        // Still inside the first backoff window.
        clock.advance(1)
        _ = await client.fetch()
        #expect(await transport.requestCount == 1)

        // First window elapsed: one more attempt, which fails and doubles it.
        clock.advance(10)
        _ = await client.fetch()
        #expect(await transport.requestCount == 2)

        // The doubled window is longer than the first one was.
        clock.advance(6)
        _ = await client.fetch()
        #expect(await transport.requestCount == 2)
    }

    @Test("a transport error with a warm cache keeps serving it, cold reports unavailable")
    func transportErrorBehaviour() async {
        let clock = TestClock()
        let failing = StubTransport(error: URLError(.notConnectedToInternet))
        let cold = await makeClient(transport: failing, clock: clock).fetch()
        guard case .unavailable(let reason) = cold else {
            Issue.record("expected unavailable, got \(cold)")
            return
        }
        #expect(!reason.en.isEmpty)
        #expect(!reason.th.isEmpty)

        let warmClock = TestClock()
        let transport = StubTransport(replies: [.json(realisticBody)], fallback: nil, error: nil)
        let client = makeClient(transport: transport, clock: warmClock)
        _ = await client.fetch()
        warmClock.advance(Constants.Usage.cacheTTL + 1)
        // The stub is exhausted, so this throws inside the transport.
        let warm = await client.fetch()
        #expect(warm.windows.count == 4)
    }

    @Test("401 triggers exactly one refresh and exactly one retry")
    func refreshesOnceOnUnauthorized() async {
        let transport = StubTransport(replies: [
            .json("{\"error\":\"expired\"}", status: 401),
            .json("{\"access_token\":\"fresh-token-CCCC\",\"expires_in\":3600}"),
            .json(realisticBody),
        ])
        let client = makeClient(transport: transport)

        let state = await client.fetch()

        #expect(state.windows.count == 4)
        let urls = await transport.urls()
        #expect(urls.count == 3)
        #expect(urls[0] == Constants.Usage.endpoint.absoluteString)
        #expect(urls[1] == Constants.Usage.refreshEndpoint.absoluteString)
        #expect(urls[2] == Constants.Usage.endpoint.absoluteString)
        // The retry carried the refreshed token, not the stale one.
        let auth = await transport.authorizationHeaders()
        #expect(auth == ["Bearer access-token-AAAA", "Bearer fresh-token-CCCC"])
    }

    @Test("a second 401 after the retry stops: no refresh loop")
    func stopsAfterOneRetry() async {
        let transport = StubTransport(replies: [
            .json("{}", status: 401),
            .json("{\"access_token\":\"fresh-token-CCCC\"}"),
            .json("{}", status: 401),
            .json(realisticBody),
        ])
        let state = await makeClient(transport: transport).fetch()

        #expect(await transport.requestCount == 3)
        guard case .unavailable(let reason) = state else {
            Issue.record("expected unavailable, got \(state)")
            return
        }
        #expect(!reason.en.isEmpty)
        #expect(!reason.th.isEmpty)
    }

    @Test("401 without a refresh token reports unavailable and never calls refresh")
    func noRefreshTokenMeansNoRefreshCall() async {
        let transport = StubTransport(replies: [.json("{}", status: 401)])
        let client = makeClient(
            transport: transport,
            credentials: StubCredentials(refresh: nil)
        )

        let state = await client.fetch()
        #expect(await transport.requestCount == 1)
        if case .available = state { Issue.record("expected unavailable, got \(state)") }
    }

    @Test("a host outside the allowlist is rejected before any network call")
    func blocksOffAllowlistHost() async {
        let transport = StubTransport(replies: [.json(realisticBody)])
        let client = makeClient(
            transport: transport,
            endpoint: URL(string: "https://evil.example.com/api/oauth/usage")!
        )

        let state = await client.fetch()

        #expect(await transport.requestCount == 0)
        guard case .unavailable(let reason) = state else {
            Issue.record("expected unavailable, got \(state)")
            return
        }
        #expect(reason.en.localizedCaseInsensitiveContains("host"))
    }

    @Test("a look-alike host is rejected too")
    func blocksLookAlikeHost() async {
        for candidate in [
            "https://api.anthropic.com.evil.example/api/oauth/usage",
            "http://localhost:8080/api/oauth/usage",
            "https://api-anthropic.com/api/oauth/usage",
        ] {
            let transport = StubTransport(replies: [.json(realisticBody)])
            let client = makeClient(transport: transport, endpoint: URL(string: candidate)!)
            _ = await client.fetch()
            #expect(await transport.requestCount == 0, "\(candidate) reached the transport")
        }
    }

    @Test("every allowlisted host is accepted")
    func allowsAllowlistedHosts() async {
        for host in Constants.Usage.allowedHosts {
            let transport = StubTransport(replies: [.json(realisticBody)])
            let client = makeClient(
                transport: transport,
                endpoint: URL(string: "https://\(host)/api/oauth/usage")!
            )
            _ = await client.fetch()
            #expect(await transport.requestCount == 1, "\(host) was blocked")
        }
    }

    @Test("a malformed body reports unavailable instead of throwing")
    func malformedBodyIsUnavailable() async {
        for body in ["{not json", "[]", "\"\"", "{}", "{\"five_hour\": \"nope\"}"] {
            let transport = StubTransport(replies: [.json(body)])
            let state = await makeClient(transport: transport).fetch()
            if case .available = state {
                Issue.record("expected unavailable for body \(body)")
            }
        }
    }

    @Test("an oversized body is capped rather than parsed whole")
    func capsOversizedBody() async {
        let padding = String(repeating: "x", count: Constants.Usage.maxResponseBytes + 5_000)
        let oversized = "{\"five_hour\":{\"used_percentage\":1,\"resets_at\":1},\"pad\":\"\(padding)\"}"
        let transport = StubTransport(replies: [.json(oversized)])

        let state = await makeClient(transport: transport).fetch()

        // Truncated JSON cannot parse, so the state degrades rather than the
        // client buffering an unbounded body.
        guard case .unavailable = state else {
            Issue.record("expected unavailable for a truncated oversized body, got \(state)")
            return
        }
        #expect(await transport.lastMaxBytes == Constants.Usage.maxResponseBytes)
    }

    @Test("the body reader stops at the cap")
    func bodyLimiterStopsAtCap() async throws {
        let cap = 1_024
        let stream = AsyncStream<UInt8> { continuation in
            for _ in 0..<(cap * 4) { continuation.yield(UInt8(0x61)) }
            continuation.finish()
        }
        let data = try await BodyLimiter.collect(stream, cap: cap)
        #expect(data.count == cap)
    }

    @Test("a credential failure degrades with a readable reason and never calls the transport")
    func credentialFailureDegrades() async {
        let cases: [(CredentialError, String)] = [
            (.notFound, "Not signed in to Claude Code"),
            (.accessDenied, "Keychain access denied"),
            (.malformed("no accessToken field"), "Stored credentials unreadable"),
        ]
        for (error, expected) in cases {
            let transport = StubTransport(replies: [.json(realisticBody)])
            let client = makeClient(transport: transport, credentials: StubCredentials(error: error))
            let state = await client.fetch()
            #expect(await transport.requestCount == 0)
            #expect(state == .unavailable(reason: error.displayReason))
            #expect(error.displayReason.en == expected)
        }
    }
}

// MARK: - Redirects

@Suite("Redirect blocking")
struct RedirectBlockingTests {
    private func redirect(to target: String) -> URLRequest {
        URLRequest(url: URL(string: target)!)
    }

    @Test("a redirect to a disallowed host is blocked")
    func blocksDisallowedRedirect() {
        let delegate = RedirectBlockingDelegate()
        #expect(delegate.allow(redirect(to: "https://evil.example.com/steal")) == nil)
        #expect(delegate.allow(redirect(to: "https://api.anthropic.com.evil.example/x")) == nil)
        #expect(delegate.allow(redirect(to: "http://127.0.0.1:9/x")) == nil)
    }

    @Test("a redirect within the allowlist is followed")
    func allowsAllowlistedRedirect() {
        let delegate = RedirectBlockingDelegate()
        let target = redirect(to: "https://console.anthropic.com/api/oauth/usage")
        #expect(delegate.allow(target)?.url == target.url)
    }

    @Test("the URLSession delegate hook hands back nil for a disallowed host")
    func delegateHookReturnsNil() async {
        let delegate = RedirectBlockingDelegate()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        defer { task.cancel() }  // never resumed, so nothing is sent

        let response = HTTPURLResponse(
            url: URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://evil.example.com/steal"]
        )!

        let blocked: URLRequest? = await withCheckedContinuation { continuation in
            delegate.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: self.redirect(to: "https://evil.example.com/steal")
            ) { continuation.resume(returning: $0) }
        }
        #expect(blocked == nil)

        let followed: URLRequest? = await withCheckedContinuation { continuation in
            delegate.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: self.redirect(to: "https://api.anthropic.com/other")
            ) { continuation.resume(returning: $0) }
        }
        #expect(followed?.url?.host() == "api.anthropic.com")
    }
}

// MARK: - Credentials

@Suite("Credential handling")
struct CredentialTests {
    private static let token = "sk-ant-oat01-SUPERSECRETVALUE"

    @Test("the credential type never describes its token")
    func credentialDescriptionIsRedacted() {
        let credentials = OAuthCredentials(
            accessToken: Self.token,
            refreshToken: "sk-ant-ort01-ALSOSECRET",
            expiresAt: Date(timeIntervalSince1970: 1_756_000_000)
        )

        for rendering in [
            credentials.description,
            credentials.debugDescription,
            "\(credentials)",
            String(describing: credentials),
            String(reflecting: credentials),
            "\(credentials.accessToken)",
            credentials.accessToken.description,
            credentials.accessToken.debugDescription,
            String(describing: credentials.refreshToken),
        ] {
            #expect(!rendering.contains(Self.token))
            #expect(!rendering.contains("SUPERSECRET"))
            #expect(!rendering.contains("ALSOSECRET"))
        }
        #expect(credentials.description.contains(RedactedSecret.placeholder))
        // The real value is still reachable when the request builder asks.
        #expect(credentials.accessToken.value == Self.token)
    }

    @Test("credential errors never carry a token")
    func errorsAreRedacted() {
        let errors: [CredentialError] = [
            .notFound, .accessDenied, .malformed("no accessToken field"), .keychain(-25300),
        ]
        for error in errors {
            #expect(!error.description.contains(Self.token))
            #expect(!error.debugDescription.contains(Self.token))
            #expect(!error.displayReason.en.isEmpty)
            #expect(!error.displayReason.th.isEmpty)
        }
    }

    @Test("the Claude Code Keychain payload parses")
    func parsesKeychainPayload() throws {
        let payload = """
        {"claudeAiOauth":{"accessToken":"\(Self.token)","refreshToken":"refresh-1",
         "expiresAt":1756000000000,"scopes":["user:inference"],"rateLimitTier":"max_20x"}}
        """
        let credentials = try CredentialStore.parse(Data(payload.utf8))
        #expect(credentials.accessToken.value == Self.token)
        #expect(credentials.refreshToken?.value == "refresh-1")
        // Milliseconds, not seconds.
        #expect(credentials.expiresAt == Date(timeIntervalSince1970: 1_756_000_000))
    }

    @Test("a bare credential object parses too")
    func parsesBareObject() throws {
        let credentials = try CredentialStore.parse(
            Data("{\"access_token\":\"a\",\"refresh_token\":\"b\",\"expires_at\":1756000000}".utf8)
        )
        #expect(credentials.accessToken.value == "a")
        #expect(credentials.refreshToken?.value == "b")
        #expect(credentials.expiresAt == Date(timeIntervalSince1970: 1_756_000_000))
    }

    @Test("a payload without an access token is malformed, not a crash")
    func rejectsMissingToken() {
        for payload in ["{}", "{\"claudeAiOauth\":{}}", "not json", "[]"] {
            #expect(throws: CredentialError.self) {
                try CredentialStore.parse(Data(payload.utf8))
            }
        }
    }

    @Test("an absent Keychain item falls back to the file, and a missing file is notFound")
    func fallsBackToFile() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claudence-usage-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(".credentials.json")

        let absent = CredentialStore(
            service: "test",
            account: nil,
            fallbackFile: file,
            keychainRead: { _, _ in .failure(.notFound) }
        )
        #expect(throws: CredentialError.self) { try absent.load() }

        try Data("{\"claudeAiOauth\":{\"accessToken\":\"from-file\"}}".utf8).write(to: file)
        #expect(try absent.load().accessToken.value == "from-file")
    }

    @Test("a denied Keychain read does not silently fall back to the file")
    func deniedDoesNotFallBack() throws {
        let denied = CredentialStore(
            service: "test",
            account: nil,
            fallbackFile: Constants.credentialsFile,
            keychainRead: { _, _ in .failure(.accessDenied) }
        )
        #expect(throws: CredentialError.accessDenied) { try denied.load() }
    }

    @Test("the Keychain value is preferred over the file")
    func keychainWinsOverFile() throws {
        let store = CredentialStore(
            service: "test",
            account: "tester",
            fallbackFile: Constants.credentialsFile,
            keychainRead: { _, _ in
                .success(Data("{\"claudeAiOauth\":{\"accessToken\":\"from-keychain\"}}".utf8))
            }
        )
        #expect(try store.load().accessToken.value == "from-keychain")
    }
}
