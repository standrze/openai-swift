import Foundation

/// Chat resource group mirroring the service-oriented structure of openai-go.
public struct ChatService: Sendable {
    public let client: OpenAIClient

    public init(client: OpenAIClient) { self.client = client }

    public var completions: ChatCompletionsService { ChatCompletionsService(client: client) }
}

/// Creates, streams, and manages stored chat completions.
public struct ChatCompletionsService: Sendable {
    public let client: OpenAIClient

    public init(client: OpenAIClient) { self.client = client }

    /// Creates a completed response. This operation always sends `stream: false`.
    public func create(
        _ request: ChatCompletionRequest,
        options: RequestOptions = .init()
    ) async throws -> ChatCompletion {
        var options = options
        options.extraBody["stream"] = .bool(false)
        return try await client.send(.post, path: "chat/completions", body: request, options: options)
    }

    /// Starts an SSE stream. The caller owns consumption and cancellation of the returned stream.
    public func stream(
        _ request: ChatCompletionRequest,
        options: RequestOptions = .init()
    ) async throws -> OpenAIStream<ChatCompletionChunk> {
        var options = options
        options.extraBody["stream"] = .bool(true)
        return try await client.stream(path: "chat/completions", body: request, options: options)
    }

    /// Retrieves a completion that was created with storage enabled.
    public func retrieve(_ id: String, options: RequestOptions = .init()) async throws -> ChatCompletion {
        try await client.send(.get, path: path(id), options: options)
    }

    /// Lists stored completions. Pagination and filters can be supplied with request query options.
    public func list(options: RequestOptions = .init()) async throws -> Page<ChatCompletion> {
        try await client.send(.get, path: "chat/completions", options: options)
    }

    /// Updates a stored completion's metadata.
    public func update(
        _ id: String,
        metadata: [String: String],
        options: RequestOptions = .init()
    ) async throws -> ChatCompletion {
        try await client.send(.post, path: path(id), body: StoredChatUpdate(metadata: metadata), options: options)
    }

    /// Deletes a stored completion.
    public func delete(_ id: String, options: RequestOptions = .init()) async throws -> DeletedObject {
        try await client.send(.delete, path: path(id), options: options)
    }

    /// Lists messages associated with a stored completion.
    public func messages(_ id: String, options: RequestOptions = .init()) async throws -> Page<ChatStoredMessage> {
        try await client.send(.get, path: path(id) + "/messages", options: options)
    }

    private func path(_ id: String) -> String {
        "chat/completions/" + OpenAIClient.pathComponent(id)
    }
}

/// A stored message includes its server identifier in addition to conversational fields.
public struct ChatStoredMessage: Codable, Sendable, Equatable {
    public var id: String?
    public var role: String
    public var content: ChatContent?
    public var toolCalls: [ChatToolCall]?
    public var toolCallID: String?
    public var name: String?

    public init(
        id: String? = nil,
        role: String,
        content: ChatContent? = nil,
        toolCalls: [ChatToolCall]? = nil,
        toolCallID: String? = nil,
        name: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.name = name
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, content, name
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }
}

private struct StoredChatUpdate: Codable, Sendable {
    var metadata: [String: String]
}
