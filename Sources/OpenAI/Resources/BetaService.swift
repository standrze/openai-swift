import Foundation

/// Beta resource groups with their required version headers and query parameters.
public struct BetaService: Sendable {
    public let agents: AgentsService
    public let chatKit: ChatKitService
    public let responses: BetaResponsesService
    public let assistants: APIResource
    public let threads: ThreadsService

    public init(client: OpenAIClient) {
        agents = AgentsService(client: client)
        chatKit = ChatKitService(client: client)
        responses = BetaResponsesService(client: client)
        assistants = APIResource(
            client: client, path: "assistants", defaultOptions: .init(headers: ["OpenAI-Beta": "assistants=v2"]))
        threads = ThreadsService(client: client)
    }
}

/// The Responses API beta variant. Each operation supplies the required `beta=true` query parameter.
public struct BetaResponsesService: Sendable {
    private let service: ResponsesService
    private let resource: APIResource

    public init(client: OpenAIClient) {
        service = ResponsesService(client: client)
        resource = APIResource(client: client, path: "responses", defaultOptions: .init(query: ["beta": "true"]))
    }

    public func create(_ request: ResponseRequest, options: RequestOptions = .init()) async throws -> Response {
        try await service.create(request, options: resource.mergedOptions(options))
    }

    public func stream(_ request: ResponseRequest, options: RequestOptions = .init()) async throws -> OpenAIStream<
        ResponseEvent
    > {
        try await service.stream(request, options: resource.mergedOptions(options))
    }

    public func retrieve(_ id: String, options: RequestOptions = .init()) async throws -> Response {
        try await service.retrieve(id, options: resource.mergedOptions(options))
    }

    public func retrieveStream(
        _ id: String, startingAfter: Int? = nil, options: RequestOptions = .init()
    ) async throws -> OpenAIStream<ResponseEvent> {
        try await service.retrieveStream(id, startingAfter: startingAfter, options: resource.mergedOptions(options))
    }

    public func delete(_ id: String, options: RequestOptions = .init()) async throws {
        try await service.delete(id, options: resource.mergedOptions(options))
    }

    public func cancel(_ id: String, options: RequestOptions = .init()) async throws -> Response {
        try await service.cancel(id, options: resource.mergedOptions(options))
    }

    public func compact(_ body: JSONValue, options: RequestOptions = .init()) async throws -> JSONValue {
        try await service.compact(body, options: resource.mergedOptions(options))
    }

    public func inputItems(_ id: String, options: RequestOptions = .init()) async throws -> Page<JSONValue> {
        try await service.inputItems(id, options: resource.mergedOptions(options))
    }

    public func inputTokens(_ body: JSONValue, options: RequestOptions = .init()) async throws -> JSONValue {
        try await service.inputTokens(body, options: resource.mergedOptions(options))
    }
}
