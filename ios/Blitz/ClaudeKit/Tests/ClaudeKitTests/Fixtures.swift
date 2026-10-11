import Foundation
@testable import ClaudeKit

/// Builders for realistic Messages API SSE streams.
enum SSE {
    static func event(_ name: String, _ json: String) -> String {
        "event: \(name)\ndata: \(json)\n\n"
    }

    static func messageStart(id: String = "msg_1", model: String = "claude-opus-5-5") -> String {
        event("message_start", #"{"type":"message_start","message":{"id":"\#(id)","type":"message","role":"assistant","model":"\#(model)","content":[],"stop_reason":null,"usage":{"input_tokens":12,"output_tokens":1,"cache_read_input_tokens":0}}}"#)
    }

    static func textStart(_ index: Int) -> String {
        event("content_block_start", #"{"type":"content_block_start","index":\#(index),"content_block":{"type":"text","text":""}}"#)
    }

    static func thinkingStart(_ index: Int) -> String {
        event("content_block_start", #"{"type":"content_block_start","index":\#(index),"content_block":{"type":"thinking","thinking":"","signature":""}}"#)
    }

    static func fallbackBlock(_ index: Int, from: String, to: String) -> String {
        event("content_block_start", #"{"type":"content_block_start","index":\#(index),"content_block":{"type":"fallback","from":{"model":"\#(from)"},"to":{"model":"\#(to)"}}}"#)
            + blockStop(index)
    }

    static func textDelta(_ index: Int, _ text: String) -> String {
        let escaped = String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
        return event("content_block_delta", #"{"type":"content_block_delta","index":\#(index),"delta":{"type":"text_delta","text":\#(escaped)}}"#)
    }

    static func thinkingDelta(_ index: Int, _ text: String) -> String {
        let escaped = String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
        return event("content_block_delta", #"{"type":"content_block_delta","index":\#(index),"delta":{"type":"thinking_delta","thinking":\#(escaped)}}"#)
    }

    static func signatureDelta(_ index: Int, _ signature: String) -> String {
        event("content_block_delta", #"{"type":"content_block_delta","index":\#(index),"delta":{"type":"signature_delta","signature":"\#(signature)"}}"#)
    }

    static func blockStop(_ index: Int) -> String {
        event("content_block_stop", #"{"type":"content_block_stop","index":\#(index)}"#)
    }

    static func messageDelta(stopReason: String = "end_turn", extra: String = "") -> String {
        event("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"\#(stopReason)","stop_sequence":null\#(extra)},"usage":{"output_tokens":42}}"#)
    }

    static let ping = event("ping", #"{"type": "ping"}"#)
    static let messageStop = event("message_stop", #"{"type":"message_stop"}"#)

    static func error(_ type: String, _ message: String) -> String {
        event("error", #"{"type":"error","error":{"type":"\#(type)","message":"\#(message)"}}"#)
    }

    /// A complete response with thinking followed by text.
    static func fullResponse(text: [String] = ["Hallo", " Welt"], thinking: String = "Überlege…", signature: String = "sig123") -> String {
        var stream = messageStart() + ping + thinkingStart(0) + thinkingDelta(0, thinking) + signatureDelta(0, signature) + blockStop(0)
        stream += textStart(1)
        for piece in text { stream += textDelta(1, piece) }
        stream += blockStop(1) + messageDelta() + messageStop
        return stream
    }

    static func errorBody(type: String, message: String) -> String {
        #"{"type":"error","error":{"type":"\#(type)","message":"\#(message)"},"request_id":"req_body"}"#
    }
}
