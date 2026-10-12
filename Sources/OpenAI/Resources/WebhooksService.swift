import Foundation

/// Manages webhook endpoint registrations. Signature verification is a separate operation.
public struct WebhooksService: Sendable {
    private let secret: String?
    public let endpoints: APIResource
    public let eventTypes: APIResource

    public init(client: OpenAIClient) {
        secret = client.configuration.webhookSecret
        endpoints = client.resource("webhook_endpoints")
        eventTypes = client.resource("webhook_event_types")
    }

    public func verifySignature(
        payload: Data, headers: [String: String], secret: String? = nil,
        tolerance: TimeInterval = 300, now: Date = Date()
    ) throws {
        try WebhookVerifier(secret: secret ?? self.secret ?? "", tolerance: tolerance)
            .verify(payload: payload, headers: headers, now: now)
    }

    public func unwrap(
        payload: Data, headers: [String: String], secret: String? = nil,
        tolerance: TimeInterval = 300, now: Date = Date()
    ) throws -> WebhookEvent {
        try WebhookVerifier(secret: secret ?? self.secret ?? "", tolerance: tolerance)
            .unwrap(payload: payload, headers: headers, now: now)
    }

    public func create(_ body: JSONValue, options: RequestOptions = .init()) async throws -> JSONValue {
        try await endpoints.create(body, options: options)
    }

    public func retrieve(_ id: String, options: RequestOptions = .init()) async throws -> JSONValue {
        try await endpoints.retrieve(id, options: options)
    }

    public func update(_ id: String, body: JSONValue, options: RequestOptions = .init()) async throws -> JSONValue {
        try await endpoints.update(id, body: body, options: options)
    }

    public func list(options: RequestOptions = .init()) async throws -> Page<JSONValue> {
        try await endpoints.list(options: options)
    }

    public func delete(_ id: String, options: RequestOptions = .init()) async throws -> JSONValue {
        try await endpoints.delete(id, options: options)
    }

    public func rotateSecret(_ id: String, body: JSONValue = [:], options: RequestOptions = .init()) async throws
        -> JSONValue
    {
        try await endpoints.action(id, "rotate_secret", body: body, options: options)
    }

    public func test(_ id: String, body: JSONValue, options: RequestOptions = .init()) async throws -> JSONValue {
        try await endpoints.action(id, "test", body: body, options: options)
    }
}
