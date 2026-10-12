import Foundation

/// Coordinates issuer retries and complete request attempts for workload identity authentication.
/// Each logical operation receives a fresh scope, including concurrent operations on the same client.
public final class AuthenticationRetryScope: @unchecked Sendable {
    @TaskLocal public static var current: AuthenticationRetryScope?
    public let maximumDelay: TimeInterval
    private let lock = NSLock()
    private let maximum: Int
    private var consumed = 0
    private var started = false
    private var replayed = false
    private var admissions: Set<ObjectIdentifier> = []

    public init(maximum: Int, maximumDelay: TimeInterval) {
        self.maximum = max(0, maximum)
        self.maximumDelay = maximumDelay
    }

    public var canRetry: Bool { lock.withLock { consumed < maximum } }

    public func beginAttempt() -> Bool {
        lock.withLock {
            if started {
                guard consumed < maximum else { return false }
                consumed += 1
            }
            started = true
            return true
        }
    }

    public func retryIssuer() -> Bool {
        lock.withLock {
            guard consumed < maximum else { return false }
            consumed += 1
            return true
        }
    }

    public func reserveUnauthorizedReplay() -> Bool {
        lock.withLock {
            guard !replayed, consumed < maximum else { return false }
            replayed = true
            return true
        }
    }

    /// Keeps an admitted operation valid when its native identity capability is subsequently closed.
    public func admit(_ capability: AnyObject, check: () throws -> Void) throws {
        try lock.withLock {
            let id = ObjectIdentifier(capability)
            if admissions.contains(id) { return }
            try check()
            admissions.insert(id)
        }
    }

    public static func withScope<Value: Sendable>(
        configuration: ClientConfiguration, options: RequestOptions,
        operation: () async throws -> Value
    ) async rethrows -> Value {
        let scope =
            configuration.sharesAuthenticationRetryBudget
            ? AuthenticationRetryScope(
                maximum: options.maxRetries ?? configuration.maxRetries,
                maximumDelay: options.maxRetryDelay ?? configuration.maxRetryDelay)
            : nil
        return try await $current.withValue(scope, operation: operation)
    }
}
