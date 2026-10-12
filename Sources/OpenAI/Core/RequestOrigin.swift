import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Validates the final destination after request middleware and provider signing have run.
public enum RequestOrigin {
    public static func validate(_ url: URL?, expected: URL) throws {
        func origin(_ url: URL?) -> String? {
            guard let url, let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(),
                url.user == nil, url.password == nil, ["http", "https"].contains(scheme)
            else { return nil }
            return "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
        }
        guard let actual = origin(url), actual == origin(expected) else {
            throw OpenAIClientError.invalidConfiguration("Request middleware changed the configured API origin")
        }
    }
}

struct OriginRestrictedTransport: OpenAITransport {
    let transport: any OpenAITransport
    let origin: URL
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        try RequestOrigin.validate(request.url, expected: origin)
        return try await transport.send(request)
    }
    func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
        try RequestOrigin.validate(request.url, expected: origin)
        return try await transport.stream(request)
    }
}
