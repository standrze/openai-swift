#if os(Linux)
    import Foundation
    import FoundationNetworking
    import NIOCore
    import NIOHTTP1
    import NIOPosix
    import NIOSSL
    import NIOWebSocket
    import WebSocketKit

    /// NIO owns TLS, HTTP upgrade validation, masking, fragmentation, and control frames.
    final class LinuxWebSocketConnection: OpenAIWebSocketConnection, @unchecked Sendable {
        private static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        private let lock = NSLock()
        private let options: WebSocketOptions
        private let messages: AsyncThrowingStream<WebSocketMessage, any Error>
        private let output: AsyncThrowingStream<WebSocketMessage, any Error>.Continuation
        private var channel: (any Channel)?
        private var socket: WebSocket?
        private var opening: CheckedContinuation<any OpenAIWebSocketConnection, any Error>?
        private var timer: Task<Void, Never>?
        private var terminal: (any Error)?
        private var response: HTTPResponse?
        private var receiving = false

        var handshakeResponse: HTTPResponse? { lock.withLock { response } }

        private init(options: WebSocketOptions) {
            self.options = options
            let pair = AsyncThrowingStream<WebSocketMessage, any Error>.makeStream()
            messages = pair.stream
            output = pair.continuation
        }

        deinit { channel?.close(promise: nil) }

        static func open(_ request: URLRequest, options: WebSocketOptions) async throws -> any OpenAIWebSocketConnection
        {
            try options.validate()
            guard let url = request.url, let host = url.host,
                let scheme = url.scheme, ["ws", "wss"].contains(scheme),
                url.user == nil, url.password == nil, url.fragment == nil
            else {
                throw OpenAIClientError.invalidConfiguration("A WebSocket transport requires a ws or wss URL")
            }
            let state = LinuxWebSocketConnection(options: options)
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await state.start(request, host: host, scheme: scheme)
            } onCancel: {
                state.fail(CancellationError())
            }
        }

        private func start(_ request: URLRequest, host: String, scheme: String) async throws
            -> any OpenAIWebSocketConnection
        {
            let url = request.url!
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
            let uri = path + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
            var headers = HTTPHeaders()
            for (name, value) in request.allHTTPHeaderFields ?? [:] {
                try HeaderMutation.validate(name: name, value: value)
                headers.add(name: name, value: value)
            }
            let authority = host + (url.port.map { ":\($0)" } ?? "")
            headers.replaceOrAdd(name: "Host", value: authority)
            let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: uri, headers: headers)
            let tls = scheme == "wss" ? try NIOSSLContext(configuration: .makeClientConfiguration()) : nil
            return try await withCheckedThrowingContinuation { continuation in
                let stopped = lock.withLock {
                    if terminal != nil { return true }
                    opening = continuation
                    return false
                }
                if stopped {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(self?.options.handshakeTimeout ?? 30)) } catch { return }
                    self?.fail(OpenAIWebSocketError.handshakeTimeout)
                }
                lock.withLock { timer = timeout }
                let bootstrap = ClientBootstrap(group: Self.group)
                    .connectTimeout(.seconds(30))
                    .channelInitializer { channel in
                        self.attach(channel)
                        return channel.eventLoop.submit {
                            if let tls {
                                let sni =
                                    host.contains(":") || host.split(separator: ".").allSatisfy({ Int($0) != nil })
                                    ? nil : host
                                try channel.pipeline.syncOperations.addHandler(
                                    NIOSSLClientHandler(context: tls, serverHostname: sni))
                            }
                            let upgrader = NIOWebSocketClientUpgrader(
                                maxFrameSize: self.options.maxMessageBytes == 0
                                    ? Int(UInt32.max) : min(self.options.maxMessageBytes, Int(UInt32.max)),
                                automaticErrorHandling: true,
                                upgradePipelineHandler: { channel, response in
                                    var configuration = WebSocket.Configuration()
                                    configuration.maxAccumulatedFrameSize =
                                        self.options.maxMessageBytes == 0 ? Int.max : self.options.maxMessageBytes
                                    return WebSocket.client(on: channel, config: configuration) { socket in
                                        self.didOpen(socket, response: response)
                                    }
                                })
                            let opening = NIOLoopBound(
                                LinuxOpeningHandler(head: head, owner: self), eventLoop: channel.eventLoop)
                            let upgrade: NIOHTTPClientUpgradeConfiguration = (
                                upgraders: [upgrader],
                                completionHandler: { context in
                                    context.pipeline.syncOperations.removeHandler(opening.value, promise: nil)
                                }
                            )
                            try channel.pipeline.syncOperations.addHTTPClientHandlers(
                                leftOverBytesStrategy: .forwardBytes, withClientUpgrade: upgrade)
                            try channel.pipeline.syncOperations.addHandler(opening.value)
                        }
                    }
                bootstrap.connect(host: host, port: url.port ?? (scheme == "wss" ? 443 : 80))
                    .whenFailure {
                        self.fail(
                            OpenAIWebSocketError.handshakeFailed(
                                statusCode: nil, headers: [:], message: $0.localizedDescription))
                    }
            }
        }

        private func attach(_ channel: any Channel) {
            let stopped = lock.withLock {
                self.channel = channel
                return terminal != nil
            }
            if stopped { channel.close(promise: nil) }
            channel.closeFuture.whenComplete { [weak self] _ in
                guard let self else { return }
                let code = self.lock.withLock {
                    self.socket?.closeCode.map { Int(UInt16(webSocketErrorCode: $0)) } ?? 1006
                }
                self.fail(OpenAIWebSocketError.closed(code: code, reason: nil))
            }
        }

        private func didOpen(_ socket: WebSocket, response: HTTPResponseHead) {
            let text: @Sendable (WebSocket, String) -> Void = { [weak self] _, text in self?.output.yield(.text(text)) }
            let binary: @Sendable (WebSocket, ByteBuffer) -> Void = { [weak self] _, buffer in
                self?.output.yield(.data(Data(buffer.readableBytesView)))
            }
            socket.onText(text)
            socket.onBinary(binary)
            let pending = lock.withLock {
                self.socket = socket
                self.response = HTTPResponse(
                    data: Data(), statusCode: Int(response.status.code),
                    headers: Dictionary(
                        response.headers.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last }))
                let pending = opening
                opening = nil
                timer?.cancel()
                timer = nil
                return terminal == nil ? pending : nil
            }
            pending?.resume(returning: self)
        }

        func fail(_ error: any Error) {
            let state = lock.withLock {
                () -> (CheckedContinuation<any OpenAIWebSocketConnection, any Error>?, (any Channel)?)? in
                guard terminal == nil else { return nil }
                terminal = error
                let state = (opening, channel)
                opening = nil
                timer?.cancel()
                timer = nil
                return state
            }
            guard let (pending, channel) = state else { return }
            pending?.resume(throwing: error)
            output.finish(throwing: error)
            channel?.close(promise: nil)
        }

        func send(_ message: WebSocketMessage) async throws {
            let socket = try lock.withLock {
                if let terminal { throw terminal }
                guard let socket else { throw OpenAIClientError.invalidResponse }
                return socket
            }
            guard options.maxMessageBytes == 0 || message.bytes.count <= options.maxMessageBytes else {
                throw OpenAIWebSocketError.messageTooLarge(limit: options.maxMessageBytes)
            }
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                switch message {
                case .text(let text): try await socket.send(text)
                case .data(let data): try await socket.send(Array(data))
                }
            } onCancel: {
                self.fail(CancellationError())
            }
        }

        func receive() async throws -> WebSocketMessage {
            try lock.withLock {
                guard !receiving else { throw OpenAIWebSocketError.concurrentReceive }
                receiving = true
            }
            defer { lock.withLock { receiving = false } }
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                var iterator = messages.makeAsyncIterator()
                guard let value = try await iterator.next() else {
                    try Task.checkCancellation()
                    throw OpenAIWebSocketError.closed(code: 1006, reason: nil)
                }
                try Task.checkCancellation()
                return value
            } onCancel: {
                self.fail(CancellationError())
            }
        }

        func abort() async { fail(CancellationError()) }

        func close(code: WebSocketCloseCode, reason: Data?) async {
            guard
                let (socket, channel) = lock.withLock({
                    self.socket.flatMap { socket in self.channel.map { (socket, $0) } }
                })
            else {
                fail(OpenAIWebSocketError.closed(code: code.rawValue, reason: nil))
                return
            }
            let validReason = reason.flatMap { $0.count <= 123 && String(data: $0, encoding: .utf8) != nil ? $0 : nil }
            var payload = Data([UInt8(code.rawValue >> 8), UInt8(code.rawValue & 255)])
            if let validReason { payload.append(validReason) }
            let timeout = Task {
                do { try await Task.sleep(for: .seconds(options.closeTimeout == 0 ? 5 : options.closeTimeout)) } catch {
                    return
                }
                channel.close(promise: nil)
            }
            defer { timeout.cancel() }
            do {
                let message = payload
                try await withTaskCancellationHandler {
                    try await socket.send(raw: message, opcode: .connectionClose)
                    try await channel.closeFuture.get()
                } onCancel: {
                    channel.close(promise: nil)
                }
            } catch { fail(error) }
            fail(OpenAIWebSocketError.closed(code: code.rawValue, reason: validReason))
        }
    }
#endif
