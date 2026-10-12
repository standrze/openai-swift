import Foundation

/// A model advertised by an OpenAI-compatible endpoint.
public struct OpenAIModel: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let object: String?
    public let created: Int64?
    public let ownedBy: String?

    public init(id: String, object: String? = nil, created: Int64? = nil, ownedBy: String? = nil) {
        self.id = id
        self.object = object
        self.created = created
        self.ownedBy = ownedBy
    }

    enum CodingKeys: String, CodingKey {
        case id, object, created
        case ownedBy = "owned_by"
    }
}

/// Lists available models and manages model resources where supported by the server.
public struct ModelsService: Sendable {
    private let client: OpenAIClient

    public init(client: OpenAIClient) {
        self.client = client
    }

    public func list(options: RequestOptions = .init()) async throws -> Page<OpenAIModel> {
        try await client.send(.get, path: "models", options: options)
    }

    public func retrieve(_ id: String, options: RequestOptions = .init()) async throws -> OpenAIModel {
        try await client.send(.get, path: "models/\(OpenAIClient.pathComponent(id))", options: options)
    }

    public func delete(_ id: String, options: RequestOptions = .init()) async throws -> DeletedObject {
        try await client.send(.delete, path: "models/\(OpenAIClient.pathComponent(id))", options: options)
    }
}
