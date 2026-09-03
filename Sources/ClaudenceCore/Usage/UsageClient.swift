import Foundation

// MARK: - Transport seam

/// One HTTP round trip. Injectable so tests never touch the network.
public protocol HTTPTransport: Sendable {
    /// Sends `request` and returns at most `maxBytes` of body.
    func send(_ request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse)
}

// MARK: - Redirect blocking

/// Refuses to follow a redirect whose target host is off the allowlist.
///
/// Without this, a 302 from an allowed host to an attacker-controlled one would
/// have `URLSession` replay the `Authorization` header at the new location.
public final class RedirectBlockingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let allowedHosts: Set<String>

    public init(allowedHosts: Set<String> = Constants.Usage.allowedHosts) {
        self.allowedHosts = allowedHosts
    }

    /// The whole decision, as a pure function: the new request when its host is
    /// allowed, `nil` otherwise.
    public func allow(_ request: URLRequest) -> URLRequest? {
        guard let host = request.url?.host()?.lowercased(), allowedHosts.contains(host) else {
            return nil
        }
        return request
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(allow(request))
    }
}

// MARK: - Body cap

enum BodyLimiter {
    /// Stops reading at `cap` bytes instead of buffering whatever the server
    /// decides to send.
    static func collect<S: AsyncSequence>(_ bytes: S, cap: Int) async throws -> Data
    where S.Element == UInt8 {
        var data = Data()
        data.reserveCapacity(min(cap, 64 * 1024))
        for try await byte in bytes {
            if data.count >= cap { break }
            data.append(byte)
        }
        return data
    }
}

// MARK: - URLSession transport

/// The only transport that touches the network. Owns the redirect blocker and
/// caps the body read.
public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession
    private let delegate: RedirectBlockingDelegate

    public init(allowedHosts: Set<String> = Constants.Usage.allowedHosts) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Constants.Usage.requestTimeout
        configuration.timeoutIntervalForResource = Constants.Usage.requestTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        self.delegate = RedirectBlockingDelegate(allowedHosts: allowedHosts)
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    public func send(_ request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
        guard let http = response as? HTTPURLResponse else {
            throw UsageFailure.transport("unexpected response")
        }
        let data = try await BodyLimiter.collect(bytes, cap: maxBytes)
        return (data, http)
    }
}

// MARK: - Failures

enum UsageFailure: Error, Equatable {
    case credentials(CredentialError)
    case blockedHost(String)
    case transport(String)
    case http(Int)
    case unauthorized
    case malformed
    case empty

    /// Short, human-readable, safe to show. Never carries a token.
    var reason: Phrase {
        switch self {
        case .credentials(let error):
            return error.displayReason
        case .blockedHost:
            return Phrase(en: "Blocked an unexpected host", th: "บล็อกโฮสต์ที่ไม่คาดคิด")
        case .transport:
            return Phrase(en: "Network unavailable", th: "เชื่อมต่อเครือข่ายไม่ได้")
        case .http(429):
            return Phrase(en: "Rate limited by the usage API", th: "ถูกจำกัดอัตราโดย usage API")
        case .http(let code):
            return Phrase(en: "Usage service error (%@)", th: "usage API ผิดพลาด (%@)")
                .asFormatted("\(code)")
        case .unauthorized:
            return Phrase(en: "Sign in to Claude Code again", th: "กรุณาเข้าสู่ระบบ Claude Code อีกครั้ง")
        case .malformed:
            return Phrase(en: "Usage response unreadable", th: "อ่านคำตอบจาก usage API ไม่ได้")
        case .empty:
            return Phrase(en: "Usage response had no windows", th: "คำตอบจาก usage API ไม่มีหน้าต่างการใช้งาน")
        }
    }

    /// Transient failures back off and keep serving the last good value.
    var isTransient: Bool {
        switch self {
        case .transport, .http: return true
        case .credentials, .blockedHost, .unauthorized, .malformed, .empty: return false
        }
    }
}

