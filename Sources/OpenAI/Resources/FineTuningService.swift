import Foundation

/// Fine-tuning jobs, checkpoint permissions, and grader operations with flexible JSON schemas.
public struct FineTuningService: Sendable {
    public let jobs: APIResource
    public let checkpoints: APIResource

    public init(client: OpenAIClient) {
        jobs = client.resource("fine_tuning/jobs")
        checkpoints = client.resource("fine_tuning/checkpoints")
    }

    public func create(_ body: JSONValue, options: RequestOptions = .init()) async throws -> JSONValue {
        try await jobs.create(body, options: options)
    }

    public func retrieve(_ id: String, options: RequestOptions = .init()) async throws -> JSONValue {
        try await jobs.retrieve(id, options: options)
    }

    public func list(options: RequestOptions = .init()) async throws -> Page<JSONValue> {
        try await jobs.list(options: options)
    }

    public func events(_ jobID: String) -> APIResource { jobs.nested(jobID, "events") }
    public func jobCheckpoints(_ jobID: String) -> APIResource { jobs.nested(jobID, "checkpoints") }
    public func permissions(_ checkpointID: String) -> APIResource { checkpoints.nested(checkpointID, "permissions") }

    public func cancel(_ jobID: String, options: RequestOptions = .init()) async throws -> JSONValue {
        try await jobs.action(jobID, "cancel", options: options)
    }

    public func pause(_ jobID: String, options: RequestOptions = .init()) async throws -> JSONValue {
        try await jobs.action(jobID, "pause", options: options)
    }

    public func resume(_ jobID: String, options: RequestOptions = .init()) async throws -> JSONValue {
        try await jobs.action(jobID, "resume", options: options)
    }

    public func listEvents(_ jobID: String, options: RequestOptions = .init()) async throws -> Page<JSONValue> {
        try await events(jobID).list(options: options)
    }

    public func listCheckpoints(_ jobID: String, options: RequestOptions = .init()) async throws -> Page<JSONValue> {
        try await jobCheckpoints(jobID).list(options: options)
    }

    /// Grants access to a fine-tuned checkpoint. The request commonly contains `project_ids`.
    public func createPermission(
        checkpointID: String, body: JSONValue, options: RequestOptions = .init()
    ) async throws -> JSONValue {
        try await permissions(checkpointID).create(body, options: options)
    }

    public func listPermissions(
        checkpointID: String, options: RequestOptions = .init()
    ) async throws -> Page<JSONValue> {
        try await permissions(checkpointID).list(options: options)
    }

    public func deletePermission(
        _ permissionID: String, checkpointID: String, options: RequestOptions = .init()
    ) async throws -> JSONValue {
        try await permissions(checkpointID).delete(permissionID, options: options)
    }

    public func runGrader(_ body: JSONValue, options: RequestOptions = .init()) async throws -> JSONValue {
        try await jobs.client.send(.post, path: "fine_tuning/alpha/graders/run", body: body, options: options)
    }

    public func validateGrader(_ body: JSONValue, options: RequestOptions = .init()) async throws -> JSONValue {
        try await jobs.client.send(.post, path: "fine_tuning/alpha/graders/validate", body: body, options: options)
    }
}
