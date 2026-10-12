import Foundation

/// Persistent conversations and their input/output items.
public struct ConversationsService: Sendable {
    public let conversations: APIResource

    public init(client: OpenAIClient) { conversations = client.resource("conversations") }

    public func create(_ body: JSONValue = [:], options: RequestOptions = .init()) async throws -> JSONValue {
        try await conversations.create(body, options: options)
    }

    public func retrieve(_ id: String, options: RequestOptions = .init()) async throws -> JSONValue {
        try await conversations.retrieve(id, options: options)
    }

    public func update(_ id: String, body: JSONValue, options: RequestOptions = .init()) async throws -> JSONValue {
        try await conversations.update(id, body: body, options: options)
    }

    public func delete(_ id: String, options: RequestOptions = .init()) async throws -> JSONValue {
        try await conversations.delete(id, options: options)
    }

    public func items(_ conversationID: String) -> APIResource { conversations.nested(conversationID, "items") }

    public func createItems(
        _ conversationID: String, items: [JSONValue], options: RequestOptions = .init()
    ) async throws -> JSONValue {
        try await self.items(conversationID).create(["items": .array(items)], options: options)
    }

    public func retrieveItem(
        _ itemID: String, conversationID: String, options: RequestOptions = .init()
    ) async throws -> JSONValue {
        try await items(conversationID).retrieve(itemID, options: options)
    }

    public func listItems(_ conversationID: String, options: RequestOptions = .init()) async throws -> Page<JSONValue> {
        try await items(conversationID).list(options: options)
    }

    public func deleteItem(
        _ itemID: String, conversationID: String, options: RequestOptions = .init()
    ) async throws -> JSONValue {
        try await items(conversationID).delete(itemID, options: options)
    }
}
