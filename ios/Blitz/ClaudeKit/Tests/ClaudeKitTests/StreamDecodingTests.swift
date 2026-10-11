import Foundation
import Testing
@testable import ClaudeKit

struct StreamDecodingTests {
    private func decodeStream(_ text: String) throws -> [StreamEvent] {
        var parser = SSEParser()
        return try parser.feed(Data(text.utf8)).map { try JSONDecoder().decode(StreamEvent.self, from: $0.data) }
    }

    @Test func decodesAllEventTypes() throws {
        let events = try decodeStream(SSE.fullResponse() + SSE.error("overloaded_error", "Overloaded") + SSE.event("x", #"{"type":"brand_new_event","foo":1}"#))
        #expect(events.first == .messageStart(MessageStartPayload(id: "msg_1", model: "claude-opus-5-5", usage: Usage(inputTokens: 12, outputTokens: 1, cacheReadInputTokens: 0))))
        #expect(events.contains(.ping))
        #expect(events.contains(.contentBlockDelta(index: 0, delta: .thinking("Überlege…"))))
        #expect(events.contains(.contentBlockDelta(index: 0, delta: .signature("sig123"))))
        #expect(events.contains(.contentBlockDelta(index: 1, delta: .text("Hallo"))))
        #expect(events.contains(.messageStop))
        #expect(events.contains(.error(APIErrorBody(type: "overloaded_error", message: "Overloaded"))))
        #expect(events.last == .unknown(type: "brand_new_event"))
    }

    @Test func decodesRefusalStopDetails() throws {
        let events = try decodeStream(SSE.messageDelta(stopReason: "refusal", extra: #","stop_details":{"type":"refusal","category":"cyber","explanation":"x","recommended_model":null}"#))
        guard case .messageDelta(let payload) = events.first else {
            Issue.record("expected message_delta")
            return
        }
        #expect(payload.stopReason == .refusal)
        #expect(payload.stopDetails?.category == "cyber")
        #expect(payload.usage?.outputTokens == 42)
    }

    @Test func unknownDeltaAndBlockTypesDoNotFail() throws {
        let stream = SSE.event("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"future_block","x":1}}"#)
            + SSE.event("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"future_delta"}}"#)
        let events = try decodeStream(stream)
        #expect(events == [.contentBlockStart(index: 0, block: .unknown(type: "future_block")), .contentBlockDelta(index: 0, delta: .other(type: "future_delta"))])
    }

    @Test func accumulatorBuildsFinalMessage() throws {
        var accumulator = MessageAccumulator()
        var updates: [StreamUpdate] = []
        for event in try decodeStream(SSE.fullResponse(text: ["A", "B", "C"])) {
            updates += accumulator.apply(event)
        }
        #expect(accumulator.isComplete)
        #expect(accumulator.hasContent)
        let final = accumulator.finalMessage(requestID: "req_1")
        #expect(final.content == [.thinking(thinking: "Überlege…", signature: "sig123"), .text("ABC")])
        #expect(final.stopReason == .endTurn)
        #expect(final.usage.inputTokens == 12)
        #expect(final.usage.outputTokens == 42)
        #expect(final.requestID == "req_1")
        #expect(final.text == "ABC")
        #expect(updates.first == .started(messageID: "msg_1", model: "claude-opus-5-5"))
        #expect(updates.filter { if case .textDelta = $0 { return true } else { return false } }.count == 3)
    }

    @Test func accumulatorTracksServerSideFallback() throws {
        var accumulator = MessageAccumulator()
        let stream = SSE.messageStart() + SSE.textStart(0) + SSE.textDelta(0, "partial")
            + SSE.fallbackBlock(1, from: "claude-opus-5-5", to: "claude-opus-4-8")
            + SSE.textStart(2) + SSE.textDelta(2, "rescued") + SSE.blockStop(2) + SSE.messageDelta() + SSE.messageStop
        var updates: [StreamUpdate] = []
        for event in try decodeStream(stream) { updates += accumulator.apply(event) }
        let final = accumulator.finalMessage(requestID: nil)
        #expect(final.servedByFallback)
        #expect(final.model == "claude-opus-4-8")
        #expect(final.content == [.text("partial"), .fallback(from: "claude-opus-5-5", to: "claude-opus-4-8"), .text("rescued")])
        #expect(updates.contains(.fallback(from: "claude-opus-5-5", to: "claude-opus-4-8")))
    }

    @Test func deltasForUnknownIndexesAreIgnored() {
        var accumulator = MessageAccumulator()
        #expect(accumulator.apply(.contentBlockDelta(index: 9, delta: .text("x"))).isEmpty)
        #expect(!accumulator.hasContent)
    }

    @Test func contentBlockRoundTripsThroughCodable() throws {
        let blocks: [ContentBlock] = [
            .text("t"), .thinking(thinking: "th", signature: "s"), .redactedThinking(data: "d"),
            .fallback(from: "a", to: "b"), .unknown(type: "u"),
        ]
        let data = try JSONEncoder().encode(blocks)
        #expect(try JSONDecoder().decode([ContentBlock].self, from: data) == blocks)
    }
}
