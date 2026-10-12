import Foundation

/// Assistants threads and runs. Tool calls are returned to the application and never executed automatically.
public struct ThreadsService: Sendable {
    public let threads: APIResource

    public init(client: OpenAIClient) {
        threads = APIResource(
            client: client, path: "threads", defaultOptions: .init(headers: ["OpenAI-Beta": "assistants=v2"]))
    }

    public func create(_ body: JSONValue = [:], options: RequestOptions = .init()) async throws -> JSONValue {
        try await threads.create(body, options: options)
    }

    public func retrieve(_ id: String, options: RequestOptions = .init()) async throws -> JSONValue {
        try await threads.retrieve(id, options: options)
    }

    public func update(_ id: String, body: JSONValue, options: RequestOptions = .init()) async throws -> JSONValue {
        try await threads.update(id, body: body, options: options)
    }

    public func delete(_ id: String, options: RequestOptions = .init()) async throws -> JSONValue {
        try await threads.delete(id, options: options)
    }

    public func messages(_ threadID: String) -> APIResource { threads.nested(threadID, "messages") }
    public func runs(_ threadID: String) -> APIResource { threads.nested(threadID, "runs") }
    public func steps(_ threadID: String, runID: String) -> APIResource { runs(threadID).nested(runID, "steps") }

    public func createAndRun(_ body: JSONValue, options: RequestOptions = .init()) async throws -> JSONValue {
        var options = threads.mergedOptions(options)
        options.extraBody["stream"] = false
        return try await threads.client.send(.post, path: "threads/runs", body: body, options: options)
    }

    public func createAndRunStream(
        _ body: JSONValue, options: RequestOptions = .init()
    ) async throws -> OpenAIStream<JSONValue> {
        var options = threads.mergedOptions(options)
        options.extraBody["stream"] = true
        return try await threads.client.stream(path: "threads/runs", body: body, options: options)
    }

    public func createRun(
        _ threadID: String, body: JSONValue, options: RequestOptions = .init()
    ) async throws -> JSONValue {
        var options = options
        options.extraBody["stream"] = false
        return try await runs(threadID).create(body, options: options)
    }

    public func streamRun(
        _ threadID: String, body: JSONValue, options: RequestOptions = .init()
    ) async throws -> OpenAIStream<JSONValue> {
        var options = runs(threadID).mergedOptions(options)
        options.extraBody["stream"] = true
        return try await threads.client.stream(path: runs(threadID).path, body: body, options: options)
    }

    public func cancelRun(
        _ runID: String, threadID: String, options: RequestOptions = .init()
    ) async throws -> JSONValue {
        try await runs(threadID).action(runID, "cancel", options: options)
    }

    public func submitToolOutputs(
        _ runID: String, threadID: String, outputs: [JSONValue], options: RequestOptions = .init()
    ) async throws -> JSONValue {
        var options = options
        options.extraBody["stream"] = false
        return try await runs(threadID).action(
            runID, "submit_tool_outputs", body: ["tool_outputs": .array(outputs)], options: options)
    }

    public func submitToolOutputsStream(
        _ runID: String, threadID: String, outputs: [JSONValue], options: RequestOptions = .init()
    ) async throws -> OpenAIStream<JSONValue> {
        var options = runs(threadID).mergedOptions(options)
        options.extraBody["stream"] = true
        let path = runs(threadID).path + "/" + OpenAIClient.pathComponent(runID) + "/submit_tool_outputs"
        return try await threads.client.stream(
            path: path, body: JSONValue.object(["tool_outputs": .array(outputs)]), options: options)
    }
}
