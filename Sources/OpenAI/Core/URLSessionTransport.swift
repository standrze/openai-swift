import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Redirect handling for HTTP operations. Credentials never follow a cross-origin redirect.
public enum HTTPRedirectPolicy: Sendable {
    case sameOrigin
    case rejectAll
}

/// A dependency-free transport that yields URLSession delegate chunks as they arrive.
/// Each operation owns its session; completion or cancellation invalidates that session.
public struct URLSessionTransport: OpenAITransport {
    public let maxResponseBytes: Int?
    public let maxBufferedChunks: Int
    public let redirectPolicy: HTTPRedirectPolicy
    public let clientIdentity: TLSClientIdentity?
    public let disableProxy: Bool
    public let resourceTimeout: TimeInterval?

    /// Bounds unread network chunks for streams. Full downloads collect all bytes in memory.
    public init(
        maxBufferedChunks: Int = 64, redirectPolicy: HTTPRedirectPolicy = .sameOrigin, disableProxy: Bool = false,
        resourceTimeout: TimeInterval? = nil, clientIdentity: TLSClientIdentity? = nil, maxResponseBytes: Int? = nil
    ) {
        self.maxResponseBytes = maxResponseBytes
        self.maxBufferedChunks = max(1, maxBufferedChunks)
        self.redirectPolicy = redirectPolicy
        self.disableProxy = disableProxy
        self.resourceTimeout = resourceTimeout
        self.clientIdentity = clientIdentity
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        guard maxResponseBytes.map({ $0 >= 0 }) ?? true else {
            throw OpenAIClientError.invalidConfiguration("Maximum response size must be nonnegative")
        }
        let exchange = SessionExchange(
            maxBufferedChunks: nil, redirectPolicy: redirectPolicy, disableProxy: disableProxy,
            resourceTimeout: resourceTimeout, clientIdentity: clientIdentity)
        let response = try await withTaskCancellationHandler {
            try await exchange.start(request)
        } onCancel: {
            exchange.cancel()
        }
        return try await withTaskCancellationHandler {
            var data = Data()
            for try await chunk in response.body {
                try Task.checkCancellation()
                if let maxResponseBytes, chunk.count > maxResponseBytes - data.count {
                    response.cancel()
                    throw OpenAIClientError.invalidResponse
                }
                data.append(chunk)
            }
            try Task.checkCancellation()
            return HTTPResponse(data: data, statusCode: response.statusCode, headers: response.headers)
        } onCancel: {
            response.cancel()
        }
    }

    public func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
        let exchange = SessionExchange(
            maxBufferedChunks: maxBufferedChunks, redirectPolicy: redirectPolicy, disableProxy: disableProxy,
            resourceTimeout: resourceTimeout, clientIdentity: clientIdentity)
        return try await withTaskCancellationHandler {
            try await exchange.start(request)
        } onCancel: {
            exchange.cancel()
        }
    }
}

