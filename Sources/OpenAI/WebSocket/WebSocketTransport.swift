import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// One complete WebSocket message. Frame fragmentation is handled by the transport.
public enum WebSocketMessage: Sendable, Equatable {
    case text(String)
    case data(Data)

    var bytes: Data {
        switch self {
        case .text(let text): Data(text.utf8)
        case .data(let data): data
        }
    }
}

/// Close codes that clients may transmit under RFC 6455.
public enum WebSocketCloseCode: Int, Sendable {
    case normalClosure = 1000
    case goingAway = 1001
    case protocolError = 1002
    case unsupportedData = 1003
    case invalidPayload = 1007
    case policyViolation = 1008
    case messageTooBig = 1009
    case internalServerError = 1011
    case serviceRestart = 1012
    case tryAgainLater = 1013
}

/// Limits for a single connection. Messages are pulled directly without a background queue.
public struct WebSocketOptions: Sendable {
    public var maxMessageBytes: Int
    public var handshakeTimeout: TimeInterval
    public var closeTimeout: TimeInterval

    public init(maxMessageBytes: Int = 0, handshakeTimeout: TimeInterval = 30, closeTimeout: TimeInterval = 5) {
        self.maxMessageBytes = maxMessageBytes
        self.handshakeTimeout = handshakeTimeout
        self.closeTimeout = closeTimeout
    }

    func validate() throws {
        guard maxMessageBytes >= 0, closeTimeout.isFinite, closeTimeout >= 0, closeTimeout <= 86_400,
            handshakeTimeout.isFinite,
            handshakeTimeout > 0, handshakeTimeout <= 86_400
        else { throw OpenAIClientError.invalidConfiguration("Invalid WebSocket message limit or handshake timeout") }
    }
}

/// An established connection. Only one receive operation may be active at a time.
public protocol OpenAIWebSocketConnection: Sendable {
    var handshakeResponse: HTTPResponse? { get }
    func send(_ message: WebSocketMessage) async throws
    func receive() async throws -> WebSocketMessage
    /// Initiates a close handshake. Invalid or oversized UTF-8 reasons are omitted.
    func close(code: WebSocketCloseCode, reason: Data?) async
    /// Immediately releases the underlying connection without waiting for a close handshake.
    func abort() async
}

extension OpenAIWebSocketConnection {
    public var handshakeResponse: HTTPResponse? { nil }
    public func abort() async { await close(code: .goingAway, reason: nil) }
    public func close() async { await close(code: .normalClosure, reason: nil) }
}

/// Inject a WebSocket stack for alternate platforms or deterministic tests.
public protocol OpenAIWebSocketTransport: Sendable {
    /// Returns after the upgrade handshake succeeds. A connection is never automatically replayed.
    func connect(_ request: URLRequest, options: WebSocketOptions) async throws -> any OpenAIWebSocketConnection
}

/// Protocol and response failures, retaining terminal server payloads for inspection.
public enum OpenAIWebSocketError: Error, Sendable, LocalizedError {
    case handshakeFailed(statusCode: Int?, headers: [String: String], message: String)
    case handshakeTimeout
    case closed(code: Int, reason: Data?)
    case concurrentReceive
    case messageTooLarge(limit: Int)
    case responseTerminated(ResponseEvent)

    public var errorDescription: String? {
        switch self {
        case .handshakeFailed(let status, _, let message):
            return "WebSocket handshake failed\(status.map { " (HTTP \($0))" } ?? ""): \(message)"
        case .handshakeTimeout: return "The WebSocket upgrade handshake timed out"
        case .closed(let code, let reason):
            return
                "WebSocket closed (\(code))\(reason.flatMap { String(data: $0, encoding: .utf8) }.map { ": \($0)" } ?? "")"
        case .concurrentReceive: return "Only one WebSocket receive operation may be active"
        case .messageTooLarge(let limit): return "A WebSocket message exceeded the \(limit)-byte limit"
        case .responseTerminated(let event): return "The response terminated with \(event.type)"
        }
    }
}
