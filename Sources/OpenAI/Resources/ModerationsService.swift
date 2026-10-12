import Foundation

/// Text, text arrays, or multimodal moderation input expressed as JSON.
public struct ModerationRequest: Codable, Sendable {
    public var input: JSONValue
    public var model: String?

    public init(input: JSONValue, model: String? = nil) {
        self.input = input
        self.model = model
    }

    /// Creates a request from a single text input.
    public init(text: String, model: String? = nil) {
        self.init(input: .string(text), model: model)
    }
}

/// A moderation classification. Category names remain dynamic as models evolve.
public struct ModerationResult: Codable, Sendable, Equatable {
    public let flagged: Bool
    public let categories: [String: Bool]
    public let categoryScores: [String: Double]
    public let categoryAppliedInputTypes: [String: [String]]?

    enum CodingKeys: String, CodingKey {
        case flagged, categories
        case categoryScores = "category_scores"
        case categoryAppliedInputTypes = "category_applied_input_types"
    }
}

/// Classifications in the same order as the submitted moderation inputs.
public struct ModerationResponse: Codable, Sendable, Equatable {
    public let id: String
    public let model: String
    public let results: [ModerationResult]
}

/// Classifies text and multimodal content using the moderation endpoint.
public struct ModerationsService: Sendable {
    private let client: OpenAIClient

    public init(client: OpenAIClient) {
        self.client = client
    }

    public func create(
        _ request: ModerationRequest,
        options: RequestOptions = .init()
    ) async throws -> ModerationResponse {
        try await client.send(.post, path: "moderations", body: request, options: options)
    }
}
