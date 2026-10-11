import Foundation
import Testing
@testable import ClaudeKit

struct RequestEncodingTests {
    private func json(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private let history = [Message.user("Hi"), Message(role: .assistant, content: [.thinking(thinking: "", signature: "s"), .text("Hallo")]), Message.user("Weiter")]

    @Test func encodesAllFeaturesForOpus() throws {
        let request = MessageRequest.make(model: ModelCatalog.opus55, system: "  Sei knapp.  ", messages: history, effort: .low, maxTokens: 64_000, fastMode: true, showThinking: true)
        #expect(request.features == [.fastMode, .refusalFallback, .thinkingSummary, .promptCaching, .effort])
        let (body, betas) = try RequestEncoder.encode(request, messages: request.messages, features: request.features)
        let object = try json(body)
        #expect(object["model"] as? String == "claude-opus-5-5")
        #expect(object["max_tokens"] as? Int == 64_000)
        #expect(object["stream"] as? Bool == true)
        #expect(object["system"] as? String == "Sei knapp.")
        #expect(object["speed"] as? String == "fast")
        #expect(object["fallbacks"] as? String == "default")
        #expect((object["cache_control"] as? [String: String]) == ["type": "ephemeral"])
        #expect((object["output_config"] as? [String: String]) == ["effort": "low"])
        #expect((object["thinking"] as? [String: String]) == ["type": "adaptive", "display": "summarized"])
        #expect(object["temperature"] == nil)
        #expect(betas == ["fast-mode-2026-02-01", "server-side-fallback-2026-07-01"])
        let messages = try #require(object["messages"] as? [[String: Any]])
        #expect(messages.count == 3)
        let assistant = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(assistant[0]["type"] as? String == "thinking")
        #expect(assistant[0]["signature"] as? String == "s")
    }

    @Test func gatesFeaturesByModel() {
        let haiku = MessageRequest.make(model: ModelCatalog.haiku55, system: nil, messages: history, effort: .medium, maxTokens: 500_000, fastMode: true, showThinking: false)
        #expect(haiku.features == [.promptCaching, .effort])
        #expect(haiku.maxTokens == ModelCatalog.haiku55.maxOutputTokens)
        let sonnet = MessageRequest.make(model: ModelCatalog.sonnet55, system: nil, messages: history, effort: .medium, maxTokens: 1000, fastMode: true, showThinking: false)
        #expect(sonnet.features == [.promptCaching, .effort, .refusalFallback])
    }

    @Test func minimalRequestOmitsOptionalFields() throws {
        let request = MessageRequest.make(model: ModelCatalog.opus55, system: "   ", messages: history, effort: .high, maxTokens: 1000, fastMode: false, showThinking: false)
        let (body, betas) = try RequestEncoder.encode(request, messages: request.messages, features: [])
        let object = try json(body)
        #expect(Set(object.keys) == ["model", "max_tokens", "stream", "messages", "thinking"])
        #expect((object["thinking"] as? [String: String]) == ["type": "adaptive"])
        #expect(betas.isEmpty)
    }

    @Test func encodingIsDeterministic() throws {
        let request = MessageRequest.make(model: ModelCatalog.opus55, system: "x", messages: history, effort: .low, maxTokens: 10, fastMode: true, showThinking: true)
        let first = try RequestEncoder.encode(request, messages: request.messages, features: request.features).body
        for _ in 0..<20 {
            #expect(try RequestEncoder.encode(request, messages: request.messages, features: request.features).body == first)
        }
    }

    @Test func negotiatorMapsErrorsToFeatures() {
        let all = Set(OptionalFeature.allCases)
        #expect(FeatureNegotiator.featuresToDisable(forMessage: "Unexpected value(s) `fast-mode-2026-02-01` for the `anthropic-beta` header.", active: all) == [.fastMode])
        #expect(FeatureNegotiator.featuresToDisable(forMessage: "speed: fast mode is not available for this organization", active: all) == [.fastMode])
        #expect(FeatureNegotiator.featuresToDisable(forMessage: "fallbacks: Extra inputs are not permitted", active: all) == [.refusalFallback])
        #expect(FeatureNegotiator.featuresToDisable(forMessage: "thinking.display: invalid", active: all) == [.thinkingSummary])
        #expect(FeatureNegotiator.featuresToDisable(forMessage: "Unexpected value(s) `xyz` for the `anthropic-beta` header.", active: all) == [.fastMode, .refusalFallback])
        #expect(FeatureNegotiator.featuresToDisable(forMessage: "messages: roles must alternate", active: all).isEmpty)
        #expect(FeatureNegotiator.featuresToDisable(forMessage: "speed: invalid", active: [.effort]).isEmpty)
    }
}

struct RetryPolicyTests {
    private let policy = RetryPolicy(initialBackoff: .milliseconds(400), maxBackoff: .seconds(8), maxRetryAfter: .seconds(60))
    private let overloaded = ClaudeError.http(APIErrorInfo(status: 529, type: "overloaded_error", message: "Overloaded"))

