import Foundation

// MARK: - Dynamic key

struct DynamicKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ value: String) { self.stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

// MARK: - Raw pieces

/// A window as it appears on the wire: a percentage plus a reset instant.
/// `resets_at` is Unix epoch **seconds**; an ISO-8601 string is tolerated so a
/// server-side change does not turn into a crash or a wrong date.
struct RawWindow: Decodable, Equatable {
    let usedPercent: Double?
    let resetsAt: Date?

    private enum Keys: String, CodingKey {
        case used_percentage
        case usedPercentage
        case percent
        case resets_at
        case resetsAt
    }

    init(usedPercent: Double?, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)

        var percent: Double?
        for key in [Keys.used_percentage, .usedPercentage, .percent] where percent == nil {
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                percent = value
            }
        }

        var reset: Date?
        for key in [Keys.resets_at, .resetsAt] where reset == nil {
            reset = RawWindow.decodeInstant(container, key)
        }

        // An object that carries neither is not a window. Refusing it here is
        // what lets the flat section be enumerated dynamically without
        // mistaking unrelated objects for usage windows.
        guard percent != nil || reset != nil else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "not a usage window")
            )
        }

        self.usedPercent = percent
        self.resetsAt = reset
    }

    private static func decodeInstant(
        _ container: KeyedDecodingContainer<Keys>,
        _ key: Keys
    ) -> Date? {
        if let seconds = try? container.decodeIfPresent(Double.self, forKey: key), seconds > 0 {
            return Date(timeIntervalSince1970: seconds)
        }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) {
            if let seconds = Double(text), seconds > 0 {
                return Date(timeIntervalSince1970: seconds)
            }
            return ISO8601DateFormatter().date(from: text)
        }
        return nil
    }
}

/// `limits[]` entry. Model names are never hard-coded; the scope is read and
/// slugged so a newly launched model shows up without a code change.
struct ScopedLimit: Decodable {
    struct Scope: Decodable {
        struct Model: Decodable {
            let displayName: String?
            let id: String?

            private enum Keys: String, CodingKey {
                case display_name
                case displayName
                case id
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                self.displayName = Model.firstString(c, [.display_name, .displayName])
                self.id = Model.firstString(c, [.id])
            }

            private static func firstString(
                _ container: KeyedDecodingContainer<Keys>,
                _ keys: [Keys]
            ) -> String? {
                for key in keys {
                    if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                        return value
                    }
                }
                return nil
            }
        }

        let model: Model?
    }

    let kind: String?
    let scope: Scope?
    let window: RawWindow?

    private enum Keys: String, CodingKey {
        case kind
        case scope
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        self.scope = try? c.decodeIfPresent(Scope.self, forKey: .scope)
        // percent / resets_at sit on the entry itself.
        self.window = try? RawWindow(from: decoder)
    }

    /// Lowercase, every run of non-alphanumerics collapsed to `_`, trimmed.
    /// "Sonnet 4.6" -> "sonnet_4_6". "!!!" -> "".
    static func slug(_ raw: String) -> String {
        var out = ""
        var pendingSeparator = false
        for character in raw.lowercased() {
            if character.isLetter || character.isNumber {
                if pendingSeparator && !out.isEmpty { out.append("_") }
                pendingSeparator = false
                out.append(character)
            } else {
                pendingSeparator = true
            }
        }
        return out
    }

    /// `seven_day_<slug>`, or nil when there is nothing to name it after.
    var windowName: String? {
        guard kind == "weekly_scoped" else { return nil }
        guard let raw = scope?.model?.displayName ?? scope?.model?.id else { return nil }
        let slug = ScopedLimit.slug(raw)
        guard !slug.isEmpty else { return nil }
        return "seven_day_" + slug
    }
}

// MARK: - Payload

/// The usage document: an arbitrary set of flat windows plus `limits[]`.
///
/// The flat section is enumerated rather than pinned to `five_hour` and
/// `seven_day`, because deployments already ship extra flat windows such as
/// `seven_day_opus`.
struct UsagePayload: Decodable {
    struct FlatEntry {
        let name: String
        let window: RawWindow
    }

    let flat: [FlatEntry]
    let limits: [ScopedLimit]

    init(flat: [FlatEntry] = [], limits: [ScopedLimit] = []) {
        self.flat = flat
        self.limits = limits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)

        var flat: [FlatEntry] = []
        for key in container.allKeys where key.stringValue != "limits" {
            if let window = try? container.decode(RawWindow.self, forKey: key) {
                flat.append(FlatEntry(name: key.stringValue, window: window))
            }
        }
        self.flat = flat
        self.limits = (try? container.decode([ScopedLimit].self, forKey: DynamicKey("limits"))) ?? []
    }

    var isEmpty: Bool { flat.isEmpty && limits.isEmpty }

    /// Deterministic ordering: `five_hour`, `seven_day`, then the rest by name.
    private static func rank(_ name: String) -> Int {
        switch name {
        case "five_hour": return 0
        case "seven_day": return 1
        default: return 2
        }
    }

    /// Flat windows win over a scoped entry of the same name.
    func windows() -> [UsageWindow] {
        var byName: [String: UsageWindow] = [:]
        var order: [String] = []

        for entry in flat {
            if byName[entry.name] == nil { order.append(entry.name) }
            byName[entry.name] = UsageWindow(
                name: entry.name,
                usedPercent: entry.window.usedPercent,
                resetsAt: entry.window.resetsAt
            )
        }

        for limit in limits {
            guard let name = limit.windowName else { continue }
            if let existing = byName[name], existing.usedPercent != nil { continue }
            if byName[name] == nil { order.append(name) }
            byName[name] = UsageWindow(
                name: name,
                usedPercent: limit.window?.usedPercent,
                resetsAt: limit.window?.resetsAt
            )
        }

        return order
            .compactMap { byName[$0] }
            .sorted {
                let a = UsagePayload.rank($0.name), b = UsagePayload.rank($1.name)
                return a == b ? $0.name < $1.name : a < b
            }
    }
}

// MARK: - Envelope

/// Some deployments nest the document under a top-level `data` key. Both
/// shapes decode to the same payload.
struct UsageEnvelope: Decodable {
    let payload: UsagePayload

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: DynamicKey.self),
           container.contains(DynamicKey("data")),
           let nested = try? container.decode(UsagePayload.self, forKey: DynamicKey("data")),
           !nested.isEmpty {
            self.payload = nested
            return
        }
        self.payload = try UsagePayload(from: decoder)
    }

    static func decode(_ data: Data) throws -> [UsageWindow] {
        try JSONDecoder().decode(UsageEnvelope.self, from: data).payload.windows()
    }
}

// MARK: - Refresh response

struct TokenRefreshResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?

    private enum Keys: String, CodingKey {
        case access_token
        case accessToken
        case refresh_token
        case refreshToken
        case expires_in
        case expiresIn
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let access = TokenRefreshResponse.firstString(c, [.access_token, .accessToken])
        guard let access, !access.isEmpty else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "no access token in refresh response")
            )
        }
        self.accessToken = access
        self.refreshToken = TokenRefreshResponse.firstString(c, [.refresh_token, .refreshToken])

        var lifetime: Double?
        for key in [Keys.expires_in, .expiresIn] where lifetime == nil {
            lifetime = try? c.decodeIfPresent(Double.self, forKey: key)
        }
        self.expiresAt = lifetime.map { Date().addingTimeInterval($0) }
    }

    private static func firstString(
        _ container: KeyedDecodingContainer<Keys>,
        _ keys: [Keys]
    ) -> String? {
        for key in keys {
            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                return value
            }
        }
        return nil
    }
}
