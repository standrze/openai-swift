import Foundation

/// A non-success HTTP response, retaining server diagnostics and request identifiers.
public struct APIError: Error, Sendable, LocalizedError {
    public let statusCode: Int
    public let message: String
    public let type: String?
    public let code: JSONValue?
    public let param: JSONValue?
    public let requestID: String?
    public let headers: [String: String]
    public let responseBody: Data

    public var errorDescription: String? { "HTTP \(statusCode): \(message)" }

    init(response: HTTPResponse) {
        statusCode = response.statusCode
        headers = response.headers
        responseBody = response.data
        requestID = response.header("x-request-id") ?? response.header("request-id")
        let json = try? JSONDecoder().decode(JSONValue.self, from: response.data)
        let error = json?["error"] ?? json
        message =
            error?["message"]?.stringValue ?? error?.stringValue
            ?? String(data: response.data.prefix(4096), encoding: .utf8) ?? "Request failed"
        type = error?["type"]?.stringValue
        code = error?["code"]
        param = error?["param"]
    }
}

/// Client-side failures distinct from HTTP status errors and underlying network errors.
public enum OpenAIClientError: Error, Sendable, LocalizedError {
    case invalidConfiguration(String)
    case invalidPath(String)
    case invalidResponse
    case decoding(String)
    case streamOverflow
    case streamEventTooLarge
    case invalidStream(String)
    case pagination(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail): return "Invalid client configuration: \(detail)"
        case .invalidPath(let path): return "Invalid API path: \(path)"
        case .invalidResponse: return "The transport did not return an HTTP response"
        case .decoding(let detail): return "Could not decode the API response: \(detail)"
        case .streamOverflow: return "The stream consumer exceeded the configured event buffer"
        case .streamEventTooLarge: return "An SSE event exceeded the configured byte limit"
        case .invalidStream(let detail): return "Invalid event stream: \(detail)"
        case .pagination(let detail): return "Could not advance the API page: \(detail)"
        }
    }
}
