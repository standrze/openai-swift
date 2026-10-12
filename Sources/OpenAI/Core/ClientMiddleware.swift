import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Intercepts each HTTP attempt. Client middleware wraps request middleware in declaration order.
/// Implement both methods when supporting JSON and streaming operations. Never consume an SSE body to log it.
public protocol ClientMiddleware: Sendable {
    func send(_ request: URLRequest, next: any OpenAITransport) async throws -> HTTPResponse
    func stream(_ request: URLRequest, next: any OpenAITransport) async throws -> HTTPStreamResponse
}

extension ClientMiddleware {
    public func send(_ request: URLRequest, next: any OpenAITransport) async throws -> HTTPResponse {
        try await next.send(request)
    }
    public func stream(_ request: URLRequest, next: any OpenAITransport) async throws -> HTTPStreamResponse {
        try await next.stream(request)
    }
}

struct MiddlewareTransport: OpenAITransport {
    let middleware: any ClientMiddleware
    let next: any OpenAITransport
    func send(_ request: URLRequest) async throws -> HTTPResponse { try await middleware.send(request, next: next) }
    func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
        try await middleware.stream(request, next: next)
    }
}

/// Safe diagnostic events contain no credentials, URL query, body, or header values.
public enum ClientDiagnostic: Sendable {
    case request(method: String, path: String, attempt: Int)
    case response(status: Int, attempt: Int)
}

/// Request signing runs inside caller middleware, after any byte transformations, on each attempt.
struct PreparedTransport: OpenAITransport {
    let transport: any OpenAITransport
    let prepare: @Sendable (URLRequest, Int) async throws -> URLRequest
    let attempt: Int
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        try await transport.send(prepare(request, attempt))
    }
    func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
        try await transport.stream(prepare(request, attempt))
    }
}
