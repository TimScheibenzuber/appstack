import Foundation

public enum Role: String, Codable, Sendable, Hashable {
    case user
    case assistant
}

/// One block of message content, shaped exactly like the Messages API wire format.
///
/// The same `Codable` representation is used for persistence and for the request body, so a
/// stored conversation can be replayed byte-for-byte (important for prompt caching and for
/// preserved-thinking signatures, which bind thinking blocks to the exact conversation prefix).
public enum ContentBlock: Sendable, Hashable {
    case text(String)
    /// `signature` is required to echo the block back; a block without one (stream cut off
    /// before `signature_delta`) is never sent.
    case thinking(thinking: String, signature: String)
    case redactedThinking(data: String)
    /// Marker inserted by server-side refusal fallback. Audit-only; never echoed back.
    case fallback(from: String?, to: String?)
    /// A block type this client does not understand. Kept for display/debugging, never echoed.
    case unknown(type: String)

    public var isText: Bool {
        if case .text = self { return true }
        return false
    }

    public var isThinking: Bool {
        switch self {
        case .thinking, .redactedThinking: return true
        default: return false
        }
    }

    public var text: String? {
        if case .text(let value) = self { return value }
        return nil
    }
}

extension ContentBlock: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, text, thinking, signature, data, from, to
    }

    private struct ModelRef: Codable, Hashable {
        var model: String?
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try container.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "thinking":
            self = .thinking(
                thinking: try container.decodeIfPresent(String.self, forKey: .thinking) ?? "",
                signature: try container.decodeIfPresent(String.self, forKey: .signature) ?? ""
            )
        case "redacted_thinking":
            self = .redactedThinking(data: try container.decodeIfPresent(String.self, forKey: .data) ?? "")
        case "fallback":
            self = .fallback(
                from: try container.decodeIfPresent(ModelRef.self, forKey: .from)?.model,
                to: try container.decodeIfPresent(ModelRef.self, forKey: .to)?.model
            )
        default:
            self = .unknown(type: type)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .thinking(let thinking, let signature):
            try container.encode("thinking", forKey: .type)
            try container.encode(thinking, forKey: .thinking)
            try container.encode(signature, forKey: .signature)
        case .redactedThinking(let data):
            try container.encode("redacted_thinking", forKey: .type)
            try container.encode(data, forKey: .data)
        case .fallback(let from, let to):
            try container.encode("fallback", forKey: .type)
            try container.encode(ModelRef(model: from), forKey: .from)
            try container.encode(ModelRef(model: to), forKey: .to)
        case .unknown(let type):
            try container.encode(type, forKey: .type)
        }
    }
}

/// A message as sent to the API.
public struct Message: Sendable, Hashable, Codable {
    public var role: Role
    public var content: [ContentBlock]

    public init(role: Role, content: [ContentBlock]) {
        self.role = role
        self.content = content
    }

    public static func user(_ text: String) -> Message {
        Message(role: .user, content: [.text(text)])
    }
}
