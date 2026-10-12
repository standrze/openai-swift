import Foundation

/// An upstream REST operation with an explicit method, relative path template, and optional fixed query defaults.
/// The catalog includes every operation listed by the pinned openai-go API references.
public struct RESTEndpoint: Sendable, Hashable {
    public let name: String
    public let method: HTTPMethod
    public let pathTemplate: String
    public let upstreamSymbol: String

    public init(name: String, method: HTTPMethod, pathTemplate: String, upstreamSymbol: String = "") {
        self.name = name
        self.method = method
        self.pathTemplate = pathTemplate
        self.upstreamSymbol = upstreamSymbol
    }

    /// Required identifiers in template order. Values are escaped as single path components.
    public var parameterNames: [String] {
        templatePath.split(separator: "/").compactMap {
            guard $0.hasPrefix("{"), $0.hasSuffix("}") else { return nil }
            return String($0.dropFirst().dropLast())
        }
    }

    /// Rejects missing, empty, or unexpected path arguments instead of emitting a partially bound URL.
    public func path(parameters: [String: String] = [:]) throws -> String {
        guard Set(parameters.keys) == Set(parameterNames), parameters.values.allSatisfy({ !$0.isEmpty }) else {
            throw OpenAIClientError.invalidPath(
                "\(name) requires path parameters: \(parameterNames.joined(separator: ", "))")
        }
        return templatePath.split(separator: "/").map { segment in
            if segment.hasPrefix("{"), segment.hasSuffix("}"),
                let value = parameters[String(segment.dropFirst().dropLast())]
            {
                return OpenAIClient.pathComponent(value)
            }
            return String(segment)
        }.joined(separator: "/")
    }

    /// API versions that are part of the named operation, with caller overrides applied last.
    public func options(overriding options: RequestOptions = .init()) -> RequestOptions {
        var result = options
        var betaHeader: String?
        if pathTemplate.hasPrefix("agents") || pathTemplate.hasPrefix("vaults") { betaHeader = "agents=v1" }
        if pathTemplate.hasPrefix("assistants") || pathTemplate.hasPrefix("threads") { betaHeader = "assistants=v2" }
        if pathTemplate.hasPrefix("chatkit") { betaHeader = "chatkit_beta=v1" }
        if let betaHeader,
            !result.headers.keys.contains(where: { $0.caseInsensitiveCompare("OpenAI-Beta") == .orderedSame })
        {
            result.headers["OpenAI-Beta"] = betaHeader
        }
        if let query = pathTemplate.split(separator: "?", maxSplits: 1).dropFirst().first,
            let components = URLComponents(string: "https://catalog.invalid/?" + query)
        {
            for item in components.queryItems ?? []
            where result.query[item.name] == nil
                && !result.queryItems.contains(where: { $0.name == item.name })
            {
                result.query[item.name] = item.value ?? ""
            }
        }
        return result
    }

    private var templatePath: Substring {
        pathTemplate.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
    }
}

/// Executes the complete named endpoint catalog with JSON, original bytes, multipart, or streamed bodies.
/// It preserves evolving response schemas instead of imposing incomplete generated models.
public struct RESTClient: Sendable {
    public let client: OpenAIClient
    public init(client: OpenAIClient) { self.client = client }

    public func call(
        _ endpoint: RESTEndpoint, parameters: [String: String] = [:], body: JSONValue? = nil,
        options: RequestOptions = .init()
    ) async throws -> JSONValue {
        try await decode(endpoint, parameters: parameters, body: body, options: options)
    }

    /// Decodes any application-owned response type using a named upstream operation.
    public func decode<Response: Decodable & Sendable>(
        _ endpoint: RESTEndpoint, parameters: [String: String] = [:], body: JSONValue? = nil,
        options: RequestOptions = .init()
    ) async throws -> Response {
        let path = try endpoint.path(parameters: parameters)
        let options = endpoint.options(overriding: options)
        if let body { return try await client.send(endpoint.method, path: path, body: body, options: options) }
        return try await client.send(endpoint.method, path: path, options: options)
    }

    /// Returns raw bytes and response metadata, including empty DELETE results and binary downloads.
    public func response(
        _ endpoint: RESTEndpoint, parameters: [String: String] = [:], data: Data? = nil,
        contentType: String? = nil, options: RequestOptions = .init()
    ) async throws -> HTTPResponse {
        try await client.request(
            endpoint.method, path: endpoint.path(parameters: parameters), data: data,
            contentType: contentType, options: endpoint.options(overriding: options))
    }

    /// Uploads ordered and repeated multipart fields for a named POST operation.
    public func upload(
        _ endpoint: RESTEndpoint, parameters: [String: String] = [:], fields: [MultipartField] = [],
        files: [MultipartFile] = [], options: RequestOptions = .init()
    ) async throws -> HTTPResponse {
        guard endpoint.method == .post else {
            throw OpenAIClientError.invalidConfiguration("Multipart catalog operations require POST")
        }
        return try await client.uploadResponse(
            path: endpoint.path(parameters: parameters), fields: fields,
            files: files, options: endpoint.options(overriding: options))
    }

    /// Opens a named GET or POST SSE operation. Supply protocol-specific streaming fields in the body or query.
    public func stream<Event: Decodable & Sendable>(
        _ endpoint: RESTEndpoint, parameters: [String: String] = [:], body: JSONValue? = nil,
        options: RequestOptions = .init()
    ) async throws -> OpenAIStream<Event> {
        let path = try endpoint.path(parameters: parameters)
        let options = endpoint.options(overriding: options)
        switch endpoint.method {
        case .get: return try await client.stream(path: path, options: options)
        case .post: return try await client.stream(path: path, body: body ?? .object([:]), options: options)
        default: throw OpenAIClientError.invalidConfiguration("SSE catalog operations require GET or POST")
        }
    }

    /// Reads a named operation as incremental original bytes, for audio, recordings, or generated media.
    public func bytes(
        _ endpoint: RESTEndpoint, parameters: [String: String] = [:], data: Data? = nil,
        contentType: String? = nil, options: RequestOptions = .init()
    ) async throws -> HTTPStreamResponse {
        try await client.streamBytes(
            endpoint.method, path: endpoint.path(parameters: parameters), data: data,
            contentType: contentType, options: endpoint.options(overriding: options))
    }
}

/// Organization and project administration using the full named Admin endpoint catalog.
public struct AdminService: Sendable {
    public let api: RESTClient
    public let organization: APIResource
    public init(client: OpenAIClient) {
        api = RESTClient(client: client)
        organization = client.resource("organization")
    }

    public var projects: APIResource { organization.client.resource("organization/projects") }
    public var users: APIResource { organization.client.resource("organization/users") }
    public var groups: APIResource { organization.client.resource("organization/groups") }
    public var roles: APIResource { organization.client.resource("organization/roles") }
    public var invites: APIResource { organization.client.resource("organization/invites") }
    public var adminAPIKeys: APIResource { organization.client.resource("organization/admin_api_keys") }
    public var auditLogs: APIResource { organization.client.resource("organization/audit_logs") }
}
