import Foundation

/// Error object as returned by the API, both in non-2xx bodies and in SSE `error` events.
public struct APIErrorBody: Codable, Sendable, Hashable {
    public var type: String?
    public var message: String?

    public init(type: String?, message: String?) {
        self.type = type
        self.message = message
    }
}

public struct MessageStartPayload: Sendable, Hashable {
    public var id: String?
    public var model: String?
    public var usage: Usage?
}

public struct MessageDeltaPayload: Sendable, Hashable {
    public var stopReason: StopReason?
    public var stopDetails: StopDetails?
    public var usage: Usage?
}

public enum ContentDelta: Sendable, Hashable {
    case text(String)
    case thinking(String)
    case signature(String)
    case inputJSON(String)
    case other(type: String)
}

/// One decoded server-sent event of the Messages streaming API.
/// Dispatch is on the JSON `type` field (authoritative), not on the SSE `event:` name.
public enum StreamEvent: Sendable, Hashable {
    case messageStart(MessageStartPayload)
    case contentBlockStart(index: Int, block: ContentBlock)
    case contentBlockDelta(index: Int, delta: ContentDelta)
    case contentBlockStop(index: Int)
    case messageDelta(MessageDeltaPayload)
    case messageStop
    case ping
    case error(APIErrorBody)
    case unknown(type: String)
}

extension StreamEvent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, message, index, contentBlock = "content_block", delta, usage, error
    }

    private struct MessageStub: Decodable {
        var id: String?
        var model: String?
        var usage: Usage?
    }

    private struct DeltaStub: Decodable {
        var type: String?
        var text: String?
        var thinking: String?
        var signature: String?
        var partialJSON: String?
        var stopReason: StopReason?
        var stopDetails: StopDetails?

        private enum CodingKeys: String, CodingKey {
            case type, text, thinking, signature
            case partialJSON = "partial_json"
            case stopReason = "stop_reason"
            case stopDetails = "stop_details"
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "message_start":
            let stub = try container.decode(MessageStub.self, forKey: .message)
            self = .messageStart(MessageStartPayload(id: stub.id, model: stub.model, usage: stub.usage))
        case "content_block_start":
            self = .contentBlockStart(
                index: try container.decode(Int.self, forKey: .index),
                block: try container.decode(ContentBlock.self, forKey: .contentBlock)
            )
        case "content_block_delta":
            let index = try container.decode(Int.self, forKey: .index)
            let stub = try container.decode(DeltaStub.self, forKey: .delta)
            let delta: ContentDelta
            switch stub.type {
            case "text_delta": delta = .text(stub.text ?? "")
            case "thinking_delta": delta = .thinking(stub.thinking ?? "")
            case "signature_delta": delta = .signature(stub.signature ?? "")
            case "input_json_delta": delta = .inputJSON(stub.partialJSON ?? "")
            default: delta = .other(type: stub.type ?? "")
            }
            self = .contentBlockDelta(index: index, delta: delta)
        case "content_block_stop":
            self = .contentBlockStop(index: try container.decode(Int.self, forKey: .index))
        case "message_delta":
            let stub = try container.decodeIfPresent(DeltaStub.self, forKey: .delta)
            self = .messageDelta(MessageDeltaPayload(
                stopReason: stub?.stopReason,
                stopDetails: stub?.stopDetails,
                usage: try container.decodeIfPresent(Usage.self, forKey: .usage)
            ))
        case "message_stop":
            self = .messageStop
        case "ping":
            self = .ping
        case "error":
            self = .error(try container.decodeIfPresent(APIErrorBody.self, forKey: .error) ?? APIErrorBody(type: nil, message: nil))
        default:
            self = .unknown(type: type)
        }
    }
}
