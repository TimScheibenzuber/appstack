import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal lock-protected box (NSLock works on every platform the package targets).
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

/// `URLSession`-based streaming transport.
///
/// Uses one long-lived session so the TLS + HTTP/2 connection to the API is reused across
/// requests (no handshake on follow-up messages). Bytes are delivered from the delegate in
/// network-sized chunks - no per-byte async iteration - straight into the SSE parser.
public final class URLSessionTransport: StreamingTransport, @unchecked Sendable {
    public struct Configuration: Sendable {
        /// Maximum silence between two packets before the request fails (the API sends
        /// periodic `ping` events while a response is being generated).
        public var idleTimeout: TimeInterval
        /// Hard upper bound for a single exchange.
        public var maxDuration: TimeInterval

        public init(idleTimeout: TimeInterval = 120, maxDuration: TimeInterval = 3600) {
            self.idleTimeout = idleTimeout
            self.maxDuration = maxDuration
        }
    }

    private let session: URLSession
    private let router: TaskRouter

    public init(configuration: Configuration = Configuration()) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = configuration.idleTimeout
        config.timeoutIntervalForResource = configuration.maxDuration
        // Nothing about API traffic is cached or stored on disk.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        config.httpMaximumConnectionsPerHost = 4
        #if canImport(Darwin)
        // Fail fast while offline; the client waits for connectivity itself so a long
        // resource timeout never turns into a silent multi-minute hang.
        config.waitsForConnectivity = false
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        // Tells the OS this is latency-sensitive interactive traffic.
        config.networkServiceType = .responsiveData
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        #endif

        let queue = OperationQueue()
        queue.name = "ClaudeKit.URLSessionTransport"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated

        let router = TaskRouter()
        self.router = router
        self.session = URLSession(configuration: config, delegate: router, delegateQueue: queue)
    }

    deinit {
        // The session retains its delegate; invalidating breaks that cycle.
        session.invalidateAndCancel()
    }

    public func events(for request: URLRequest) -> AsyncThrowingStream<TransportEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = session.dataTask(with: request)
            let identifier = task.taskIdentifier
            router.register(identifier, continuation: continuation)
            let cancel = TaskCanceller(task: task)
            continuation.onTermination = { [router] termination in
                if case .cancelled = termination { cancel.cancel() }
                router.remove(identifier)
            }
            task.resume()
        }
    }
}

/// Holds a task reference for the `@Sendable` termination handler.
private final class TaskCanceller: @unchecked Sendable {
    private let task: URLSessionTask
    init(task: URLSessionTask) { self.task = task }
    func cancel() { task.cancel() }
}

/// Session-level delegate that routes callbacks to the continuation of each task.
/// All callbacks arrive on the session's serial delegate queue.
private final class TaskRouter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Entry {
        var continuation: AsyncThrowingStream<TransportEvent, any Error>.Continuation
        var reportedHead = false
    }

    private let entries = Locked<[Int: Entry]>([:])

    func register(_ identifier: Int, continuation: AsyncThrowingStream<TransportEvent, any Error>.Continuation) {
        entries.withLock { $0[identifier] = Entry(continuation: continuation) }
    }

    func remove(_ identifier: Int) {
        _ = entries.withLock { $0.removeValue(forKey: identifier) }
    }

    /// Emits the response head once, before the first body byte (or at completion for
    /// bodiless responses). Reading `task.response` avoids the completion-handler based
    /// `didReceive response` callback entirely.
    private func continuationReportingHead(for task: URLSessionTask) -> AsyncThrowingStream<TransportEvent, any Error>.Continuation? {
        let (continuation, needsHead) = entries.withLock { entries -> (AsyncThrowingStream<TransportEvent, any Error>.Continuation?, Bool) in
            guard var entry = entries[task.taskIdentifier] else { return (nil, false) }
            let needsHead = !entry.reportedHead
            entry.reportedHead = true
            entries[task.taskIdentifier] = entry
            return (entry.continuation, needsHead)
        }
        if needsHead, let continuation, let http = task.response as? HTTPURLResponse {
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let name = key as? String, let value = value as? String { headers[name] = value }
            }
            continuation.yield(.response(HTTPResponseHead(statusCode: http.statusCode, headers: headers)))
        }
        return continuation
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuationReportingHead(for: dataTask)?.yield(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        // Bodiless responses (e.g. some errors) still need their status reported.
        if error == nil { _ = continuationReportingHead(for: task) }
        guard let entry = entries.withLock({ $0.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let error {
            entry.continuation.finish(throwing: error)
        } else {
            entry.continuation.finish()
        }
    }

    #if canImport(Darwin)
    /// Never follow redirects: the API does not redirect, and following one could forward
    /// the `x-api-key` header to another host. The 3xx response surfaces as an error.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
    #else
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
    #endif
}
