import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Uses URLSession's native WebSocket framing, TLS validation, and control-frame handling.
public struct URLSessionWebSocketTransport: OpenAIWebSocketTransport {
    public let clientIdentity: TLSClientIdentity?
    public let rejectRedirects: Bool
    public init(clientIdentity: TLSClientIdentity? = nil, rejectRedirects: Bool = false) {
        self.clientIdentity = clientIdentity
        self.rejectRedirects = rejectRedirects
    }

    public func connect(
        _ request: URLRequest,
        options: WebSocketOptions = .init()
    ) async throws -> any OpenAIWebSocketConnection {
        #if os(Linux)
            guard clientIdentity == nil else {
                throw OpenAIClientError.invalidConfiguration(
                    "Native client identities require Apple's Security framework")
            }
            return try await LinuxWebSocketConnection.open(request, options: options)
        #else
            try options.validate()
            guard let url = request.url, ["ws", "wss"].contains(url.scheme?.lowercased() ?? ""),
                let host = url.host, !host.isEmpty
            else { throw OpenAIClientError.invalidConfiguration("A WebSocket transport requires a ws or wss URL") }
            let connection = URLSessionWebSocketConnection(
                options: options, clientIdentity: clientIdentity, rejectRedirects: rejectRedirects)
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await connection.start(request)
            } onCancel: {
                connection.terminate(CancellationError())
            }
        #endif
    }
}

// Delegate callbacks, cancellation handlers, and callers share this state. All state
// changes occur under lock; native operations and continuation resumes happen outside it.
private final class URLSessionWebSocketConnection: OpenAIWebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private let options: WebSocketOptions
    fileprivate let clientIdentity: TLSClientIdentity?
    fileprivate let rejectRedirects: Bool
    private let closeSignal = WebSocketCloseSignal()
    private var closingSession: URLSession?
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var handshake: CheckedContinuation<any OpenAIWebSocketConnection, any Error>?
    private var deadline: Task<Void, Never>?
    private var terminalError: (any Error)?
    private var opened = false
    private var receiving = false

    init(options: WebSocketOptions, clientIdentity: TLSClientIdentity?, rejectRedirects: Bool) {
        self.options = options
        self.clientIdentity = clientIdentity
        self.rejectRedirects = rejectRedirects
    }
    var handshakeResponse: HTTPResponse? {
        lock.withLock {
            guard let response = task?.response as? HTTPURLResponse else { return nil }
            let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, item in
                result[String(describing: item.key)] = String(describing: item.value)
            }
            return HTTPResponse(data: Data(), statusCode: response.statusCode, headers: headers)
        }
    }

    deinit {
        deadline?.cancel()
        task?.cancel()
        session?.invalidateAndCancel()
        closingSession?.invalidateAndCancel()
    }

    func start(_ request: URLRequest) async throws -> any OpenAIWebSocketConnection {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = WebSocketSessionDelegate(owner: self)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = request.timeoutInterval
            #if canImport(Security)
                if clientIdentity != nil { configuration.tlsMinimumSupportedProtocolVersion = .TLSv12 }
            #endif
            if clientIdentity != nil { configuration.connectionProxyDictionary = [:] }
            let newSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            let newTask = newSession.webSocketTask(with: request)
            newTask.maximumMessageSize = options.maxMessageBytes == 0 ? .max : options.maxMessageBytes
            let priorError = lock.withLock { () -> (any Error)? in
                if let terminalError { return terminalError }
                session = newSession
                task = newTask
                handshake = continuation
                return nil
            }
            if let priorError {
                newSession.invalidateAndCancel()
                continuation.resume(throwing: priorError)
                return
            }
            let timeout = options.handshakeTimeout
            let timer = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) } catch { return }
                self?.terminate(OpenAIWebSocketError.handshakeTimeout)
            }
            let needsDeadline = lock.withLock {
                guard terminalError == nil, !opened else { return false }
                deadline = timer
                return true
            }
            if !needsDeadline { timer.cancel() }
            newTask.resume()
        }
    }

    func send(_ message: WebSocketMessage) async throws {
        guard options.maxMessageBytes == 0 || message.bytes.count <= options.maxMessageBytes else {
            throw OpenAIWebSocketError.messageTooLarge(limit: options.maxMessageBytes)
        }
        let task = try activeTask()
        try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                switch message {
                case .text(let text): try await task.send(.string(text))
                case .data(let data): try await task.send(.data(data))
                }
                try Task.checkCancellation()
            } catch {
                terminate(error)
                throw currentError(or: error)
            }
        } onCancel: {
            self.terminate(CancellationError())
        }
    }

    func receive() async throws -> WebSocketMessage {
        let task = try lock.withLock {
            if let terminalError { throw terminalError }
            guard !receiving else { throw OpenAIWebSocketError.concurrentReceive }
            guard opened, let task else {
                throw OpenAIClientError.invalidStream("WebSocket handshake has not completed")
            }
            receiving = true
            return task
        }
        defer { lock.withLock { receiving = false } }
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let native = try await task.receive()
                let message: WebSocketMessage
                switch native {
                case .string(let text): message = .text(text)
                case .data(let data): message = .data(data)
                @unknown default: throw OpenAIClientError.invalidStream("Unsupported WebSocket message kind")
                }
                guard options.maxMessageBytes == 0 || message.bytes.count <= options.maxMessageBytes else {
                    throw OpenAIWebSocketError.messageTooLarge(limit: options.maxMessageBytes)
                }
                try Task.checkCancellation()
                return message
            } catch {
                terminate(error)
                throw currentError(or: error)
            }
        } onCancel: {
            self.terminate(CancellationError())
        }
    }

    func abort() async { abortImmediately() }

    private func abortImmediately() {
        terminate(CancellationError())
        completeClose()
    }

    fileprivate func completeClose() {
        let closing = lock.withLock {
            let result = closingSession
            closingSession = nil
            return result
        }
        closing?.invalidateAndCancel()
        closeSignal.finish()
    }

    func close(code: WebSocketCloseCode, reason: Data?) async {
        let validReason = reason.flatMap { $0.count <= 123 && String(data: $0, encoding: .utf8) != nil ? $0 : nil }
        terminate(
            OpenAIWebSocketError.closed(code: code.rawValue, reason: validReason), closeCode: code, reason: validReason)
        await withTaskCancellationHandler {
            await closeSignal.wait()
        } onCancel: {
            self.abortImmediately()
        }
    }

    func didOpen() {
        let state = lock.withLock {
            () -> (
                CheckedContinuation<any OpenAIWebSocketConnection, any Error>?, Task<Void, Never>?
            )? in
            guard terminalError == nil else { return nil }
            opened = true
            let state = (handshake, deadline)
            handshake = nil
            deadline = nil
            return state
        }
        guard let (continuation, timer) = state else { return }
        timer?.cancel()
        continuation?.resume(returning: self)
    }

    func didComplete(_ task: URLSessionTask, error: (any Error)?) {
        completeClose()
        let wasOpened = lock.withLock { opened }
        if !wasOpened {
            let response = task.response as? HTTPURLResponse
            let headers =
                response.map {
                    Dictionary(
                        uniqueKeysWithValues: $0.allHeaderFields.map {
                            (String(describing: $0.key), String(describing: $0.value))
                        })
                } ?? [:]
            terminate(
                OpenAIWebSocketError.handshakeFailed(
                    statusCode: response?.statusCode,
                    headers: headers,
                    message: error?.localizedDescription ?? "Connection closed before the upgrade completed"
                ))
        } else {
            terminate(error ?? OpenAIWebSocketError.closed(code: 1006, reason: nil))
        }
    }

    func terminate(_ error: any Error, closeCode: WebSocketCloseCode? = nil, reason: Data? = nil) {
        let state = lock.withLock {
            () -> (
                URLSession?, URLSessionWebSocketTask?, CheckedContinuation<any OpenAIWebSocketConnection, any Error>?,
                Task<Void, Never>?
            )? in
            guard terminalError == nil else { return nil }
            terminalError = error
            let state = (session, task, handshake, deadline)
            if closeCode != nil { closingSession = session }
            session = nil
            task = nil
            handshake = nil
            deadline = nil
            return state
        }
        guard let (session, task, continuation, timer) = state else { return }
        timer?.cancel()
        continuation?.resume(throwing: error)
        if let closeCode {
            let nativeCode = URLSessionWebSocketTask.CloseCode(rawValue: closeCode.rawValue) ?? .normalClosure
            task?.cancel(with: nativeCode, reason: reason)
            session?.finishTasksAndInvalidate()
            // A peer that ignores close frames cannot retain the session indefinitely.
            if let session {
                let timeout = options.closeTimeout == 0 ? 5 : options.closeTimeout
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    session.invalidateAndCancel()
                    self?.completeClose()
                }
            }
        } else {
            task?.cancel()
            session?.invalidateAndCancel()
            closeSignal.finish()
        }
    }

    private func activeTask() throws -> URLSessionWebSocketTask {
        try lock.withLock {
            if let terminalError { throw terminalError }
            guard opened, let task else {
                throw OpenAIClientError.invalidStream("WebSocket handshake has not completed")
            }
            return task
        }
    }

    private func currentError(or fallback: any Error) -> any Error {
        lock.withLock { terminalError ?? fallback }
    }
}

