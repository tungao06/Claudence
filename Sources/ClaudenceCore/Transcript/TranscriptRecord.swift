import CryptoKit
import Foundation

// MARK: - Privacy note
//
// These types are the ONLY decoding surface for a transcript line, and they are
// deliberately narrow. The privacy guarantee of spec section 3.1 is structural,
// not conventional: there is no stored property anywhere in this file that can
// hold prompt text, response text, thinking text, a tool result, a file-history
// payload, an attachment payload, or a raw command string. `CodingKeys` name
// only allowlisted keys, so `Decodable` never even looks at the rest.
//
// The single field that is derived from forbidden data is
// `TranscriptToolInput.commandSHA256`. The command string exists only as a
// `let` inside `init(from:)`, is hashed immediately, and is never stored,
// returned, or logged.

// MARK: - Line type probe

/// First-pass decode. Every line is classified by `type` before anything else
/// is decoded, so a `user`, `attachment`, `file-history-snapshot` or
/// `file-history-delta` line is never decoded past this struct.
struct TranscriptLineType: Decodable {
    let type: String?

    private enum CodingKeys: String, CodingKey { case type }

    var isAssistant: Bool { type == "assistant" }
}

/// Used by `TranscriptLocator` to confirm that a file really belongs to a
/// session. Decodes the session id and nothing else.
struct TranscriptSessionProbe: Decodable {
    let sessionID: String?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
    }
}

// MARK: - Assistant record

/// An `assistant` record, reduced to the allowlisted fields.
struct TranscriptRecord: Decodable {
    let type: String?
    let timestamp: String?
    let sessionID: String?
    let cwd: String?
    let gitBranch: String?
    let version: String?
    let isSidechain: Bool?
    let message: TranscriptMessage?

    private enum CodingKeys: String, CodingKey {
        case type, timestamp, cwd, gitBranch, version, isSidechain, message
        case sessionID = "sessionId"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try? container.decodeIfPresent(String.self, forKey: .type)
        timestamp = try? container.decodeIfPresent(String.self, forKey: .timestamp)
        sessionID = try? container.decodeIfPresent(String.self, forKey: .sessionID)
        cwd = try? container.decodeIfPresent(String.self, forKey: .cwd)
        gitBranch = try? container.decodeIfPresent(String.self, forKey: .gitBranch)
        version = try? container.decodeIfPresent(String.self, forKey: .version)
        isSidechain = try? container.decodeIfPresent(Bool.self, forKey: .isSidechain)
        message = try? container.decodeIfPresent(TranscriptMessage.self, forKey: .message)
    }

    var date: Date? { TranscriptTimestamp.parse(timestamp) }
}

/// `record.message`. Carries the model id, the usage block, and the content
/// blocks. No `role`, no `id`, no `stop_reason`, nothing else.
struct TranscriptMessage: Decodable {
    let model: String?
    let usage: TranscriptUsage?
    let content: [TranscriptContentBlock]?

    private enum CodingKeys: String, CodingKey { case model, usage, content }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try? container.decodeIfPresent(String.self, forKey: .model)
        usage = try? container.decodeIfPresent(TranscriptUsage.self, forKey: .usage)
        // `content` is an array on every observed record, but an API-error
        // record could carry a bare string. `try?` degrades that to nil rather
        // than discarding the token counts on the same record.
        content = try? container.decodeIfPresent([TranscriptContentBlock].self, forKey: .content)
    }
}

// MARK: - Usage

/// `message.usage`. Raw counts only; totals are never computed here. The
/// formula lives in `TokenUsage` and nowhere else. See spec section 5.1.
struct TranscriptUsage: Decodable {
    let inputTokens: Int
    let cacheCreationInputTokens: Int
    let cacheReadInputTokens: Int
    let outputTokens: Int
    let thinkingTokens: Int

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case outputTokens = "output_tokens"
        case outputTokensDetails = "output_tokens_details"
    }

    private struct OutputTokensDetails: Decodable {
        let thinkingTokens: Int

        private enum CodingKeys: String, CodingKey {
            case thinkingTokens = "thinking_tokens"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            thinkingTokens = (try? container.decodeIfPresent(Int.self, forKey: .thinkingTokens)) ?? 0
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = (try? container.decodeIfPresent(Int.self, forKey: .inputTokens)) ?? 0
        cacheCreationInputTokens =
            (try? container.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens)) ?? 0
        cacheReadInputTokens =
            (try? container.decodeIfPresent(Int.self, forKey: .cacheReadInputTokens)) ?? 0
        outputTokens = (try? container.decodeIfPresent(Int.self, forKey: .outputTokens)) ?? 0
        let details = try? container.decodeIfPresent(OutputTokensDetails.self, forKey: .outputTokensDetails)
        thinkingTokens = details?.thinkingTokens ?? 0
    }

    /// Maps into the one shared token type. Totals are derived there.
    var tokenUsage: TokenUsage {
        TokenUsage(
            freshInput: max(0, inputTokens),
            cacheCreation: max(0, cacheCreationInputTokens),
            cacheRead: max(0, cacheReadInputTokens),
            output: max(0, outputTokens),
            thinking: max(0, thinkingTokens)
        )
    }
}

// MARK: - Content blocks

/// One entry of `message.content`.
///
/// A `text` block decodes its `type` and nothing more. A `thinking` block
/// decodes its `type` and nothing more. There is no `text` property and no
/// `thinking` property on this struct, by design.
struct TranscriptContentBlock: Decodable {
    let type: String?
    let name: String?
    let input: TranscriptToolInput?

    private enum CodingKeys: String, CodingKey { case type, name, input }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try? container.decodeIfPresent(String.self, forKey: .type)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        input = try? container.decodeIfPresent(TranscriptToolInput.self, forKey: .input)
    }

    var isToolUse: Bool { type == "tool_use" }
}

/// `content[].input`, reduced to `file_path` plus the SHA256 of `command`.
///
/// Every other input key of every tool — `content`, `old_string`, `new_string`,
/// `prompt`, `query`, `description`, `plan` — is absent from `CodingKeys` and is
/// therefore never decoded.
struct TranscriptToolInput: Decodable {
    let filePath: String?
    /// 64 lowercase hex characters, or nil. The command string itself is never
    /// stored anywhere; it lives only as a local inside `init(from:)`.
    let commandSHA256: String?

    private enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case command
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        filePath = try? container.decodeIfPresent(String.self, forKey: .filePath)
        if let command = try? container.decodeIfPresent(String.self, forKey: .command),
           !command.isEmpty {
            commandSHA256 = TranscriptToolInput.sha256Hex(command)
        } else {
            commandSHA256 = nil
        }
    }

    /// Lowercase hex SHA256. The only permitted representation of a command.
    static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - Timestamps

/// ISO8601 with fractional seconds, e.g. "2026-08-18T07:39:02.837Z".
/// `Date.ISO8601FormatStyle` is a `Sendable` value type, unlike
/// `ISO8601DateFormatter`, so it is safe to hold in a `static let`.
enum TranscriptTimestamp {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let date = try? fractional.parse(value) { return date }
        return try? whole.parse(value)
    }
}
