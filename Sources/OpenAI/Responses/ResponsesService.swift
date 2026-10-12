import Foundation

/// Creates, streams, retrieves, and manages Responses API objects.
public struct ResponsesService: Sendable {
    let client: OpenAIClient

    public init(client: OpenAIClient) {
        self.client = client
    }

    /// Creates a response. Streaming is disabled even if `extraBody` asks for it.
    public func create(_ request: ResponseRequest, options: RequestOptions = .init()) async throws -> Response {
        var options = options
        options.extraBody["stream"] = .bool(false)
        return try await client.send(.post, path: "responses", body: request, options: options)
    }

    /// Streams events as they arrive. Cancelling iteration closes the response body.
    public func stream(
        _ request: ResponseRequest,
        options: RequestOptions = .init()
    ) async throws -> OpenAIStream<ResponseEvent> {
        var options = options
        options.extraBody["stream"] = .bool(true)
        return try await client.stream(path: "responses", body: request, options: options)
    }

    /// Retrieves a previously stored response.
    public func retrieve(_ id: String, options: RequestOptions = .init()) async throws -> Response {
        var options = options
        options.query["stream"] = "false"
        return try await client.send(.get, path: "responses/\(OpenAIClient.pathComponent(id))", options: options)
    }

    /// Streams a stored background response, optionally resuming after an event sequence number.
    public func retrieveStream(
        _ id: String,
        startingAfter: Int? = nil,
        options: RequestOptions = .init()
    ) async throws -> OpenAIStream<ResponseEvent> {
        var options = options
        options.query["stream"] = "true"
        if let startingAfter { options.query["starting_after"] = String(startingAfter) }
        return try await client.stream(path: "responses/\(OpenAIClient.pathComponent(id))", options: options)
    }

    /// Deletes a stored response. Accepts both empty and JSON deletion responses.
    public func delete(_ id: String, options: RequestOptions = .init()) async throws {
        _ = try await client.download(.delete, path: "responses/\(OpenAIClient.pathComponent(id))", options: options)
    }

    /// Cancels a response created with background processing enabled.
    public func cancel(_ id: String, options: RequestOptions = .init()) async throws -> Response {
        try await client.send(.post, path: "responses/\(OpenAIClient.pathComponent(id))/cancel", options: options)
    }

    /// Lists a response's input items. Supply pagination parameters through `options.query`.
    public func inputItems(_ id: String, options: RequestOptions = .init()) async throws -> Page<JSONValue> {
        try await client.send(.get, path: "responses/\(OpenAIClient.pathComponent(id))/input_items", options: options)
    }

    /// Compacts conversation items. The result retains every provider-defined field.
    public func compact(_ request: JSONValue, options: RequestOptions = .init()) async throws -> JSONValue {
        try await client.send(.post, path: "responses/compact", body: request, options: options)
    }

    /// Counts input tokens without generating a response.
    public func inputTokens(_ request: JSONValue, options: RequestOptions = .init()) async throws -> JSONValue {
        try await client.send(.post, path: "responses/input_tokens", body: request, options: options)
    }
}
