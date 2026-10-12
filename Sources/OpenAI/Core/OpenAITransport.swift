import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// An HTTP response with raw bytes and case-insensitive header lookup.
public struct HTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int
    public let headers: [String: String]

    public init(data: Data, statusCode: Int, headers: [String: String] = [:]) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// Successful response headers plus incremental body chunks. Cancellation closes the connection.
public struct HTTPStreamResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: AsyncThrowingStream<Data, any Error>
    public let cancel: @Sendable () -> Void

    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        body: AsyncThrowingStream<Data, any Error>,
        cancel: @escaping @Sendable () -> Void = {}
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.cancel = cancel
    }
}

/// Inject a transport to test requests or integrate a different HTTP stack.
public protocol OpenAITransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
    func stream(_ request: URLRequest) async throws -> HTTPStreamResponse
}
