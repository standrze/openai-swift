import Foundation

/// Creates decisions using evolving JSON input and response schemas.
public struct DecisionsService: Sendable {
    private let client: OpenAIClient

    public init(client: OpenAIClient) { self.client = client }

    public func create(_ body: JSONValue, options: RequestOptions = .init()) async throws -> JSONValue {
        try await client.send(.post, path: "decisions", body: body, options: options)
    }
}

/// Checks provenance using multipart content and provider-specific fields.
public struct ContentProvenanceChecksService: Sendable {
    private let client: OpenAIClient

    public init(client: OpenAIClient) { self.client = client }

    public func create(
        fields: [String: String] = [:], files: [MultipartFile], options: RequestOptions = .init()
    ) async throws -> JSONValue {
        try await client.upload(path: "content_provenance_checks", fields: fields, files: files, options: options)
    }
}

/// Retrieves safety cases and alerts. These endpoints require server-side access grants.
public struct SafetyService: Sendable {
    public let cases: APIResource
    public let alerts: APIResource

    public init(client: OpenAIClient) {
        cases = client.resource("safety/cases")
        alerts = client.resource("safety/alerts")
    }
}
