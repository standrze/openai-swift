import Crypto
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Exchanges and caches bearer tokens, sharing one refresh among concurrent callers.
/// Connect to a client with `accessTokenProvider: { try await provider.accessToken() }`.
public actor OAuthTokenProvider {
    private let configuration: OAuthConfiguration
    private let transport: any OpenAITransport
    private let now: @Sendable () -> Date
    private var cached: CachedOAuthToken?
    private var issued: [String: Date] = [:]
    private var rejected: [String: Date] = [:]
    private var fallbackUntil: Date?
    private struct Waiter {
        let continuation: CheckedContinuation<String, any Error>
        let scope: AuthenticationRetryScope?
        let deadline: Date?
    }
    private var refresh: (id: UUID, leader: UUID, deadline: Date?, task: Task<Void, Never>)?
    private var waiters: [UUID: Waiter] = [:]

    /// Creates a provider. Credentials and token responses are never logged by this implementation.
    /// The injected clock supports deterministic expiry tests and must be safe for concurrent calls.
    public init(
        configuration: OAuthConfiguration,
        transport: any OpenAITransport = URLSessionTransport(redirectPolicy: .rejectAll, maxResponseBytes: 1024 * 1024),
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        try configuration.validate()
        self.configuration = configuration
        self.transport = transport
        self.now = now
    }

    /// Returns a cached token or waits for a shared exchange.
    /// Cancelling one caller stops its wait without cancelling the exchange or other callers.
    public func accessToken() async throws -> String {
        try Task.checkCancellation()
        let time = now()
        pruneHistory(at: time)
        guard time.timeIntervalSince1970.isFinite else { throw OAuthTokenError.invalidResponse("Invalid clock value") }
        if let cached, time >= cached.receivedAt, time < cached.refreshAfter {
            try Task.checkCancellation()
            return cached.value
        }
        if let cached, let fallbackUntil, time >= cached.receivedAt, time < fallbackUntil,
            time < cached.expiresAt, rejected[fingerprint(cached.value)] == nil
        {
            return cached.value
        }
        let waiterID = UUID()
        do {
            let value = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    waiters[waiterID] = Waiter(
                        continuation: continuation, scope: AuthenticationRetryScope.current,
                        deadline: RequestDeadline.current)
                    if refresh == nil { startRefresh(leader: waiterID) }
                }
            } onCancel: {
                Task { await self.cancelWaiter(waiterID) }
            }
            try Task.checkCancellation()
            return value
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }

    /// Drops the cache and cancels any active refresh. Existing waiters receive `OAuthTokenError.invalidated`.
    /// An invalidated exchange cannot repopulate the cache even if its transport ignores cancellation.
    public func invalidate() {
        cached = nil
        fallbackUntil = nil
        let task = refresh?.task
        refresh = nil
        task?.cancel()
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending { waiter.continuation.resume(throwing: OAuthTokenError.invalidated) }
    }

    /// Invalidates only the rejected generation, preserving a newer token refreshed by another request.
    public func invalidate(ifToken rejected: String) -> Bool {
        pruneHistory(at: now())
        let digest = fingerprint(rejected)
        if let expiry = issued[digest] { self.rejected[digest] = expiry }
        guard let cached else { return refresh != nil }
        guard cached.value == rejected else { return true }
        self.cached = nil
        fallbackUntil = nil
        return true
    }

    private func fingerprint(_ token: String) -> String {
        Data(SHA256.hash(data: Data(token.utf8))).base64EncodedString()
    }

    func hasIssued(_ token: String) -> Bool {
        pruneHistory(at: now())
        return issued[fingerprint(token)] != nil
    }

    var pendingWaiterCount: Int { waiters.count }

    private func accepts(_ token: String) -> Bool {
        pruneHistory(at: now())
        return rejected[fingerprint(token)] == nil
    }

    private func pruneHistory(at time: Date) {
        issued = issued.filter { $0.value > time }
        rejected = rejected.filter { $0.value > time }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }

    private func startRefresh(leader: UUID) {
        guard let owner = waiters[leader] else { return }
        let id = UUID()
        let configuration = configuration
        let transport = transport
        let now = now
        let task = Task {
            let result: Result<CachedOAuthToken, any Error>
            do {
                result = .success(
                    try await AuthenticationRetryScope.$current.withValue(owner.scope) {
                        try await RequestDeadline.$current.withValue(owner.deadline) {
                            try await OAuthExchange.fetch(
                                configuration: configuration, transport: transport, now: now,
                                acceptToken: { await self.accepts($0) })
                        }
                    })
            } catch {
                result = .failure(error)
            }
            finishRefresh(id: id, result: result)
        }
        refresh = (id, leader, owner.deadline, task)
    }

    private func finishRefresh(id: UUID, result: Result<CachedOAuthToken, any Error>) {
        guard refresh?.id == id else { return }
        let leader = refresh?.leader
        let ownerDeadline = refresh?.deadline
        refresh = nil
        let pending = waiters
        waiters.removeAll()
        switch result {
        case .success(let token):
            pruneHistory(at: now())
            guard rejected[fingerprint(token.value)] == nil,
                issued.count < 1024 || issued[fingerprint(token.value)] != nil
            else {
                for waiter in pending.values {
                    waiter.continuation.resume(
                        throwing: OAuthTokenError.invalidResponse("Rejected or excessive bearer generation"))
                }
                return
            }
            issued[fingerprint(token.value)] = token.expiresAt
            fallbackUntil = nil
            cached = token
            for waiter in pending.values { waiter.continuation.resume(returning: token.value) }
        case .failure(let error):
            let time = now()
            let transient: Bool
            if let issuer = error as? OAuthHTTPError {
                transient =
                    issuer.retryableOAuthError
                    || [408, 409, 429].contains(issuer.statusCode) || (500..<600).contains(issuer.statusCode)
            } else if let api = error as? APIError {
                transient = [408, 409, 429].contains(api.statusCode) || (500..<600).contains(api.statusCode)
            } else if let network = error as? URLError {
                transient = [
                    .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                    .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable,
                ].contains(network.code)
            } else {
                transient = false
            }
            if transient, ownerDeadline.map({ $0 > Date() }) ?? true,
                configuration.refreshFailureCooldown > 0, let cached,
                time >= cached.receivedAt, time < cached.expiresAt, rejected[fingerprint(cached.value)] == nil
            {
                fallbackUntil = min(
                    cached.expiresAt,
                    time.addingTimeInterval(
                        min(configuration.refreshFailureCooldown, cached.expiresAt.timeIntervalSince(time) / 2)))
                for waiter in pending.values { waiter.continuation.resume(returning: cached.value) }
                return
            }
            for (id, waiter) in pending {
                if id != leader, transient, waiter.scope?.retryIssuer() == true,
                    waiter.deadline.map({ $0 > Date() }) ?? true
                {
                    waiters[id] = waiter
                } else {
                    waiter.continuation.resume(throwing: error)
                }
            }
            if let next = waiters.keys.first { startRefresh(leader: next) }
        }
    }
}

struct CachedOAuthToken: Sendable {
    let value: String
    let receivedAt: Date
    let expiresAt: Date
    let refreshAfter: Date
}

/// Invalid token endpoint content or explicit cache invalidation. HTTP failures use `APIError`.
public enum OAuthTokenError: Error, Sendable, Equatable, LocalizedError {
    case invalidResponse(String)
    case emptySubjectToken
    case invalidated

    public var errorDescription: String? {
        switch self {
        case .invalidResponse(let detail): return "Invalid OAuth token response: \(detail)"
        case .emptySubjectToken: return "OAuth subject-token provider returned an empty token"
        case .invalidated: return "OAuth token refresh was invalidated"
        }
    }
}

extension ClientConfiguration {
    /// Uses cached OAuth tokens and recovers from a rejected generation within the normal HTTP retry budget.
    public mutating func authenticate(using provider: OAuthTokenProvider) {
        apiKey = nil
        adminAPIKey = nil
        accessTokenProvider = { try await provider.accessToken() }
        refreshUnauthorized = { token in await provider.invalidate(ifToken: token) }
    }
}
