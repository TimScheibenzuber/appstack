import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPResponseHead: Sendable, Hashable {
    public var statusCode: Int
    /// Header names lower-cased.
    public var headers: [String: String]

    public init(statusCode: Int, headers: [String: String]) {
        self.statusCode = statusCode
        var normalized: [String: String] = [:]
        for (name, value) in headers { normalized[name.lowercased()] = value }
        self.headers = normalized
    }
}

public enum TransportEvent: Sendable, Hashable {
    case response(HTTPResponseHead)
    case data(Data)
}

/// Streams the raw HTTP exchange for one request. Cancelling the consuming task (or dropping
/// the stream) must cancel the underlying network request.
public protocol StreamingTransport: Sendable {
    func events(for request: URLRequest) -> AsyncThrowingStream<TransportEvent, any Error>
}

/// Lets the client wait for a usable network path instead of burning retries while offline.
public protocol ConnectivityMonitoring: Sendable {
    /// Whether the system currently reports a usable network path.
    var isConnected: Bool { get }
    /// Returns `true` once a satisfied path exists, `false` on timeout.
    func waitUntilConnected(timeout: Duration) async -> Bool
}
