import Foundation

/// Vector stores, attached files, and indexing batches.
public struct VectorStoresService: Sendable {
    public let stores: APIResource

    public init(client: OpenAIClient) { stores = client.resource("vector_stores") }

    public func create(_ body: JSONValue = [:], options: RequestOptions = .init()) async throws -> JSONValue {
        try await stores.create(body, options: options)
    }

    public func retrieve(_ id: String, options: RequestOptions = .init()) async throws -> JSONValue {
        try await stores.retrieve(id, options: options)
    }

    public func update(_ id: String, body: JSONValue, options: RequestOptions = .init()) async throws -> JSONValue {
        try await stores.update(id, body: body, options: options)
    }

    public func list(options: RequestOptions = .init()) async throws -> Page<JSONValue> {
        try await stores.list(options: options)
    }

    public func delete(_ id: String, options: RequestOptions = .init()) async throws -> JSONValue {
        try await stores.delete(id, options: options)
    }

    public func files(_ storeID: String) -> APIResource { stores.nested(storeID, "files") }
    public func fileBatches(_ storeID: String) -> APIResource { stores.nested(storeID, "file_batches") }

    public func search(_ storeID: String, body: JSONValue, options: RequestOptions = .init()) async throws -> JSONValue
    {
        try await stores.action(storeID, "search", body: body, options: options)
    }

    /// Retrieves parsed content chunks, rather than the original uploaded file bytes.
    public func fileContent(
        _ fileID: String, storeID: String, options: RequestOptions = .init()
    ) async throws -> JSONValue {
        try await stores.client.send(
            .get, path: files(storeID).path + "/" + OpenAIClient.pathComponent(fileID) + "/content", options: options)
    }

    public func cancelFileBatch(
        _ batchID: String, storeID: String, options: RequestOptions = .init()
    ) async throws -> JSONValue {
        try await fileBatches(storeID).action(batchID, "cancel", options: options)
    }

    public func listBatchFiles(
        _ batchID: String, storeID: String, options: RequestOptions = .init()
    ) async throws -> Page<JSONValue> {
        try await fileBatches(storeID).nested(batchID, "files").list(options: options)
    }
}
