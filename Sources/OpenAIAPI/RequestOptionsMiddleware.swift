import Foundation
import HTTPTypes
import OpenAI
import OpenAPIRuntime

/// Applies OpenAI request overrides to generated operations without changing generated source.
/// JSON edits buffer only JSON request bodies, up to maxJSONBytes; multipart files remain streaming.
public struct RequestOptionsMiddleware: OpenAPIRuntime.ClientMiddleware {
    public let options: RequestOptions
    public let maxJSONBytes: Int
    public init(_ options: RequestOptions, maxJSONBytes: Int = 32 * 1024 * 1024) {
        self.options = options
        self.maxJSONBytes = maxJSONBytes
    }
    public func intercept(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPTypes.HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPTypes.HTTPResponse, HTTPBody?) {
        var request = request
        var body = body
        for (name, value) in options.headers {
            try HeaderMutation.validate(name: name, value: value)
            guard let field = HTTPField.Name(name) else {
                throw OpenAIClientError.invalidConfiguration("Invalid HTTP header")
            }
            request.headerFields[field] = value
        }
        for mutation in options.headerMutations {
            try HeaderMutation.validate(name: mutation.name, value: nil)
            guard let name = HTTPField.Name(mutation.name) else {
                throw OpenAIClientError.invalidConfiguration("Invalid HTTP header")
            }
            switch mutation {
            case .set(_, let value):
                try HeaderMutation.validate(name: mutation.name, value: value)
                request.headerFields[name] = value
            case .add(_, let value):
                try HeaderMutation.validate(name: mutation.name, value: value)
                request.headerFields.append(HTTPField(name: name, value: value))
            case .delete: request.headerFields[name] = nil
            }
        }
        if !options.query.isEmpty || !options.queryItems.isEmpty || !options.queryMutations.isEmpty {
            guard var components = URLComponents(string: request.path ?? "/") else {
                throw OpenAIClientError.invalidPath(request.path ?? "")
            }
            let names = Set(options.query.keys)
            var query = (components.queryItems ?? []).filter { !names.contains($0.name) }
            query += options.query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            query += options.queryItems
            for mutation in options.queryMutations { mutation.apply(to: &query) }
            components.queryItems = query
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            request.path = components.string
        }
        if !options.extraBody.isEmpty || !options.jsonMutations.isEmpty {
            guard request.headerFields[.contentType]?.hasPrefix("application/json") == true, let original = body,
                maxJSONBytes > 0
            else {
                throw OpenAIClientError.invalidConfiguration("JSON overrides require a JSON request body")
            }
            let raw = try await Data(collecting: original, upTo: maxJSONBytes)
            var value = try JSONDecoder().decode(JSONValue.self, from: raw)
            if !options.extraBody.isEmpty {
                guard var object = value.objectValue else {
                    throw OpenAIClientError.invalidConfiguration("extraBody requires an object")
                }
                object.merge(options.extraBody, uniquingKeysWith: { _, override in override })
                value = .object(object)
            }
            for mutation in options.jsonMutations { try mutation.apply(to: &value) }
            body = HTTPBody(try JSONEncoder().encode(value))
            request.headerFields[.contentLength] = nil
        }
        if let replacement = options.bodyOverride {
            try HeaderMutation.validate(name: "Content-Type", value: replacement.contentType)
            body = HTTPBody(replacement.data)
            request.headerFields[.contentType] = replacement.contentType
            request.headerFields[.contentLength] = nil
        }
        return try await next(request, body, options.baseURL ?? baseURL)

    }
}
