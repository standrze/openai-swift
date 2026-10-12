import Foundation

/// A decoded result together with the unmodified success response and exact JSON field bytes.
public struct APIResult<Value: Sendable>: Sendable {
    public let value: Value
    public let response: HTTPResponse
    public var document: JSONDocument { get throws { try JSONDocument(data: response.data) } }
}

final class ResponseCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var response: HTTPResponse?
    func store(_ response: HTTPResponse) { lock.withLock { self.response = response } }
    func read() -> HTTPResponse? { lock.withLock { response } }
}

extension OpenAIClient {
    /// Captures the last response from a typed operation, including any service method.
    /// The closure must perform one operation on the supplied scoped client.
    public func withResponse<Value: Sendable>(
        _ operation: @Sendable (OpenAIClient) async throws -> Value
    ) async throws -> APIResult<Value> {
        let capture = ResponseCapture()
        var configuration = configuration
        let observer = configuration.responseObserver
        configuration.responseObserver = { response in
            capture.store(response)
            observer?(response)
        }
        let value = try await operation(reconfigured(configuration))
        guard let response = capture.read() else { throw OpenAIClientError.invalidResponse }
        return APIResult(value: value, response: response)
    }
}