// URLSession delegate callbacks and task cancellation may arrive on different queues.
// All shared state is protected by lock; callbacks and continuation resumes run outside it.
private final class SessionExchange: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var responseContinuation: CheckedContinuation<HTTPStreamResponse, any Error>?
    private var bodyContinuation: AsyncThrowingStream<Data, any Error>.Continuation?
    private var finished = false
    private var headerDeadline: Task<Void, Never>?
    private let maxBufferedChunks: Int?
    private let redirectPolicy: HTTPRedirectPolicy
    private let clientIdentity: TLSClientIdentity?
    private let disableProxy: Bool
    private let resourceTimeout: TimeInterval?

    init(
        maxBufferedChunks: Int?, redirectPolicy: HTTPRedirectPolicy, disableProxy: Bool, resourceTimeout: TimeInterval?,
        clientIdentity: TLSClientIdentity?
    ) {
        self.maxBufferedChunks = maxBufferedChunks
        self.redirectPolicy = redirectPolicy
        self.disableProxy = disableProxy
        self.resourceTimeout = resourceTimeout
        self.clientIdentity = clientIdentity
    }

    func start(_ request: URLRequest) async throws -> HTTPStreamResponse {
        guard request.timeoutInterval.isFinite,
            (0...RequestDeadline.unlimitedInterval).contains(request.timeoutInterval),
            request.timeoutInterval > 0,
            resourceTimeout.map({ $0.isFinite && $0 > 0 && $0 <= RequestDeadline.unlimitedInterval }) ?? true
        else {
            throw OpenAIClientError.invalidConfiguration("Invalid native transport timeout")
        }
        return try await withCheckedThrowingContinuation { continuation in
            let policy: AsyncThrowingStream<Data, any Error>.Continuation.BufferingPolicy =
                maxBufferedChunks.map { .bufferingOldest($0) } ?? .unbounded
            let body = AsyncThrowingStream<Data, any Error>(bufferingPolicy: policy) { body in
                lock.withLock { bodyContinuation = body }
                body.onTermination = { [weak self] _ in self?.cancel() }
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = request.timeoutInterval
            configuration.timeoutIntervalForResource = resourceTimeout ?? max(request.timeoutInterval, 604_800)
            #if canImport(Security)
                if clientIdentity != nil { configuration.tlsMinimumSupportedProtocolVersion = .TLSv12 }
            #endif
            if disableProxy { configuration.connectionProxyDictionary = [:] }
            let newSession = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            let newTask = newSession.dataTask(with: request)
            let cancelled = lock.withLock {
                if finished { return true }
                responseContinuation = continuation
                session = newSession
                task = newTask
                streamBody = body
                let timeout = min(request.timeoutInterval, resourceTimeout ?? request.timeoutInterval)
                headerDeadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    self?.finish(URLError(.timedOut))
                }
                return false
            }
            if cancelled {
                newSession.invalidateAndCancel()
                continuation.resume(throwing: CancellationError())
            } else {
                newTask.resume()
            }
        }
    }

    private var streamBody: AsyncThrowingStream<Data, any Error>?

    #if canImport(Security)
        func urlSession(
            _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard let clientIdentity else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            clientIdentity.handle(challenge, completion: completionHandler)
        }
        func urlSession(
            _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard let clientIdentity else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            clientIdentity.handle(challenge, completion: completionHandler)
        }
    #endif

    func cancel() { finish(CancellationError()) }

    private func finish(_ error: (any Error)?) {
        let state = lock.withLock {
            () -> (
                CheckedContinuation<HTTPStreamResponse, any Error>?,
                AsyncThrowingStream<Data, any Error>.Continuation?, URLSession?, AsyncThrowingStream<Data, any Error>?
            )? in
            guard !finished else { return nil }
            finished = true
            headerDeadline?.cancel()
            headerDeadline = nil
            let state = (responseContinuation, bodyContinuation, session, streamBody)
            responseContinuation = nil
            bodyContinuation = nil
            session = nil
            task = nil
            streamBody = nil
            return state
        }
        guard let (response, body, session, stream) = state else { return }
        response?.resume(throwing: error ?? OpenAIClientError.invalidResponse)
        body?.finish(throwing: error)
        session?.invalidateAndCancel()
        withExtendedLifetime(stream) {}
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(OpenAIClientError.invalidResponse)
            return
        }
        let state = lock.withLock {
            () -> (
                CheckedContinuation<HTTPStreamResponse, any Error>, AsyncThrowingStream<Data, any Error>
            )? in
            guard !finished, let continuation = responseContinuation, let body = streamBody else { return nil }
            responseContinuation = nil
            headerDeadline?.cancel()
            headerDeadline = nil
            return (continuation, body)
        }
        guard let (continuation, body) = state else {
            completionHandler(.cancel)
            return
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields { headers[String(describing: key)] = String(describing: value) }
        continuation.resume(
            returning: HTTPStreamResponse(
                statusCode: http.statusCode, headers: headers, body: body, cancel: { self.cancel() }
            ))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let continuation = lock.withLock { bodyContinuation }
        if case .dropped = continuation?.yield(data) {
            finish(OpenAIClientError.streamOverflow)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error = error as? URLError, error.code == .cancelled {
            finish(CancellationError())
        } else {
            finish(error)
        }
    }

    // Credentials must never follow a redirect to a different origin. Same-origin
    // redirects retain normal URLSession behavior (including its HTTP method rules).
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard case .sameOrigin = redirectPolicy else {
            completionHandler(nil)
            return
        }
        let original = task.originalRequest?.url
        let target = request.url
        func port(_ url: URL?) -> Int? { url?.port ?? (url?.scheme == "https" ? 443 : 80) }
        let sameOrigin =
            original?.scheme == target?.scheme && original?.host == target?.host
            && port(original) == port(target)
        completionHandler(sameOrigin ? request : nil)
    }
}