    @Test func backoffGrowsWithEqualJitterAndCaps() {
        #expect(policy.delay(forAttempt: 1, error: overloaded, random: 0) == .milliseconds(200))
        #expect(policy.delay(forAttempt: 1, error: overloaded, random: 1) == .milliseconds(400))
        #expect(policy.delay(forAttempt: 3, error: overloaded, random: 1) == .milliseconds(1600))
        #expect(policy.delay(forAttempt: 10, error: overloaded, random: 1) == .seconds(8))
        #expect(policy.delay(forAttempt: 10, error: overloaded, random: 0) == .seconds(4))
    }

    @Test func honorsRetryAfterWithinLimit() {
        let short = ClaudeError.http(APIErrorInfo(status: 429, type: nil, message: "", retryAfter: .seconds(3)))
        #expect(policy.delay(forAttempt: 1, error: short, random: 0.5) == .seconds(3))
        let long = ClaudeError.http(APIErrorInfo(status: 429, type: nil, message: "", retryAfter: .seconds(600)))
        #expect(policy.delay(forAttempt: 1, error: long, random: 0.5) == nil)
    }

    @Test func parsesRetryHeaders() {
        #expect(HeaderParsing.retryAfter(headers: ["retry-after": "2"]) == .seconds(2))
        #expect(HeaderParsing.retryAfter(headers: ["retry-after": "1.5"]) == .milliseconds(1500))
        #expect(HeaderParsing.retryAfter(headers: ["retry-after-ms": "250", "retry-after": "9"]) == .milliseconds(250))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(HeaderParsing.retryAfter(headers: ["retry-after": "Tue, 14 Nov 2023 22:13:30 GMT"], now: now) == .seconds(10))
        #expect(HeaderParsing.retryAfter(headers: ["retry-after": "soon"]) == nil)
        #expect(HeaderParsing.retryAfter(headers: ["retry-after": "-5"]) == nil)
        #expect(HeaderParsing.shouldRetry(headers: ["x-should-retry": "false"]) == false)
        #expect(HeaderParsing.shouldRetry(headers: [:]) == nil)
    }

    @Test func classifiesErrors() {
        #expect(overloaded.isRetryable)
        #expect(ClaudeError.http(APIErrorInfo(status: 400, type: nil, message: "")).isRetryable == false)
        #expect(ClaudeError.http(APIErrorInfo(status: 401, type: nil, message: "")).isRetryable == false)
        #expect(ClaudeError.http(APIErrorInfo(status: 503, type: nil, message: "", shouldRetry: false)).isRetryable == false)
        #expect(ClaudeError.http(APIErrorInfo(status: 400, type: nil, message: "", shouldRetry: true)).isRetryable)
        #expect(ClaudeError.stream(APIErrorInfo(status: nil, type: "overloaded_error", message: "")).isRetryable)
        #expect(ClaudeError.stream(APIErrorInfo(status: nil, type: "invalid_request_error", message: "")).isRetryable == false)
        #expect(ClaudeError.network(code: -1005, description: "").isConnectivityLoss)
        #expect(ClaudeError.network(code: -1001, description: "").isRetryable)
        #expect(ClaudeError.network(code: -1001, description: "").isConnectivityLoss == false)
        #expect(ClaudeError.network(code: -1202, description: "").isRetryable == false) // untrusted certificate
        #expect(ClaudeError.truncatedStream.isRetryable)
        #expect(ClaudeError.missingAPIKey.isRetryable == false)
        let mismatch = APIErrorInfo(status: 400, type: "invalid_request_error", message: "messages.5.content.0: Invalid `signature` in `thinking` block. The block is bound to a different conversation.")
        #expect(mismatch.isThinkingSignatureMismatch)
    }
}

struct ConversationTests {
    private func message(_ role: Role, _ blocks: [ContentBlock], status: ChatMessage.Status = .complete, excluded: Bool = false) -> ChatMessage {
        ChatMessage(role: role, blocks: blocks, status: status, excludedFromContext: excluded)
    }

