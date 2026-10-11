import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import ClaudeKit

/// Scripted transport: each request consumes the next script.
final class MockTransport: StreamingTransport, @unchecked Sendable {
    enum Step: Sendable {
        case head(Int, [String: String] = ["content-type": "text/event-stream", "request-id": "req_test"])
        case body(String)
        case fail(Int)
        /// Blocks until the consumer cancels.
        case hang
    }

    struct Recorded: Sendable {
        var request: URLRequest
        var body: [String: Any] {
            (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
        }
    }

    private let state: Locked<(scripts: [[Step]], requests: [URLRequest], terminations: Int)>

    init(_ scripts: [[Step]]) {
        state = Locked((scripts, [], 0))
    }

    var requests: [Recorded] { state.withLock { $0.requests.map(Recorded.init) } }
    var terminations: Int { state.withLock { $0.terminations } }

    func events(for request: URLRequest) -> AsyncThrowingStream<TransportEvent, any Error> {
        let script = state.withLock { state -> [Step] in
            state.requests.append(request)
            return state.scripts.isEmpty ? [.fail(-1004)] : state.scripts.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                for step in script {
                    switch step {
                    case .head(let status, let headers):
                        continuation.yield(.response(HTTPResponseHead(statusCode: status, headers: headers)))
                    case .body(let text):
                        // Deliver in small uneven chunks to exercise incremental parsing.
                        let bytes = Array(text.utf8)
                        var index = 0
                        var size = 1
                        while index < bytes.count {
                            let end = min(index + size, bytes.count)
                            continuation.yield(.data(Data(bytes[index..<end])))
                            index = end
                            size = size % 17 + 3
                        }
                    case .fail(let code):
                        continuation.finish(throwing: NSError(domain: NSURLErrorDomain, code: code))
                        return
                    case .hang:
                        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                        return
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { [state] _ in
                task.cancel()
                state.withLock { $0.terminations += 1 }
            }
        }
    }
}

final class SleepRecorder: @unchecked Sendable {
    private let delays = Locked<[Duration]>([])
    var recorded: [Duration] { delays.withLock { $0 } }
    func sleep(_ duration: Duration) async throws {
        delays.withLock { $0.append(duration) }
        try Task.checkCancellation()
    }
}

/// Reports the path as down; waiting "restores" it if `result` is true.
struct ImmediateConnectivity: ConnectivityMonitoring {
    let result: Bool
    var isConnected: Bool { false }
    func waitUntilConnected(timeout: Duration) async -> Bool { result }
}

struct OnlineConnectivity: ConnectivityMonitoring {
    var isConnected: Bool { true }
    func waitUntilConnected(timeout: Duration) async -> Bool { true }
}

struct ClaudeClientTests {
    private let request = MessageRequest.make(
        model: ModelCatalog.opus55, system: "sys",
        messages: [Message.user("Hi"), Message(role: .assistant, content: [.thinking(thinking: "", signature: "sig"), .text("Hallo")]), Message.user("Und?")],
        effort: .low, maxTokens: 1000, fastMode: true, showThinking: true
    )

    private func makeClient(_ transport: MockTransport, sleeper: SleepRecorder = SleepRecorder(), key: String? = "  sk-ant-test\n", connectivity: (any ConnectivityMonitoring)? = nil) -> ClaudeClient {
        ClaudeClient(
            transport: transport,
            connectivity: connectivity,
            apiKeyProvider: { key },
            sleep: { try await sleeper.sleep($0) },
            random: { 0.5 }
        )
    }

    private func collect(_ client: ClaudeClient, _ request: MessageRequest) async -> (updates: [StreamUpdate], error: (any Error)?) {
        var updates: [StreamUpdate] = []
        do {
            for try await update in client.stream(request) { updates.append(update) }
            return (updates, nil)
        } catch {
            return (updates, error)
        }
    }

    private func final(_ updates: [StreamUpdate]) -> FinalMessage? {
        for case .completed(let message) in updates { return message }
        return nil
    }

    @Test func streamsAndCompletes() async throws {
        let transport = MockTransport([[.head(200), .body(SSE.fullResponse())]])
        let (updates, error) = await collect(makeClient(transport), request)
        #expect(error == nil)
        let message = try #require(final(updates))
        #expect(message.text == "Hallo Welt")
        #expect(message.requestID == "req_test")
        #expect(updates.contains(.thinkingDelta(blockIndex: 0, text: "Überlege…")))

        let sent = try #require(transport.requests.first)
        #expect(sent.request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(sent.request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(sent.request.value(forHTTPHeaderField: "anthropic-beta") == "fast-mode-2026-02-01,server-side-fallback-2026-07-01")
        #expect(sent.request.value(forHTTPHeaderField: "accept") == "text/event-stream")
        #expect(sent.request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(sent.request.httpMethod == "POST")
        #expect(sent.body["speed"] as? String == "fast")
    }

    @Test func retriesOverloadBeforeContent() async throws {
        let sleeper = SleepRecorder()
        let transport = MockTransport([
            [.head(529, ["request-id": "r1"]), .body(SSE.errorBody(type: "overloaded_error", message: "Overloaded"))],
            [.head(200), .body(SSE.messageStart() + SSE.error("overloaded_error", "Overloaded"))],
            [.head(200), .body(SSE.fullResponse())],
        ])
        let (updates, error) = await collect(makeClient(transport, sleeper: sleeper), request)
        #expect(error == nil)
        #expect(final(updates)?.text == "Hallo Welt")
        let retries = updates.compactMap { update -> Bool? in
            if case .retrying(_, _, _, let discard) = update { return discard }
            return nil
        }
        #expect(retries == [false, false])
        #expect(sleeper.recorded == [.milliseconds(300), .milliseconds(600)])
        #expect(transport.requests.count == 3)
    }

    @Test func honorsRetryAfterHeader() async throws {
        let sleeper = SleepRecorder()
        let transport = MockTransport([
            [.head(429, ["retry-after": "2"]), .body(SSE.errorBody(type: "rate_limit_error", message: "slow down"))],
            [.head(200), .body(SSE.fullResponse())],
        ])
        let fastless = MessageRequest.make(model: ModelCatalog.opus55, system: nil, messages: [.user("x")], effort: .low, maxTokens: 10, fastMode: false, showThinking: false)
        let (_, error) = await collect(makeClient(transport, sleeper: sleeper), fastless)
        #expect(error == nil)
        #expect(sleeper.recorded == [.seconds(2)])
    }

    @Test func doesNotRetryAuthenticationErrors() async throws {
        let transport = MockTransport([[.head(401, ["request-id": "req_401"]), .body(SSE.errorBody(type: "authentication_error", message: "invalid x-api-key"))]])
        let (_, error) = await collect(makeClient(transport), request)
        let claude = try #require(error as? ClaudeError)
        guard case .http(let info) = claude else {
            Issue.record("expected http error")
            return
        }
        #expect(info.status == 401)
        #expect(info.type == "authentication_error")
        #expect(info.message == "invalid x-api-key")
        #expect(info.requestID == "req_401")
        #expect(transport.requests.count == 1)
    }

    @Test func givesUpAfterMaxRetries() async throws {
        let failure: [MockTransport.Step] = [.head(500), .body("oops")]
        let transport = MockTransport(Array(repeating: failure, count: 10))
        let (_, error) = await collect(makeClient(transport), request)
        #expect((error as? ClaudeError)?.isRetryable == true)
        #expect(transport.requests.count == 4) // 1 + maxRetries(3)
    }

    @Test func dropsRejectedBetaFeatureForSession() async throws {
        let transport = MockTransport([
            [.head(400), .body(SSE.errorBody(type: "invalid_request_error", message: "Unexpected value(s) `fast-mode-2026-02-01` for the `anthropic-beta` header."))],
            [.head(200), .body(SSE.fullResponse())],
            [.head(200), .body(SSE.fullResponse())],
        ])
        let client = makeClient(transport)
        let (updates, error) = await collect(client, request)
        #expect(error == nil)
        #expect(updates.contains(.featuresDisabled([.fastMode], temporary: false)))
        let retried = transport.requests[1]
        #expect(retried.body["speed"] == nil)
        #expect(retried.request.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        #expect(await client.disabledOptionalFeatures == [.fastMode])

        // Remembered for the next message: no wasted round trip.
        _ = await collect(client, request)
        #expect(transport.requests.count == 3)
        #expect(transport.requests[2].body["speed"] == nil)

        await client.resetFeatureNegotiation()
        #expect(await client.disabledOptionalFeatures.isEmpty)
    }

    @Test func fastModeRateLimitFallsBackImmediately() async throws {
        let sleeper = SleepRecorder()
        let transport = MockTransport([
            [.head(429, ["retry-after": "30"]), .body(SSE.errorBody(type: "rate_limit_error", message: "fast mode limit"))],
            [.head(200), .body(SSE.fullResponse())],
        ])
        let client = makeClient(transport, sleeper: sleeper)
        let (updates, error) = await collect(client, request)
        #expect(error == nil)
        #expect(updates.contains(.featuresDisabled([.fastMode], temporary: true)))
        #expect(sleeper.recorded.isEmpty)
        #expect(transport.requests[1].body["speed"] == nil)
        #expect(await client.disabledOptionalFeatures.isEmpty)
    }

    @Test func recoversFromThinkingSignatureMismatch() async throws {
        let transport = MockTransport([
            [.head(400), .body(SSE.errorBody(type: "invalid_request_error", message: "messages.1.content.0: Invalid `signature` in `thinking` block. The block is bound to a different conversation. Remove the block, or set `thinking.block_binding.prefix_mismatch_behavior` to \\\"drop_block\\\". That setting requires the `thinking-binding-controls-2026-08-01` value in the `anthropic-beta` header."))],
            [.head(200), .body(SSE.fullResponse())],
        ])
        let client = makeClient(transport)
        let (updates, error) = await collect(client, request)
        #expect(error == nil)
        #expect(updates.contains(.thinkingStripped))
        let messages = try #require(transport.requests[1].body["messages"] as? [[String: Any]])
        let assistant = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(assistant.map { $0["type"] as? String } == ["text"])
        // The mismatch must not be misread as a rejected beta feature.
        #expect(await client.disabledOptionalFeatures.isEmpty)
    }

    @Test func restartsStreamBrokenMidResponseOnce() async throws {
        let sleeper = SleepRecorder()
        let partial = SSE.messageStart() + SSE.textStart(0) + SSE.textDelta(0, "Hal")
        let transport = MockTransport([
            [.head(200), .body(partial), .fail(-1005)],
            [.head(200), .body(SSE.fullResponse())],
        ])
        let (updates, error) = await collect(makeClient(transport, sleeper: sleeper), request)
        #expect(error == nil)
        #expect(updates.contains { if case .retrying(_, _, _, true) = $0 { return true } else { return false } })
        #expect(final(updates)?.text == "Hallo Welt")

        let twice = MockTransport([
            [.head(200), .body(partial), .fail(-1005)],
            [.head(200), .body(partial), .fail(-1005)],
        ])
        let (_, secondError) = await collect(makeClient(twice), request)
        #expect(secondError as? ClaudeError == .network(code: -1005, description: (secondError as? ClaudeError).flatMap { if case .network(_, let d) = $0 { return d } else { return nil } } ?? ""))
        #expect(twice.requests.count == 2)
    }

    @Test func truncatedStreamIsRetried() async throws {
        let transport = MockTransport([
            [.head(200), .body(SSE.messageStart() + SSE.ping)],
            [.head(200), .body(SSE.fullResponse())],
        ])
        let (updates, error) = await collect(makeClient(transport), request)
        #expect(error == nil)
        #expect(updates.contains { if case .retrying(_, _, .truncatedStream, false) = $0 { return true } else { return false } })
    }

    @Test func waitsForConnectivityWhenOffline() async throws {
        let sleeper = SleepRecorder()
        let transport = MockTransport([[.fail(-1009)], [.head(200), .body(SSE.fullResponse())]])
        let client = makeClient(transport, sleeper: sleeper, connectivity: ImmediateConnectivity(result: true))
        let (updates, error) = await collect(client, request)
        #expect(error == nil)
        #expect(updates.contains(.waitingForConnectivity))
        #expect(sleeper.recorded == [.milliseconds(100)])

        let offline = MockTransport([[.fail(-1009)], [.head(200), .body(SSE.fullResponse())]])
        let (_, offlineError) = await collect(makeClient(offline, connectivity: ImmediateConnectivity(result: false)), request)
        #expect((offlineError as? ClaudeError)?.isConnectivityLoss == true)
        #expect(offline.requests.count == 1)
    }

    @Test func connectivityErrorsOnAWorkingPathBackOffNormally() async throws {
        let sleeper = SleepRecorder()
        let transport = MockTransport([[.fail(-1003)], [.fail(-1003)], [.head(200), .body(SSE.fullResponse())]])
        let (updates, error) = await collect(makeClient(transport, sleeper: sleeper, connectivity: OnlineConnectivity()), request)
        #expect(error == nil)
        #expect(!updates.contains(.waitingForConnectivity))
        #expect(sleeper.recorded == [.milliseconds(300), .milliseconds(600)])
    }

    @Test func missingKeyFailsWithoutNetwork() async throws {
        let transport = MockTransport([])
        let (_, error) = await collect(makeClient(transport, key: "   "), request)
        #expect(error as? ClaudeError == .missingAPIKey)
        #expect(transport.requests.isEmpty)
    }

    @Test func rejectsUnexpectedContentType() async throws {
        let transport = MockTransport([[.head(200, ["content-type": "text/html"]), .body("<html>captive portal</html>")]])
        let (_, error) = await collect(makeClient(transport), request)
        guard case .malformedResponse = error as? ClaudeError else {
            Issue.record("expected malformedResponse, got \(String(describing: error))")
            return
        }
        #expect(transport.requests.count == 1)
    }

    @Test func cancellationStopsTheRequest() async throws {
        let transport = MockTransport([[.head(200), .body(SSE.messageStart() + SSE.textStart(0) + SSE.textDelta(0, "x")), .hang]])
        let client = makeClient(transport)
        let consumer = Task {
            var completed = false
            do {
                for try await update in client.stream(request) {
                    if case .completed = update { completed = true }
                }
            } catch is CancellationError {}
            return completed
        }
        try await Task.sleep(for: .milliseconds(50))
        consumer.cancel()
        // A cancelled consumer ends iteration (nil or CancellationError) and never completes.
        #expect(try await consumer.value == false)
        for _ in 0..<100 where transport.terminations == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(transport.terminations == 1)
        #expect(transport.requests.count == 1)
    }

    @Test func validatesKeys() async throws {
        let transport = MockTransport([
            [.head(200, ["content-type": "application/json"]), .body(#"{"data":[]}"#)],
            [.head(401, ["content-type": "application/json"]), .body(SSE.errorBody(type: "authentication_error", message: "invalid x-api-key"))],
            [.head(500), .body("err")],
        ])
        let client = makeClient(transport)
        #expect(try await client.validate(apiKey: " sk-ant-x ") == .valid)
        #expect(try await client.validate(apiKey: "bad") == .invalid(message: "invalid x-api-key"))
        await #expect(throws: ClaudeError.self) { try await client.validate(apiKey: "k") }
        let first = try #require(transport.requests.first)
        #expect(first.request.url?.absoluteString == "https://api.anthropic.com/v1/models?limit=1")
        #expect(first.request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-x")
        #expect(first.request.httpMethod == "GET")
    }

    @Test func prewarmIsThrottled() async throws {
        let transport = MockTransport([[.head(200), .body("{}")], [.head(200), .body("{}")]])
        let client = makeClient(transport)
        await client.prewarm()
        await client.prewarm()
        #expect(transport.requests.count == 1)
        #expect(transport.requests[0].request.url?.path == "/v1/models")
    }
}
