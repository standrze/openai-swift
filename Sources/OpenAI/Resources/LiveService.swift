import Foundation

/// Creates live sessions, controls calls, and downloads recording bytes.
public struct LiveService: Sendable {
    public let sessions: APIResource

    public init(client: OpenAIClient) { sessions = client.resource("live/sessions") }

    public func create(_ body: JSONValue, options: RequestOptions = .init()) async throws -> JSONValue {
        try await sessions.create(body, options: options)
    }

    public func accept(_ id: String, body: JSONValue, options: RequestOptions = .init()) async throws {
        _ = try await sessions.client.download(.post, path: path(id, "accept"), body: body, options: options)
    }

    public func downloadRecording(_ id: String, options: RequestOptions = .init()) async throws -> HTTPResponse {
        try await sessions.client.download(.get, path: path(id, "content"), options: options)
    }

    public func fork(_ id: String, body: JSONValue = [:], options: RequestOptions = .init()) async throws -> JSONValue {
        try await sessions.action(id, "fork", body: body, options: options)
    }

    public func hangup(_ id: String, options: RequestOptions = .init()) async throws {
        _ = try await sessions.client.download(.post, path: path(id, "hangup"), options: options)
    }

    public func refer(_ id: String, targetURI: String, options: RequestOptions = .init()) async throws {
        _ = try await sessions.client.download(
            .post, path: path(id, "refer"), body: JSONValue.object(["target_uri": .string(targetURI)]), options: options
        )
    }

    public func reject(_ id: String, body: JSONValue = [:], options: RequestOptions = .init()) async throws {
        _ = try await sessions.client.download(.post, path: path(id, "reject"), body: body, options: options)
    }

    private func path(_ id: String, _ action: String) -> String {
        sessions.path + "/" + OpenAIClient.pathComponent(id) + "/" + action
    }
}
