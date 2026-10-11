import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import ClaudeKit

/// Runs the real `URLSessionTransport` against `scripts/mock_server.py` over loopback.
/// Started by `scripts/integration-test.sh`, which passes the port in `CLAUDEKIT_MOCK_PORT`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CLAUDEKIT_MOCK_PORT"] != nil), .serialized)
struct IntegrationTests {
    private let port = Int(ProcessInfo.processInfo.environment["CLAUDEKIT_MOCK_PORT"] ?? "") ?? 0

    private func client(path: String = "", key: String = "sk-ant-local") -> ClaudeClient {
        ClaudeClient(
            configuration: .init(baseURL: URL(string: "http://127.0.0.1:\(port)\(path)")!, requestTimeout: 10),
            transport: URLSessionTransport(configuration: .init(idleTimeout: 10, maxDuration: 30)),
            apiKeyProvider: { key },
            sleep: { _ in }
        )
    }

    private func request(_ text: String) -> MessageRequest {
        .make(model: ModelCatalog.opus55, system: "s", messages: [.user(text)], effort: .low, maxTokens: 100, fastMode: true, showThinking: true)
    }

    private func run(_ client: ClaudeClient, _ request: MessageRequest) async -> ([StreamUpdate], (any Error)?) {
        var updates: [StreamUpdate] = []
        do {
            for try await update in client.stream(request) { updates.append(update) }
            return (updates, nil)
        } catch {
            return (updates, error)
        }
    }

    @Test func streamsOverRealHTTP() async throws {
        let (updates, error) = await run(client(), request("Grüß dich 👋"))
        #expect(error == nil)
        guard case .completed(let message)? = updates.last else {
            Issue.record("no completion: \(String(describing: error))")
            return
        }
        #expect(message.text == "Echo: Grüß dich 👋 – ✓")
        #expect(message.content.first == .thinking(thinking: "Denke nach…", signature: "sig-local"))
        #expect(message.requestID == "req_local")
        #expect(message.usage.outputTokens == 9)
    }

    @Test func retriesOverloadOverRealHTTP() async throws {
        let (updates, error) = await run(client(path: "/overloaded-once"), request("x"))
        #expect(error == nil)
        #expect(updates.contains { if case .retrying = $0 { return true } else { return false } })
    }

    @Test func reportsAuthenticationFailure() async throws {
        let (_, error) = await run(client(key: "wrong"), request("x"))
        guard case .http(let info)? = error as? ClaudeError else {
            Issue.record("expected http error, got \(String(describing: error))")
            return
        }
        #expect(info.status == 401)
        #expect(info.message == "invalid x-api-key")
    }

    @Test func neverFollowsRedirects() async throws {
        let (updates, error) = await run(client(path: "/redirect"), request("x"))
        #expect(!updates.contains { if case .completed = $0 { return true } else { return false } })
        guard case .http(let info)? = error as? ClaudeError else {
            Issue.record("expected http error, got \(String(describing: error))")
            return
        }
        #expect(info.status == 302)
    }

    @Test func droppedConnectionRestartsOnceThenFails() async throws {
        let (updates, error) = await run(client(path: "/drop"), request("x"))
        #expect(error != nil)
        #expect(updates.contains { if case .retrying(_, _, _, true) = $0 { return true } else { return false } })
    }

    @Test func validatesKeyOverRealHTTP() async throws {
        #expect(try await client().validate(apiKey: "sk-ant-local") == .valid)
        #expect(try await client().validate(apiKey: "nope") == .invalid(message: "invalid x-api-key"))
    }
}
