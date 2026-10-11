import Foundation

public struct RetryPolicy: Sendable, Hashable {
    /// Retries for failures that happen before any content was delivered.
    public var maxRetries: Int
    /// How often a stream that broke after delivering content is restarted from scratch.
    public var maxInterruptedRestarts: Int
    public var initialBackoff: Duration
    public var maxBackoff: Duration
    /// A server-requested wait longer than this is surfaced instead of waited out.
    public var maxRetryAfter: Duration
    /// How long to wait for the network to come back before giving up.
    public var connectivityTimeout: Duration

    public init(
        maxRetries: Int = 3,
        maxInterruptedRestarts: Int = 1,
        initialBackoff: Duration = .milliseconds(400),
        maxBackoff: Duration = .seconds(8),
        maxRetryAfter: Duration = .seconds(60),
        connectivityTimeout: Duration = .seconds(30)
    ) {
        self.maxRetries = maxRetries
        self.maxInterruptedRestarts = maxInterruptedRestarts
        self.initialBackoff = initialBackoff
        self.maxBackoff = maxBackoff
        self.maxRetryAfter = maxRetryAfter
        self.connectivityTimeout = connectivityTimeout
    }

    /// Delay before retry number `attempt` (1-based), or `nil` if the server asked for a wait
    /// longer than `maxRetryAfter`. Uses "equal jitter" (half fixed, half random) so retries
    /// from many clients spread out without collapsing to near-zero waits.
    public func delay(forAttempt attempt: Int, error: ClaudeError, random: Double) -> Duration? {
        if let retryAfter = error.retryAfterHint {
            return retryAfter <= maxRetryAfter ? max(retryAfter, .zero) : nil
        }
        let exponent = min(max(attempt - 1, 0), 16)
        let raw = initialBackoff * (1 << exponent)
        let capped = min(raw, maxBackoff)
        let jitter = min(max(random, 0), 1)
        return capped / 2 + (capped / 2) * jitter
    }
}

extension ClaudeError {
    var retryAfterHint: Duration? {
        switch self {
        case .http(let info), .stream(let info): return info.retryAfter
        default: return nil
        }
    }
}

enum HeaderParsing {
    /// Parses `retry-after-ms` (milliseconds) or `retry-after` (seconds or HTTP-date).
    static func retryAfter(headers: [String: String], now: Date = Date()) -> Duration? {
        if let raw = headers["retry-after-ms"], let ms = Double(raw.trimmingCharacters(in: .whitespaces)), ms.isFinite, ms >= 0 {
            return .milliseconds(Int64(ms.rounded()))
        }
        guard let raw = headers["retry-after"]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let seconds = Double(raw), seconds.isFinite, seconds >= 0 {
            return .milliseconds(Int64((seconds * 1000).rounded()))
        }
        // HTTP-date form is rare; a formatter per call avoids sharing a non-Sendable instance.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: raw) {
            let interval = max(date.timeIntervalSince(now), 0)
            return .milliseconds(Int64((interval * 1000).rounded()))
        }
        return nil
    }

    static func shouldRetry(headers: [String: String]) -> Bool? {
        switch headers["x-should-retry"]?.lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }
}