    @Test func sanitizesBlocksForReplay() {
        var conversation = Conversation(systemPrompt: nil)
        conversation.messages = [
            message(.user, [.text("Frage")]),
            message(.assistant, [.thinking(thinking: "a", signature: ""), .thinking(thinking: "b", signature: "sig"), .redactedThinking(data: "r"), .text("   "), .text("Antwort"), .unknown(type: "x")]),
        ]
        #expect(conversation.apiMessages() == [
            Message.user("Frage"),
            Message(role: .assistant, content: [.thinking(thinking: "b", signature: "sig"), .redactedThinking(data: "r"), .text("Antwort")]),
        ])
    }

    @Test func dropsReasoningBeforeLastFallbackMarker() {
        var conversation = Conversation(systemPrompt: nil)
        conversation.messages = [
            message(.user, [.text("Q")]),
            message(.assistant, [
                .thinking(thinking: "declined", signature: "s1"), .text("partial"),
                .fallback(from: "claude-opus-5-5", to: "claude-opus-4-8"),
                .thinking(thinking: "rescue", signature: "s2"), .text("rest"),
            ]),
        ]
        #expect(conversation.apiMessages()[1].content == [.text("partial"), .thinking(thinking: "rescue", signature: "s2"), .text("rest")])
    }

    @Test func skipsExcludedStreamingAndTextlessTurnsAndMergesRoles() {
        var conversation = Conversation(systemPrompt: nil)
        conversation.messages = [
            message(.user, [.text("A")]),
            message(.assistant, [.thinking(thinking: "t", signature: "s")], status: .stopped),
            message(.user, [.text("B")]),
            message(.assistant, [.text("refused partial")], status: .refused(category: "cyber"), excluded: true),
            message(.user, [.text("C")]),
            message(.assistant, [], status: .streaming),
        ]
        #expect(conversation.apiMessages() == [Message(role: .user, content: [.text("A"), .text("B"), .text("C")])])
    }

    @Test func apiHistoryIsAppendOnly() {
        // Property: replaying a conversation and then the same conversation with more turns
        // must yield a prefix-identical request (prompt cache + preserved thinking).
        var conversation = Conversation(systemPrompt: "s")
        var previous: [Message] = []
        let turns: [ChatMessage] = [
            message(.user, [.text("1")]),
            message(.assistant, [.thinking(thinking: "", signature: "a"), .text("one")]),
            message(.user, [.text("2")]),
            message(.assistant, [.text("x")], status: .failed(message: "boom")),
            message(.assistant, [.thinking(thinking: "", signature: "b"), .text("two")]),
            message(.user, [.text("3")]),
        ]
        for turn in turns {
            conversation.messages.append(turn)
            let current = conversation.apiMessages()
            let comparable = previous.dropLast() // the last (user) turn may grow by merging
            #expect(Array(current.prefix(comparable.count)) == Array(comparable))
            previous = current
        }
    }

    @Test func stripThinkingRemovesAllReasoning() {
        var conversation = Conversation(systemPrompt: nil)
        conversation.messages = [message(.assistant, [.thinking(thinking: "t", signature: "s"), .redactedThinking(data: "d"), .text("x")])]
        conversation.stripThinking()
        #expect(conversation.messages[0].blocks == [.text("x")])
    }

    @Test func titles() {
        #expect(Conversation.makeTitle(from: "  Hallo Welt\nmehr") == "Hallo Welt")
        #expect(Conversation.makeTitle(from: "\n\n") == "Neuer Chat")
        #expect(Conversation.makeTitle(from: String(repeating: "a", count: 100)).count == 48)
    }

    @Test func conversationRoundTripsThroughCodable() throws {
        var conversation = Conversation(systemPrompt: "sys")
        conversation.messages = [
            message(.user, [.text("Q")]),
            message(.assistant, [.text("A")], status: .refused(category: nil)),
            message(.assistant, [.text("B")], status: .failed(message: "x")),
        ]
        let data = try JSONEncoder().encode(conversation)
        #expect(try JSONDecoder().decode(Conversation.self, from: data) == conversation)
    }
}

struct MarkdownSegmenterTests {
    @Test func splitsProseAndCode() {
        let text = "Intro\n\n```swift\nlet x = 1\n```\nOutro"
        #expect(MarkdownSegmenter.segments(of: text) == [
            .prose("Intro\n"),
            .code(language: "swift", code: "let x = 1", isClosed: true),
            .prose("Outro"),
        ])
    }

    @Test func unclosedFenceWhileStreaming() {
        #expect(MarkdownSegmenter.segments(of: "a\n~~~~ py extra\nprint(1)\n```\n") == [
            .prose("a"),
            .code(language: "py", code: "print(1)\n```\n", isClosed: false),
        ])
    }

    @Test func closingFenceMustBeAtLeastAsLong() {
        #expect(MarkdownSegmenter.segments(of: "````\n```\ninner\n````") == [
            .code(language: nil, code: "```\ninner", isClosed: true),
        ])
    }

    @Test func inlineBackticksAreNotFences() {
        #expect(MarkdownSegmenter.segments(of: "use `x` and ``y``") == [.prose("use `x` and ``y``")])
        #expect(MarkdownSegmenter.segments(of: "    ```\nindented code") == [.prose("    ```\nindented code")])
    }
}