// MARK: - Client

/// Fetches account usage windows.
///
/// An actor because the cache, the backoff schedule and the in-memory refreshed
/// token are shared mutable state that several UI refreshes may reach at once.
public actor UsageClient: UsageProviding {
    public nonisolated let sourceName = "Usage API"

    private struct CacheEntry {
        let windows: [UsageWindow]
        let fetchedAt: Date
    }

    private let credentials: CredentialProviding
    private let transport: HTTPTransport
    private let endpoint: URL
    private let refreshEndpoint: URL
    private let now: @Sendable () -> Date

    private var cache: CacheEntry?
    private var failureCount = 0
    private var retryNotBefore: Date?
    private var lastReason: Phrase?
    /// A token refreshed this run. Held in memory only, never written back.
    private var refreshedAccessToken: RedactedSecret?
    private var refreshedRefreshToken: RedactedSecret?

    private static let backoffBase: TimeInterval = 5
    private static let backoffCap: TimeInterval = 300

    public init(
        credentials: CredentialProviding = CredentialStore(),
        transport: HTTPTransport = URLSessionTransport(),
        endpoint: URL = Constants.Usage.endpoint,
        refreshEndpoint: URL = Constants.Usage.refreshEndpoint,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.credentials = credentials
        self.transport = transport
        self.endpoint = endpoint
        self.refreshEndpoint = refreshEndpoint
        self.now = now
    }

    // MARK: Public API

    /// Never throws. Every failure is an ordinary degraded state.
    ///
    /// - Parameter minimumInterval: how old a cached reading may be before the
    ///   network is asked again. It defaults to `Constants.Usage.cacheTTL`, and
    ///   the caller lowers it when the user has chosen a shorter refresh
    ///   interval. Without this the client held its own fixed 60 second cache,
    ///   so choosing 30 seconds in Settings made the engine ask twice as often
    ///   and receive the same cached answer both times: the setting appeared to
    ///   do nothing, and the reason was a layer below where anyone would look.
    ///
    ///   The backoff after a failure is deliberately NOT lowered with it. That
    ///   one protects the endpoint rather than the reading, and a user picking a
    ///   faster refresh is not asking to retry a failing server harder.
    public func fetch(minimumInterval: TimeInterval = Constants.Usage.cacheTTL) async -> UsageState {
        let instant = now()

        if let cache, instant.timeIntervalSince(cache.fetchedAt) < minimumInterval {
            return .available(windows: cache.windows, fetchedAt: cache.fetchedAt)
        }

        if let retryNotBefore, instant < retryNotBefore {
            if let cache { return .available(windows: cache.windows, fetchedAt: cache.fetchedAt) }
            return .unavailable(reason: lastReason ?? UsageState.defaultUnavailableReason)
        }

        do {
            let windows = try await load()
            let fetchedAt = now()
            cache = CacheEntry(windows: windows, fetchedAt: fetchedAt)
            failureCount = 0
            retryNotBefore = nil
            lastReason = nil
            return .available(windows: windows, fetchedAt: fetchedAt)
        } catch let failure as UsageFailure {
            return record(failure)
        } catch {
            return record(.transport("request failed"))
        }
    }

    /// Drops the cached value. The next `fetch()` goes to the network.
    public func invalidateCache() {
        cache = nil
    }

    // MARK: Failure bookkeeping

    private func record(_ failure: UsageFailure) -> UsageState {
        lastReason = failure.reason
        failureCount += 1
        let exponent = Double(min(failureCount - 1, 10))
        let delay = min(Self.backoffCap, Self.backoffBase * pow(2, exponent))
        retryNotBefore = now().addingTimeInterval(delay)

        // A transient failure must not blank a value the user was already
        // looking at. An auth or parse failure has no honest number to serve.
        if failure.isTransient, let cache {
            return .available(windows: cache.windows, fetchedAt: cache.fetchedAt)
        }
        return .unavailable(reason: failure.reason)
    }

    // MARK: Fetch pipeline

    private func load() async throws -> [UsageWindow] {
        let stored: OAuthCredentials
        do {
            stored = try credentials.load()
        } catch let error as CredentialError {
            throw UsageFailure.credentials(error)
        } catch {
            throw UsageFailure.credentials(.notFound)
        }

        let token = refreshedAccessToken ?? stored.accessToken
        var (data, status) = try await requestUsage(token: token)

        if status == 401 {
            // Exactly one refresh, then exactly one retry.
            guard let refresh = refreshedRefreshToken ?? stored.refreshToken else {
                throw UsageFailure.unauthorized
            }
            let renewed = try await refreshAccessToken(using: refresh)
            (data, status) = try await requestUsage(token: renewed)
            if status == 401 { throw UsageFailure.unauthorized }
        }

        guard (200..<300).contains(status) else { throw UsageFailure.http(status) }

        let windows: [UsageWindow]
        do {
            windows = try UsageEnvelope.decode(data)
        } catch {
            throw UsageFailure.malformed
        }
        guard !windows.isEmpty else { throw UsageFailure.empty }
        return windows
    }

    private func requestUsage(token: RedactedSecret) async throws -> (Data, Int) {
        try await perform(
            url: endpoint,
            method: "GET",
            bearer: token,
            headers: [
                "anthropic-beta": Constants.Usage.betaHeader,
                "Accept": "application/json",
            ],
            body: nil
        )
    }

    private func refreshAccessToken(using refresh: RedactedSecret) async throws -> RedactedSecret {
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refresh.value,
            "client_id": Self.oauthClientID,
        ]
        guard let encoded = try? JSONSerialization.data(withJSONObject: body) else {
            throw UsageFailure.unauthorized
        }

        let (data, status) = try await perform(
            url: refreshEndpoint,
            method: "POST",
            bearer: nil,
            headers: [
                "Content-Type": "application/json",
                "Accept": "application/json",
                "anthropic-beta": Constants.Usage.betaHeader,
            ],
            body: encoded
        )

        guard (200..<300).contains(status),
              let parsed = try? JSONDecoder().decode(TokenRefreshResponse.self, from: data) else {
            throw UsageFailure.unauthorized
        }

        let token = RedactedSecret(parsed.accessToken)
        refreshedAccessToken = token
        if let newRefresh = parsed.refreshToken { refreshedRefreshToken = RedactedSecret(newRefresh) }
        return token
    }

    // MARK: The one request helper

    /// Every authorized request in the application goes through here.
    ///
    /// The host check happens before the transport is handed anything, so a
    /// misconfigured URL cannot put the token on the wire to a third party.
    /// Redirects are fenced separately by `RedirectBlockingDelegate`.
    private func perform(
        url: URL,
        method: String,
        bearer: RedactedSecret?,
        headers: [String: String],
        body: Data?
    ) async throws -> (Data, Int) {
        guard let host = url.host()?.lowercased(), Constants.Usage.allowedHosts.contains(host) else {
            throw UsageFailure.blockedHost(url.host() ?? "unknown")
        }

        var request = URLRequest(url: url, timeoutInterval: Constants.Usage.requestTimeout)
        request.httpMethod = method
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        if let bearer { request.setValue("Bearer \(bearer.value)", forHTTPHeaderField: "Authorization") }
        request.httpBody = body

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request, maxBytes: Constants.Usage.maxResponseBytes)
        } catch let failure as UsageFailure {
            throw failure
        } catch {
            throw UsageFailure.transport("request failed")
        }

        // Belt and braces: a transport that ignores the cap is still capped here.
        let capped = data.count > Constants.Usage.maxResponseBytes
            ? data.prefix(Constants.Usage.maxResponseBytes)
            : data[...]
        return (Data(capped), response.statusCode)
    }

    /// Claude Code's public OAuth client id. Not a secret, and not derivable
    /// from the stored credentials, which carry no client id field.
    private static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
}
