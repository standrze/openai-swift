import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Shared retry decisions for the facade and generated transport. Successful stream bodies are never replayed.
public enum HTTPRetryPolicy {
    public static func shouldRetry(status: Int, headers: [String: String]) -> Bool {
        if let decision = header("x-should-retry", in: headers)?.lowercased() {
            if decision == "true" { return true }
            if decision == "false" { return false }
        }
        return [408, 409, 429].contains(status) || status >= 500
    }

    public static func shouldRetry(error: any Error) -> Bool {
        guard !Task.isCancelled, let error = error as? URLError else { return false }
        return [
            .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
            .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable,
        ].contains(error.code)
    }

    /// Honors retry-after-ms, then Retry-After seconds/HTTP date, capped by the configured maximum.
    public static func delay(
        attempt: Int, headers: [String: String], initialDelay: TimeInterval, maxDelay: TimeInterval,
        now: Date = Date()
    ) throws -> TimeInterval {
        guard attempt >= 0, initialDelay.isFinite, initialDelay >= 0,
            maxDelay.isFinite, (0...86_400).contains(maxDelay), now.timeIntervalSince1970.isFinite
        else { throw OpenAIClientError.invalidConfiguration("Invalid retry delay") }
        var serverDelay = header("retry-after-ms", in: headers).flatMap(Double.init).map { $0 / 1000 }
        if serverDelay == nil, let value = header("retry-after", in: headers) {
            serverDelay = Double(value)
            if serverDelay == nil {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                serverDelay = formatter.date(from: value)?.timeIntervalSince(now)
            }
        }
        let backoff = min(maxDelay, initialDelay * pow(2, Double(attempt)))
        let candidate =
            serverDelay.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            ?? backoff * Double.random(in: 0.75...1)
        return min(maxDelay, candidate)
    }

    /// Server delays are honored exactly or stop retries; they are never shortened to the cap.
    public static func decision(
        attempt: Int, headers: [String: String], configuration: ClientConfiguration,
        maxDelay: TimeInterval? = nil, now: Date = Date()
    ) throws -> RetryDecision {
        let limit = maxDelay ?? configuration.maxServerRetryDelay
        guard limit.isFinite, (0...86_400).contains(limit) else {
            throw OpenAIClientError.invalidConfiguration("Invalid server retry delay")
        }
        for (name, units) in [("retry-after-ms", 0.001), ("retry-after", 1.0)] {
            guard let raw = header(name, in: headers) else { continue }
            var supplied = Double(raw).map { $0 * units }
            if supplied == nil, name == "retry-after" {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                supplied = formatter.date(from: raw)?.timeIntervalSince(now)
            }
            if let supplied, !supplied.isNaN, supplied >= 0 {
                return RetryDecision(delay: min(limit, supplied), shouldRetry: supplied <= limit)
            }
        }
        return RetryDecision(
            delay: try delay(
                attempt: attempt, headers: [:],
                initialDelay: configuration.initialRetryDelay, maxDelay: maxDelay ?? configuration.maxRetryDelay,
                now: now),
            shouldRetry: true)
    }

    public static func wait(attempt: Int, headers: [String: String], configuration: ClientConfiguration) async throws {
        let seconds = try delay(
            attempt: attempt, headers: headers,
            initialDelay: configuration.initialRetryDelay, maxDelay: configuration.maxRetryDelay)
        try Task.checkCancellation()
        if seconds > 0 { try await Task.sleep(for: .seconds(seconds)) }
    }

    private static func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// Retry eligibility and the wait before the next attempt.
public struct RetryDecision: Sendable, Equatable {
    public let delay: TimeInterval
    public let shouldRetry: Bool
}
