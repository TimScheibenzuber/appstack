import Foundation

/// Details of an API-level failure (non-2xx response or SSE `error` event).
public struct APIErrorInfo: Sendable, Hashable {
    /// HTTP status, `nil` for errors delivered inside an otherwise successful stream.
    public var status: Int?
    /// API error type such as `overloaded_error`, `rate_limit_error`, `invalid_request_error`.
    public var type: String?
    public var message: String
    public var requestID: String?
    public var retryAfter: Duration?
    /// Value of the `x-should-retry` response header, when present.
    public var shouldRetry: Bool?

    public init(
        status: Int?,
        type: String?,
        message: String,
        requestID: String? = nil,
        retryAfter: Duration? = nil,
        shouldRetry: Bool? = nil
    ) {
        self.status = status
        self.type = type
        self.message = message
        self.requestID = requestID
        self.retryAfter = retryAfter
        self.shouldRetry = shouldRetry
    }

    /// The preserved-thinking check rejected a replayed thinking block (history edited or
    /// signature from another conversation). Retrying the same body can never succeed.
    public var isThinkingSignatureMismatch: Bool {
        guard status == 400 else { return false }
        let lower = message.lowercased()
        return lower.contains("signature") && lower.contains("thinking")
    }
}

public enum ClaudeError: Error, Sendable, Hashable {
    case missingAPIKey
    /// The server answered with a non-2xx status.
    case http(APIErrorInfo)
    /// The server reported an error inside the event stream.
    case stream(APIErrorInfo)
    /// Transport failure (`URLError` code and description).
    case network(code: Int, description: String)
    /// Connection ended before `message_stop`.
    case truncatedStream
    case malformedResponse(String)

    private static let retryableStatuses: Set<Int> = [408, 409, 429, 500, 502, 503, 504, 529]
    private static let retryableStreamTypes: Set<String> = ["overloaded_error", "api_error", "rate_limit_error", "timeout_error"]

    /// URLError codes that mean "no usable network path right now".
    static let connectivityCodes: Set<Int> = [
        -1009, // notConnectedToInternet
        -1005, // networkConnectionLost
        -1020, // dataNotAllowed
        -1018, // internationalRoamingOff
        -1006, // dnsLookupFailed
        -1003, // cannotFindHost
        -1004, // cannotConnectToHost
    ]
    /// Transient transport failures worth one more attempt.
    static let retryableNetworkCodes: Set<Int> = connectivityCodes.union([
        -1001, // timedOut
        -1200, // secureConnectionFailed (often a captive portal or flaky handshake)
        -1011, // badServerResponse
    ])

    public var isRetryable: Bool {
        switch self {
        case .http(let info):
            if let explicit = info.shouldRetry { return explicit }
            guard let status = info.status else { return false }
            return Self.retryableStatuses.contains(status) || status >= 500
        case .stream(let info):
            if let explicit = info.shouldRetry { return explicit }
            return info.type.map(Self.retryableStreamTypes.contains) ?? false
        case .network(let code, _):
            return Self.retryableNetworkCodes.contains(code)
        case .truncatedStream:
            return true
        case .missingAPIKey, .malformedResponse:
            return false
        }
    }

    public var isConnectivityLoss: Bool {
        if case .network(let code, _) = self { return Self.connectivityCodes.contains(code) }
        return false
    }

    public var requestID: String? {
        switch self {
        case .http(let info), .stream(let info): return info.requestID
        default: return nil
        }
    }

    /// Maps any error thrown by the transport into a `ClaudeError` (cancellation excluded).
    static func from(transportError error: any Error) -> ClaudeError {
        if let claude = error as? ClaudeError { return claude }
        if let urlError = error as? URLError {
            return .network(code: urlError.errorCode, description: urlError.localizedDescription)
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return .network(code: nsError.code, description: nsError.localizedDescription)
        }
        return .malformedResponse(String(describing: error))
    }
}

extension ClaudeError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .missingAPIKey: return "No API key configured"
        case .http(let info): return "HTTP \(info.status ?? 0) \(info.type ?? ""): \(info.message)"
        case .stream(let info): return "Stream error \(info.type ?? ""): \(info.message)"
        case .network(let code, let description): return "Network error \(code): \(description)"
        case .truncatedStream: return "Stream ended unexpectedly"
        case .malformedResponse(let detail): return "Malformed response: \(detail)"
        }
    }
}
