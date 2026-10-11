import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum APIKeyCheck: Sendable, Hashable {
    case valid
    case invalid(message: String)
}

/// Streaming client for the Claude Messages API.
///
/// Speed: one warm HTTP/2 connection (optionally pre-warmed while the user types), streaming
/// from the first byte, deterministic request bodies for prompt-cache hits, optional fast mode.
/// Stability: transparent retries with backoff before any content arrives, one automatic
/// restart if a stream breaks mid-response, waiting for connectivity instead of failing,
/// automatic removal of optional features the API rejects, and recovery from rejected
/// thinking signatures.
public actor ClaudeClient {
    public struct Configuration: Sendable {
        public var baseURL: URL
        public var apiVersion: String
        public var retry: RetryPolicy
        /// Idle timeout applied to each request (see `URLSessionTransport.Configuration`).
        public var requestTimeout: TimeInterval
        /// Minimum spacing between connection pre-warm requests.
        public var prewarmInterval: Duration

        public init(
            baseURL: URL = URL(string: "https://api.anthropic.com")!,
            apiVersion: String = "2023-06-01",
            retry: RetryPolicy = RetryPolicy(),
            requestTimeout: TimeInterval = 120,
            prewarmInterval: Duration = .seconds(20)
        ) {
            self.baseURL = baseURL
            self.apiVersion = apiVersion
            self.retry = retry
            self.requestTimeout = requestTimeout
            self.prewarmInterval = prewarmInterval
        }
    }

    public typealias APIKeyProvider = @Sendable () async throws -> String?

    private let configuration: Configuration
    private let transport: any StreamingTransport
    private let connectivity: (any ConnectivityMonitoring)?
    private let apiKeyProvider: APIKeyProvider
    private let sleep: @Sendable (Duration) async throws -> Void
    private let random: @Sendable () -> Double

    private var disabledFeatures: Set<OptionalFeature> = []
    private var lastWarmConnection: ContinuousClock.Instant?

    public init(
        configuration: Configuration = Configuration(),
        transport: any StreamingTransport = URLSessionTransport(),
        connectivity: (any ConnectivityMonitoring)? = nil,
        apiKeyProvider: @escaping APIKeyProvider,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) {
        let scheme = configuration.baseURL.scheme?.lowercased()
        let host = configuration.baseURL.host?.lowercased() ?? ""
        precondition(
            scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)),
            "The API key must never travel over plain HTTP"
        )
        self.configuration = configuration
        self.transport = transport
        self.connectivity = connectivity
        self.apiKeyProvider = apiKeyProvider
        self.sleep = sleep
        self.random = random
    }

    // MARK: - Public API

    /// Streams one assistant turn. Cancel the consuming task to abort the request.
    public nonisolated func stream(_ request: MessageRequest) -> AsyncThrowingStream<StreamUpdate, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let final = try await self.perform(request) { continuation.yield($0) }
                    continuation.yield(.completed(final))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Task.isCancelled ? CancellationError() : error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Opens (or refreshes) the TLS + HTTP/2 connection ahead of the first message, e.g. when
    /// the app becomes active or the user starts typing. Throttled; failures are ignored.
    public func prewarm() async {
        let now = ContinuousClock.now
        if let last = lastWarmConnection, now - last < configuration.prewarmInterval { return }
        lastWarmConnection = now
        guard let key = try? await currentAPIKey() else { return }
        let request = makeURLRequest(
            path: "/v1/models", query: [URLQueryItem(name: "limit", value: "1")],
            method: "GET", apiKey: key, body: nil, betas: [], accept: "application/json", timeout: 15
        )
        _ = try? await fetch(request)
    }

    /// Checks a key against `GET /v1/models` without spending tokens.
    public func validate(apiKey: String) async throws -> APIKeyCheck {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .invalid(message: "Empty key") }
        let request = makeURLRequest(
            path: "/v1/models", query: [URLQueryItem(name: "limit", value: "1")],
            method: "GET", apiKey: key, body: nil, betas: [], accept: "application/json", timeout: 20
        )
        let (head, body) = try await fetch(request)
        switch head.statusCode {
        case 200..<300:
            lastWarmConnection = .now
            return .valid
        case 401:
            return .invalid(message: APIErrorInfo.from(head: head, body: body).message)
        default:
            throw ClaudeError.http(APIErrorInfo.from(head: head, body: body))
        }
    }

    public var disabledOptionalFeatures: Set<OptionalFeature> { disabledFeatures }

    /// Re-enables features dropped after earlier rejections (e.g. after settings changed).
    public func resetFeatureNegotiation() {
        disabledFeatures.removeAll()
    }

    // MARK: - Request loop

    private func disable(_ features: Set<OptionalFeature>) {
        disabledFeatures.formUnion(features)
    }

    private func markConnectionWarm() {
        lastWarmConnection = .now
    }

    private func currentAPIKey() async throws -> String {
        let key = try await apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { throw ClaudeError.missingAPIKey }
        return key
    }

    private nonisolated func perform(
        _ request: MessageRequest,
        emit: @Sendable (StreamUpdate) -> Void
    ) async throws -> FinalMessage {
        let apiKey = try await currentAPIKey()
        let policy = configuration.retry
        var messages = request.messages
        var disabled = await disabledFeatures
        var temporarilyDisabled: Set<OptionalFeature> = []
        var retries = 0
        var restarts = 0
        var negotiations = 0
        var strippedThinking = false
        let decoder = JSONDecoder()

        while true {
            try Task.checkCancellation()
            let active = request.features.subtracting(disabled).subtracting(temporarilyDisabled)
            let (body, betas) = try RequestEncoder.encode(request, messages: messages, features: active)
            let urlRequest = makeURLRequest(
                path: "/v1/messages", query: [], method: "POST", apiKey: apiKey, body: body,
                betas: betas, accept: "text/event-stream", timeout: configuration.requestTimeout
            )

            var accumulator = MessageAccumulator()
            var requestID: String?
            do {
                try await runAttempt(urlRequest, decoder: decoder, accumulator: &accumulator, requestID: &requestID, emit: emit)
                await markConnectionWarm()
                return accumulator.finalMessage(requestID: requestID)
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                let failure = Self.classify(error)
                let hadContent = accumulator.hasContent

                // 1. Replayed thinking blocks rejected: resend once without any thinking.
                if case .http(let info) = failure, info.isThinkingSignatureMismatch, !strippedThinking,
                   messages.contains(where: { $0.content.contains(where: \.isThinking) }) {
                    strippedThinking = true
                    messages = messages.map { Message(role: $0.role, content: $0.content.filter { !$0.isThinking }) }
                    emit(.thinkingStripped)
                    continue
                }

                // 2. An optional feature was rejected: drop it for the session and resend.
                if case .http(let info) = failure, info.status == 400, negotiations < OptionalFeature.allCases.count {
                    let drop = FeatureNegotiator.featuresToDisable(forMessage: info.message, active: active)
                    if !drop.isEmpty {
                        negotiations += 1
                        disabled.formUnion(drop)
                        await disable(drop)
                        emit(.featuresDisabled(drop, temporary: false))
                        continue
                    }
                }

                // 3. Fast mode has its own rate limit: fall back to standard speed right away.
                if case .http(let info) = failure, info.status == 429, active.contains(.fastMode), !hadContent {
                    temporarilyDisabled.insert(.fastMode)
                    emit(.featuresDisabled([.fastMode], temporary: true))
                    continue
                }

                // 4. Transient failures: back off and retry; restart a broken stream once.
                guard failure.isRetryable else { throw failure }
                if hadContent {
                    guard restarts < policy.maxInterruptedRestarts else { throw failure }
                    restarts += 1
                } else {
                    guard retries < policy.maxRetries else { throw failure }
                    retries += 1
                }
                let attempt = retries + restarts

                let delay: Duration
                // Wait for the network only if the OS says it is down; errors such as
                // "cannot find host" on a working path get normal exponential backoff.
                if failure.isConnectivityLoss, let connectivity, !connectivity.isConnected {
                    emit(.waitingForConnectivity)
                    guard await connectivity.waitUntilConnected(timeout: policy.connectivityTimeout) else { throw failure }
                    delay = .milliseconds(100)
                } else {
                    guard let backoff = policy.delay(forAttempt: attempt, error: failure, random: random()) else { throw failure }
                    delay = backoff
                }
                emit(.retrying(attempt: attempt, delay: delay, reason: failure, discardPartial: hadContent))
                try await sleep(delay)
            }
        }
    }

    private nonisolated func runAttempt(
        _ urlRequest: URLRequest,
        decoder: JSONDecoder,
        accumulator: inout MessageAccumulator,
        requestID: inout String?,
        emit: @Sendable (StreamUpdate) -> Void
    ) async throws {
        var parser = SSEParser()
        var head: HTTPResponseHead?
        var errorBody: Data?

        for try await event in transport.events(for: urlRequest) {
            switch event {
            case .response(let responseHead):
                head = responseHead
                requestID = responseHead.headers["request-id"]
                if responseHead.statusCode != 200 {
                    errorBody = Data()
                } else if let type = responseHead.headers["content-type"], !type.lowercased().contains("text/event-stream") {
                    throw ClaudeError.malformedResponse("Unexpected content type \(type)")
                }

            case .data(let chunk):
                guard head != nil else { throw ClaudeError.malformedResponse("Body without response head") }
                if var body = errorBody {
                    let room = Self.maxErrorBodyBytes - body.count
                    if room > 0 { body.append(chunk.prefix(room)) }
                    errorBody = body
                    continue
                }
                for sse in try parser.feed(chunk) where !sse.data.isEmpty {
                    let streamEvent = try decoder.decode(StreamEvent.self, from: sse.data)
                    if case .error(let body) = streamEvent {
                        throw ClaudeError.stream(APIErrorInfo(
                            status: nil, type: body.type,
                            message: body.message ?? "Unknown stream error", requestID: requestID
                        ))
                    }
                    for update in accumulator.apply(streamEvent) { emit(update) }
                    // Return on message_stop instead of waiting for the connection to close.
                    if accumulator.isComplete { return }
                }
            }
        }

        guard let head else { throw ClaudeError.malformedResponse("No response") }
        if let errorBody { throw ClaudeError.http(APIErrorInfo.from(head: head, body: errorBody)) }
        throw ClaudeError.truncatedStream
    }

    /// Executes a small non-streaming request and returns its head and (capped) body.
    private nonisolated func fetch(_ request: URLRequest) async throws -> (HTTPResponseHead, Data) {
        var head: HTTPResponseHead?
        var body = Data()
        do {
            for try await event in transport.events(for: request) {
                switch event {
                case .response(let responseHead):
                    head = responseHead
                case .data(let chunk):
                    let room = Self.maxErrorBodyBytes - body.count
                    if room > 0 { body.append(chunk.prefix(room)) }
                }
            }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw Self.classify(error)
        }
        guard let head else { throw ClaudeError.malformedResponse("No response") }
        return (head, body)
    }

    // MARK: - Helpers

    private static let maxErrorBodyBytes = 64 * 1024

    private static func classify(_ error: any Error) -> ClaudeError {
        switch error {
        case let claude as ClaudeError: return claude
        case is DecodingError: return .malformedResponse("Undecodable event: \(error)")
        case let parser as SSEParserError: return .malformedResponse("\(parser)")
        default: return ClaudeError.from(transportError: error)
        }
    }

    private nonisolated func makeURLRequest(
        path: String,
        query: [URLQueryItem],
        method: String,
        apiKey: String,
        body: Data?,
        betas: [String],
        accept: String,
        timeout: TimeInterval
    ) -> URLRequest {
        var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false)!
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + path
        components.queryItems = query.isEmpty ? nil : query

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(configuration.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(accept, forHTTPHeaderField: "accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        if !betas.isEmpty {
            request.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        }
        return request
    }
}

extension APIErrorInfo {
    private struct Envelope: Decodable {
        var error: APIErrorBody?
        var requestID: String?

        enum CodingKeys: String, CodingKey {
            case error
            case requestID = "request_id"
        }
    }

    /// Builds error details from a non-2xx response; tolerant of non-JSON bodies.
    static func from(head: HTTPResponseHead, body: Data) -> APIErrorInfo {
        let envelope = try? JSONDecoder().decode(Envelope.self, from: body)
        var message = envelope?.error?.message
        if message == nil || message?.isEmpty == true {
            let text = String(decoding: body.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            message = text.isEmpty ? "HTTP \(head.statusCode)" : text
        }
        return APIErrorInfo(
            status: head.statusCode,
            type: envelope?.error?.type,
            message: String((message ?? "").prefix(1000)),
            requestID: head.headers["request-id"] ?? envelope?.requestID,
            retryAfter: HeaderParsing.retryAfter(headers: head.headers),
            shouldRetry: HeaderParsing.shouldRetry(headers: head.headers)
        )
    }
}
