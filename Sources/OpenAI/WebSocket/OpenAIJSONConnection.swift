import Foundation

/// Pull-based JSON messaging for Responses, Realtime, and provider-defined WebSocket events.
/// Call `close()` when finished. Cancelling a native send or receive closes the connection.
public actor OpenAIJSONConnection {
    public nonisolated let handshakeResponse: HTTPResponse?
    private let connection: any OpenAIWebSocketConnection
    private let maxMessageBytes: Int
    private var receiving = false

    public init(connection: any OpenAIWebSocketConnection, maxMessageBytes: Int = 0) {
        self.connection = connection
        self.handshakeResponse = connection.handshakeResponse
        self.maxMessageBytes = maxMessageBytes
    }

    /// Encodes one complete JSON text message. Sending never reconnects or replays the payload.
    public func send<Value: Encodable & Sendable>(_ value: Value) async throws {
        let data = try (value as? JSONValue)?.encodedData() ?? JSONEncoder().encode(value)
        guard maxMessageBytes == 0 || data.count <= maxMessageBytes else {
            throw OpenAIWebSocketError.messageTooLarge(limit: maxMessageBytes)
        }
        try await connection.send(.text(String(decoding: data, as: UTF8.self)))
    }

    /// Reads one JSON event, preserving unknown fields and event kinds.
    public func receive() async throws -> JSONValue {
        try beginReceive()
        defer { receiving = false }
        return try await readJSON()
    }

    /// Reads one Responses event. Error events are returned intact for caller inspection.
    public func receiveResponseEvent() async throws -> ResponseEvent {
        try beginReceive()
        defer { receiving = false }
        return try decodeResponseEvent(await readBytes())
    }

    func receiveQueuedResponseEvent() async throws -> QueuedResponseEvent {
        try beginReceive()
        defer { receiving = false }
        let data = try await readBytes()
        let event = try decodeResponseEvent(data)
        return QueuedResponseEvent(event: event, bytes: data.count)
    }

    /// Sends Responses WebSocket `response.create`, using the HTTP request's top-level fields.
    /// `stream` is implicit; background responses are unsupported. Extensions may include `stream_id`.
    public func createResponse(_ request: ResponseRequest, extraBody: [String: JSONValue] = [:]) async throws {
        var body = try JSONValue.encode(request).objectValue ?? [:]
        body.merge(extraBody, uniquingKeysWith: { _, replacement in replacement })
        guard body["background"] != .bool(true) else {
            throw OpenAIClientError.invalidConfiguration("Background responses are not supported over WebSocket")
        }
        body.removeValue(forKey: "stream")
        body.removeValue(forKey: "background")
        body["type"] = "response.create"
        try await send(JSONValue.object(body))
    }

    /// Returns the authoritative completed, failed, or incomplete server payload, retaining its status.
    /// Protocol error events throw with the original event attached; EOF never establishes completion.
    /// Use `receive()` directly to route multiplexed Responses streams or Realtime events.
    public func finalResponse() async throws -> Response {
        try beginReceive()
        defer { receiving = false }
        var responseID: String?
        while true {
            let event: ResponseEvent
            do { event = try decodeResponseEvent(await readBytes()) } catch let error
                as OpenAIWebSocketError
            {
                if case .closed = error {
                    throw OpenAIClientError.invalidStream("WebSocket closed before a terminal response event")
                }
                throw error
            }
            if let incoming = event.response?.id, !incoming.isEmpty {
                if let responseID, responseID != incoming {
                    throw OpenAIClientError.invalidStream("Terminal response belongs to another response")
                }
                responseID = incoming
            }
            switch event.type {
            case "response.completed", "response.failed", "response.incomplete":
                guard let response = event.response else {
                    throw OpenAIClientError.invalidStream("Terminal response event is missing its server response")
                }
                return response
            case "error":
                throw OpenAIWebSocketError.responseTerminated(event)
            default:
                continue
            }
        }
    }

    /// Initiates the close handshake and releases the native transport's resources.
    public func close(code: WebSocketCloseCode = .normalClosure, reason: Data? = nil) async {
        await connection.close(code: code, reason: reason)
    }

    public func abort() async { await connection.abort() }

    private func beginReceive() throws {
        guard !receiving else { throw OpenAIWebSocketError.concurrentReceive }
        receiving = true
    }

    private func readJSON() async throws -> JSONValue {
        let data = try await readBytes()
        do { return try OpenAIJSON.decode(JSONValue.self, from: data) } catch {
            throw OpenAIClientError.decoding(String(describing: error))
        }
    }

    private func decodeResponseEvent(_ data: Data) throws -> ResponseEvent {
        let event: ResponseEvent
        do {
            event = try OpenAIJSON.decode(ResponseEvent.self, from: data)
        } catch DecodingError.keyNotFound(let key, _) where key.stringValue == "type" {
            throw OpenAIClientError.invalidStream("WebSocket event is missing type")
        }
        guard !event.type.isEmpty else { throw OpenAIClientError.invalidStream("WebSocket event is missing type") }
        return event
    }

    private func readBytes() async throws -> Data {
        let message = try await connection.receive()
        let data = message.bytes
        guard maxMessageBytes == 0 || data.count <= maxMessageBytes else {
            await connection.close(code: .messageTooBig, reason: nil)
            throw OpenAIWebSocketError.messageTooLarge(limit: maxMessageBytes)
        }
        return data
    }
}
