import Foundation

/// Evaluation resources retained for servers exposing this API family.
/// This family is outside the pinned upstream REST inventory; availability depends on the server.
public struct EvalsService: Sendable {
    public let evals: APIResource

    public init(client: OpenAIClient) { evals = client.resource("evals") }
    public func runs(_ evalID: String) -> APIResource { evals.nested(evalID, "runs") }
    public func outputItems(_ evalID: String, runID: String) -> APIResource {
        runs(evalID).nested(runID, "output_items")
    }

    public func cancelRun(_ runID: String, evalID: String, options: RequestOptions = .init()) async throws -> JSONValue
    {
        try await runs(evalID).action(runID, "cancel", options: options)
    }
}
