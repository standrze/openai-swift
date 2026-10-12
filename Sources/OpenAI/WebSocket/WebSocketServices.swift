import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

extension OpenAIClient {
    /// Opens one authenticated WebSocket handshake using the configured API prefix and request overrides.
    /// A rejected workload token may reopen the handshake once within the request retry budget.
    public func connect(
        path: String,
        options: RequestOptions = .init(),
        webSocketOptions: WebSocketOptions = .init(),
        transport: (any OpenAIWebSocketTransport)? = nil
    ) async throws -> OpenAIJSONConnection {
        return try await AuthenticationRetryScope.withScope(configuration: configuration, options: options) {
            try webSocketOptions.validate()
            guard options.extraBody.isEmpty && options.jsonMutations.isEmpty else {
                throw OpenAIClientError.invalidConfiguration("A WebSocket handshake does not accept extraBody")
            }
            var request = try await authorizedRequest(.get, path: path, options: options)
            guard let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw OpenAIClientError.invalidConfiguration("Invalid WebSocket endpoint URL")
            }
            components.scheme = components.scheme?.lowercased() == "https" ? "wss" : "ws"
            request.url = components.url
            let resolvedTransport = transport ?? configuration.webSocketTransport ?? URLSessionWebSocketTransport()
            let connection: any OpenAIWebSocketConnection
            do {
                connection = try await openWebSocket(
                    resolvedTransport, request: request, options: options, webSocketOptions: webSocketOptions)
            } catch let error as OpenAIWebSocketError {
                guard case .handshakeFailed(let status, _, _) = error, status == 401,
                    !options.overridesAuthorization,
                    !configuration.headers.keys.contains(where: { $0.lowercased() == "authorization" }),
                    let authorization = request.value(forHTTPHeaderField: "Authorization"),
                    authorization.hasPrefix("Bearer "), let refresh = configuration.refreshUnauthorized,
                    await refresh(String(authorization.dropFirst(7))),
                    (options.maxRetries ?? configuration.maxRetries) > 0,
                    AuthenticationRetryScope.current?.reserveUnauthorizedReplay() ?? true
                else { throw error }
                let updated = try await authorizedRequest(.get, path: path, options: options)
                request.setValue(
                    updated.value(forHTTPHeaderField: "Authorization"), forHTTPHeaderField: "Authorization")
                connection = try await openWebSocket(
                    resolvedTransport, request: request, options: options, webSocketOptions: webSocketOptions)
            }
            if let response = connection.handshakeResponse { configuration.responseObserver?(response) }

            return OpenAIJSONConnection(connection: connection, maxMessageBytes: webSocketOptions.maxMessageBytes)
        }
    }
    private func openWebSocket(
        _ transport: any OpenAIWebSocketTransport, request: URLRequest, options: RequestOptions,
        webSocketOptions: WebSocketOptions
    ) async throws -> any OpenAIWebSocketConnection {
        let end = try RequestDeadline.end(
            timeout: request.timeoutInterval == RequestDeadline.unlimitedInterval ? 0 : request.timeoutInterval,
            deadline: options.deadline)
        return try await RequestDeadline.run(until: end) {
            try await transport.connect(request, options: webSocketOptions)
        }
    }
}

extension ResponsesService {
    /// Opens a persistent Responses connection. Send turns with `createResponse` and read events directly.
    public func connect(
        options: RequestOptions = .init(),
        webSocketOptions: WebSocketOptions = .init(),
        transport: (any OpenAIWebSocketTransport)? = nil
    ) async throws -> OpenAIJSONConnection {
        try await client.connect(
            path: "responses", options: options, webSocketOptions: webSocketOptions, transport: transport)
    }
}

extension RealtimeService {
    /// Opens a Realtime JSON event connection for a model. Audio payloads use the API's base64 JSON fields.
    public func connect(
        model: String,
        options: RequestOptions = .init(),
        webSocketOptions: WebSocketOptions = .init(),
        transport: (any OpenAIWebSocketTransport)? = nil
    ) async throws -> OpenAIJSONConnection {
        guard !model.isEmpty else { throw OpenAIClientError.invalidConfiguration("A Realtime model is required") }
        var options = options
        options.query["model"] = model
        return try await client.connect(
            path: "realtime", options: options, webSocketOptions: webSocketOptions, transport: transport)
    }
}