private final class WebSocketSessionDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    // Initialized before task.resume(). Weak ownership lets dropping a connection dispose its session.
    private weak var owner: URLSessionWebSocketConnection?

    init(owner: URLSessionWebSocketConnection) { self.owner = owner }

    #if canImport(Security)
        func urlSession(
            _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard let identity = owner?.clientIdentity else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            identity.handle(challenge, completion: completionHandler)
        }
        func urlSession(
            _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard let identity = owner?.clientIdentity else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            identity.handle(challenge, completion: completionHandler)
        }
    #endif

    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?
    ) {
        owner?.didOpen()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        owner?.completeClose()
        owner?.terminate(OpenAIWebSocketError.closed(code: closeCode.rawValue, reason: reason))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        owner?.didComplete(task, error: error)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        func origin(_ url: URL?) -> String? {
            guard let url, let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
            let secure = scheme == "wss" || scheme == "https"
            return "\(secure ? "https" : "http")://\(host):\(url.port ?? (secure ? 443 : 80))"
        }
        if owner?.rejectRedirects == true {
            completionHandler(nil)
            return
        }
        completionHandler(origin(task.originalRequest?.url) == origin(request.url) ? request : nil)
    }
}

private final class WebSocketCloseSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let done = lock.withLock {
                if finished { return true }
                waiters.append(continuation)
                return false
            }
            if done { continuation.resume() }
        }
    }
    func finish() {
        let pending = lock.withLock {
            finished = true
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        for waiter in pending { waiter.resume() }
    }
}
