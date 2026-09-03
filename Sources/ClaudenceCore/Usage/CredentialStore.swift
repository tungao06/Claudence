import Foundation
import Security

// MARK: - Redacted secret

/// A string that refuses to describe itself.
///
/// Every path that could leak a token to a log, a crash report, an error
/// message or a debugger transcript goes through `description` or
/// `debugDescription`. Both are hardcoded to a placeholder, so the only way to
/// reach the real bytes is to ask for `.value` explicitly.
public struct RedactedSecret: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let placeholder = "<redacted>"

    private let storage: String

    public init(_ value: String) {
        self.storage = value
    }

    /// The real bytes. Only the request builder should ever call this.
    public var value: String { storage }

    public var isEmpty: Bool { storage.isEmpty }

    public var description: String { Self.placeholder }
    public var debugDescription: String { Self.placeholder }
}

// MARK: - Credentials

/// Claude Code's OAuth credentials, as read from the Keychain or the fallback
/// file. Never encoded, never written to disk, never logged.
public struct OAuthCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let accessToken: RedactedSecret
    public let refreshToken: RedactedSecret?
    public let expiresAt: Date?

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil) {
        self.accessToken = RedactedSecret(accessToken)
        self.refreshToken = refreshToken.map(RedactedSecret.init)
        self.expiresAt = expiresAt
    }

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }

    public var description: String {
        "OAuthCredentials(accessToken: \(RedactedSecret.placeholder), "
            + "refreshToken: \(refreshToken == nil ? "nil" : RedactedSecret.placeholder), "
            + "expiresAt: \(expiresAt.map(String.init(describing:)) ?? "nil"))"
    }

    public var debugDescription: String { description }
}

// MARK: - Errors

/// Reading credentials fails in exactly three interesting ways. None of the
/// messages may ever carry a token value.
public enum CredentialError: Error, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    /// No Keychain item and no fallback file.
    case notFound
    /// The user (or policy) refused the Keychain read.
    case accessDenied
    /// An item exists but does not contain a usable access token.
    case malformed(String)
    /// Any other Keychain status. Carries the OSStatus only.
    case keychain(OSStatus)

    public var description: String {
        switch self {
        case .notFound:
            return "Claude Code credentials not found"
        case .accessDenied:
            return "Keychain access denied"
        case .malformed(let detail):
            return "Credentials malformed: \(detail)"
        case .keychain(let status):
            return "Keychain error \(status)"
        }
    }

    public var debugDescription: String { description }

    /// Short, human-readable, safe for display in the menu bar popover.
    public var displayReason: Phrase {
        switch self {
        case .notFound:
            return Phrase(en: "Not signed in to Claude Code", th: "ยังไม่ได้เข้าสู่ระบบ Claude Code")
        case .accessDenied:
            return Phrase(en: "Keychain access denied", th: "ไม่ได้รับสิทธิ์เข้าถึง Keychain")
        case .malformed:
            return Phrase(en: "Stored credentials unreadable", th: "อ่านข้อมูลรับรองที่เก็บไว้ไม่ได้")
        case .keychain:
            return Phrase(en: "Keychain unavailable", th: "ใช้งาน Keychain ไม่ได้")
        }
    }
}

// MARK: - Seam

public protocol CredentialProviding: Sendable {
    func load() throws -> OAuthCredentials
}

// MARK: - Store

/// Reads Claude Code's OAuth credentials.
///
/// The Keychain (`class genp`, `service "Claude Code-credentials"`, account =
/// the macOS username) is the primary source. `~/.claude/.credentials.json` is
/// the fallback for machines that still keep the file.
public struct CredentialStore: CredentialProviding {
    private let service: String
    private let account: String?
    private let fallbackFile: URL
    private let keychainRead: @Sendable (_ service: String, _ account: String?) -> Result<Data, CredentialError>

    public init(
        service: String = Constants.Keychain.service,
        account: String? = NSUserName(),
        fallbackFile: URL = Constants.credentialsFile
    ) {
        self.init(
            service: service,
            account: account,
            fallbackFile: fallbackFile,
            keychainRead: CredentialStore.copyKeychainData
        )
    }

    /// Testing seam: the Keychain read is injectable so tests never touch the
    /// real Keychain (and never see a real token).
    init(
        service: String,
        account: String?,
        fallbackFile: URL,
        keychainRead: @escaping @Sendable (_ service: String, _ account: String?) -> Result<Data, CredentialError>
    ) {
        self.service = service
        self.account = account
        self.fallbackFile = fallbackFile
        self.keychainRead = keychainRead
    }

    public func load() throws -> OAuthCredentials {
        switch keychainRead(service, account) {
        case .success(let data):
            return try Self.parse(data)
        case .failure(let error):
            guard error == .notFound else { throw error }
            guard let fileData = try? Data(contentsOf: fallbackFile) else { throw CredentialError.notFound }
            return try Self.parse(fileData)
        }
    }

    // MARK: Keychain

    private static let copyKeychainData: @Sendable (String, String?) -> Result<Data, CredentialError> = { service, account in
        if let account {
            let scoped = read(service: service, account: account)
            if case .failure(.notFound) = scoped {
                return read(service: service, account: nil)
            }
            return scoped
        }
        return read(service: service, account: nil)
    }

    private static func read(service: String, account: String?) -> Result<Data, CredentialError> {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        if let account { query[kSecAttrAccount as String] = account }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data, !data.isEmpty else {
                return .failure(.malformed("empty Keychain payload"))
            }
            return .success(data)
        case errSecItemNotFound:
            return .failure(.notFound)
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed, errSecInteractionRequired:
            return .failure(.accessDenied)
        default:
            return .failure(.keychain(status))
        }
    }

    // MARK: Parsing

    /// Accepts either the Claude Code wrapper (`{"claudeAiOauth": {...}}`) or a
    /// bare credential object. Errors mention field names only, never values.
    static func parse(_ data: Data) throws -> OAuthCredentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CredentialError.malformed("not a JSON object")
        }

        let object = (root["claudeAiOauth"] as? [String: Any])
            ?? (root["claudeAiOAuth"] as? [String: Any])
            ?? root

        let access = string(object, "accessToken", "access_token")
        guard let access, !access.isEmpty else {
            throw CredentialError.malformed("no accessToken field")
        }

        let refresh = string(object, "refreshToken", "refresh_token")
        let expiry = expiryDate(object)

        return OAuthCredentials(
            accessToken: access,
            refreshToken: (refresh?.isEmpty == false) ? refresh : nil,
            expiresAt: expiry
        )
    }

    private static func string(_ object: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = object[key] as? String { return value }
        }
        return nil
    }

    /// Claude Code stores `expiresAt` as milliseconds since the epoch. Other
    /// shapes (`expires_at` in seconds, an ISO-8601 string) are accepted too.
    private static func expiryDate(_ object: [String: Any]) -> Date? {
        for key in ["expiresAt", "expires_at", "expiry"] {
            if let number = object[key] as? NSNumber {
                let raw = number.doubleValue
                guard raw > 0 else { continue }
                // Anything past the year 33658 in seconds is milliseconds.
                return Date(timeIntervalSince1970: raw > 1_000_000_000_000 ? raw / 1_000 : raw)
            }
            if let text = object[key] as? String {
                if let raw = Double(text), raw > 0 {
                    return Date(timeIntervalSince1970: raw > 1_000_000_000_000 ? raw / 1_000 : raw)
                }
                if let parsed = ISO8601DateFormatter().date(from: text) { return parsed }
            }
        }
        return nil
    }
}
