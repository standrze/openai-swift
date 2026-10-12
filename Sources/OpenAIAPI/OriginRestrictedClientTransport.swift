import Foundation
import HTTPTypes
import OpenAI
import OpenAPIRuntime

struct OriginRestrictedClientTransport: ClientTransport {
    let transport: any ClientTransport
    let origin: URL
    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPTypes.HTTPResponse, HTTPBody?) {
        try RequestOrigin.validate(baseURL, expected: origin)
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        if let scheme = request.scheme { components?.scheme = scheme }
        if let authority = request.authority {
            guard let absolute = URL(string: "\(components?.scheme ?? "https")://\(authority)") else {
                throw OpenAIClientError.invalidConfiguration("Invalid request authority")
            }
            try RequestOrigin.validate(absolute, expected: origin)
        }
        try RequestOrigin.validate(components?.url, expected: origin)
        return try await transport.send(request, body: body, baseURL: baseURL, operationID: operationID)
    }
}
