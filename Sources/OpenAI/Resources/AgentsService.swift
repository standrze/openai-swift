import Foundation

/// Beta agent resources. Nested resources inherit `OpenAI-Beta: agents=v1`.
/// Remote agent execution occurs only when the application explicitly submits events.
public struct AgentsService: Sendable {
    public let agents: APIResource
    public let environments: APIResource
    public let environmentTemplates: APIResource
    public let sessions: APIResource
    public let vaults: VaultsService

    public init(client: OpenAIClient) {
        let options = RequestOptions(headers: ["OpenAI-Beta": "agents=v1"])
        agents = APIResource(client: client, path: "agents", defaultOptions: options)
        environments = APIResource(client: client, path: "agents/environments", defaultOptions: options)
        environmentTemplates = APIResource(
            client: client, path: "agents/environments/templates", defaultOptions: options)
        sessions = APIResource(client: client, path: "agents/sessions", defaultOptions: options)
        vaults = VaultsService(client: client)
    }

    public func create(_ body: JSONValue, options: RequestOptions = .init()) async throws -> JSONValue {
        try await agents.create(body, options: options)
    }

    public func retrieve(_ id: String, options: RequestOptions = .init()) async throws -> JSONValue {
        try await agents.retrieve(id, options: options)
    }

    public func update(_ id: String, body: JSONValue, options: RequestOptions = .init()) async throws -> JSONValue {
        try await agents.update(id, body: body, options: options)
    }

    public func list(options: RequestOptions = .init()) async throws -> Page<JSONValue> {
        try await agents.list(options: options)
    }

    public func delete(_ id: String, options: RequestOptions = .init()) async throws -> JSONValue {
        try await agents.delete(id, options: options)
    }

    public func environmentFiles(_ environmentID: String) -> APIResource { environments.nested(environmentID, "files") }
    public func artifacts(_ sessionID: String) -> APIResource { sessions.nested(sessionID, "artifacts") }
    public func items(_ sessionID: String) -> APIResource { sessions.nested(sessionID, "items") }
    public func traces(_ sessionID: String) -> APIResource { sessions.nested(sessionID, "traces") }
    public func turns(_ sessionID: String) -> APIResource { sessions.nested(sessionID, "turns") }
    public func subagents(_ sessionID: String) -> APIResource { sessions.nested(sessionID, "subagents") }
    public func turnItems(_ sessionID: String, turnID: String) -> APIResource {
        turns(sessionID).nested(turnID, "items")
    }
    public func subagentItems(_ sessionID: String, subagentID: String) -> APIResource {
        subagents(sessionID).nested(subagentID, "items")
    }
    public func subagentTurns(_ sessionID: String, subagentID: String) -> APIResource {
        subagents(sessionID).nested(subagentID, "turns")
    }
    public func subagentTurnItems(_ sessionID: String, subagentID: String, turnID: String) -> APIResource {
        subagentTurns(sessionID, subagentID: subagentID).nested(turnID, "items")
    }

    public func artifactContent(
        _ artifactID: String, sessionID: String, options: RequestOptions = .init()
    ) async throws -> HTTPResponse {
        try await sessions.client.download(
            .get, path: artifacts(sessionID).path + "/" + OpenAIClient.pathComponent(artifactID) + "/content",
            options: sessions.mergedOptions(options))
    }

    /// Explicitly submits an event. Set `Idempotency-Key` in request headers when replay protection is needed.
    public func submitEvent(
        _ sessionID: String, body: JSONValue, options: RequestOptions = .init()
    ) async throws {
        _ = try await sessions.client.download(
            .post, path: sessions.nested(sessionID, "events").path, body: body, options: sessions.mergedOptions(options)
        )
    }

    /// Subscribes to session events without submitting or executing new work.
    public func streamEvents(_ sessionID: String, options: RequestOptions = .init()) async throws -> OpenAIStream<
        JSONValue
    > {
        try await sessions.client.stream(
            path: sessions.nested(sessionID, "events").path, options: sessions.mergedOptions(options))
    }
}

/// Beta vaults and credentials. Credentials are transmitted only by explicit resource operations.
public struct VaultsService: Sendable {
    public let vaults: APIResource

    public init(client: OpenAIClient) {
        vaults = APIResource(
            client: client, path: "vaults", defaultOptions: .init(headers: ["OpenAI-Beta": "agents=v1"]))
    }

    public func credentials(_ vaultID: String) -> APIResource { vaults.nested(vaultID, "credentials") }
}

/// ChatKit beta sessions and saved threads.
public struct ChatKitService: Sendable {
    public let sessions: APIResource
    public let threads: APIResource

    public init(client: OpenAIClient) {
        let options = RequestOptions(headers: ["OpenAI-Beta": "chatkit_beta=v1"])
        sessions = APIResource(client: client, path: "chatkit/sessions", defaultOptions: options)
        threads = APIResource(client: client, path: "chatkit/threads", defaultOptions: options)
    }

    public func cancelSession(_ id: String, options: RequestOptions = .init()) async throws -> JSONValue {
        try await sessions.action(id, "cancel", options: options)
    }

    public func items(_ threadID: String) -> APIResource { threads.nested(threadID, "items") }
}
