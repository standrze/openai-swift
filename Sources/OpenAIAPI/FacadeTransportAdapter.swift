import Foundation
import HTTPTypes
import OpenAI
import OpenAPIRuntime

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Uses a facade transport with the generated client, including a sealed X.509 capability.
/// Request bodies are collected for URLRequest replay; response bodies remain incremental.
public struct FacadeTransportAdapter: ClientTransport {
    public let transport: any OpenAITransport
    public let maxRequestBytes: Int

    public init(_ transport: any OpenAITransport, maxRequestBytes: Int = Int.max) {
        self.transport = transport
        self.maxRequestBytes = maxRequestBytes
    }

    public func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPTypes.HTTPResponse, HTTPBody?) {
        guard maxRequestBytes >= 0 else {
            throw OpenAIClientError.invalidConfiguration("Maximum request size must be nonnegative")
        }
        var prefix = baseURL.absoluteString
        while prefix.hasSuffix("/") { prefix.removeLast() }
        guard let url = URL(string: prefix + (request.path ?? "/")) else {
            throw OpenAIClientError.invalidPath(request.path ?? "")
        }
        var native = URLRequest(url: url, timeoutInterval: RequestDeadline.unlimitedInterval)
        native.httpMethod = request.method.rawValue
        for field in request.headerFields { native.addValue(field.value, forHTTPHeaderField: field.name.rawName) }
        if let body { native.httpBody = try await Data(collecting: body, upTo: maxRequestBytes) }
        if let deadline = RequestDeadline.current { native.timeoutInterval = max(0.001, deadline.timeIntervalSinceNow) }
        let response = try await transport.stream(native)
        var headers = HTTPFields()
        for (name, value) in response.headers {
            if let field = HTTPField.Name(name) { headers.append(HTTPField(name: field, value: value)) }
        }
        let body = HTTPBody(TransportBody(response), length: .unknown, iterationBehavior: .single)
        return (HTTPTypes.HTTPResponse(status: .init(code: response.statusCode), headerFields: headers), body)
    }
}

extension Client {
    /// Shares the capability's issuer cache, retry budget, native identity, and admission lifecycle.
    public init(
        x509 capability: X509WorkloadIdentity, organization: String? = nil, project: String? = nil,
        maxRetries: Int = 2, requestOptions: RequestOptions = .init()
    ) throws {
        let facade = try capability.client(organization: organization, project: project, maxRetries: maxRetries)
        try self.init(
            openAIConfiguration: facade.configuration,
            transport: FacadeTransportAdapter(capability), requestOptions: requestOptions)
    }
}

private struct TransportBody: AsyncSequence, Sendable {
    typealias Element = ArraySlice<UInt8>
    let response: OpenAI.HTTPStreamResponse
    private let lifetime: TransportBodyLifetime

    init(_ response: OpenAI.HTTPStreamResponse) {
        self.response = response
        lifetime = TransportBodyLifetime(response.cancel)
    }
    struct AsyncIterator: AsyncIteratorProtocol {
        var base: AsyncThrowingStream<Data, any Error>.Iterator
        let lifetime: TransportBodyLifetime
        mutating func next() async throws -> ArraySlice<UInt8>? {
            do {
                guard let chunk = try await base.next() else {
                    lifetime.cancel()
                    return nil
                }
                return ArraySlice(chunk)
            } catch {
                lifetime.cancel()
                throw error
            }
        }
    }
    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: response.body.makeAsyncIterator(), lifetime: lifetime)
    }
}

private final class TransportBodyLifetime: Sendable {
    let cancel: @Sendable () -> Void
    init(_ cancel: @escaping @Sendable () -> Void) { self.cancel = cancel }
    deinit { cancel() }
}
