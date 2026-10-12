import Foundation

/// Parameters for executing an uploaded JSONL request file as a batch.
public struct BatchRequest: Codable, Sendable {
    public var inputFileID: String
    public var endpoint: String
    public var completionWindow: String
    public var metadata: [String: String]?

    public init(inputFileID: String, endpoint: String, completionWindow: String = "24h") {
        self.inputFileID = inputFileID
        self.endpoint = endpoint
        self.completionWindow = completionWindow
    }

    enum CodingKeys: String, CodingKey {
        case endpoint, metadata
        case inputFileID = "input_file_id"
        case completionWindow = "completion_window"
    }
}

/// Counts of requests in a batch.
public struct BatchRequestCounts: Codable, Sendable, Equatable {
    public let total: Int
    public let completed: Int
    public let failed: Int
}

/// A batch job and its lifecycle timestamps in Unix seconds.
public struct Batch: Codable, Sendable, Identifiable {
    public let id: String
    public let object: String?
    public let endpoint: String?
    public let inputFileID: String?
    public let completionWindow: String?
    public let status: String
    public let outputFileID: String?
    public let errorFileID: String?
    public let createdAt: Int64?
    public let inProgressAt: Int64?
    public let expiresAt: Int64?
    public let finalizingAt: Int64?
    public let completedAt: Int64?
    public let failedAt: Int64?
    public let expiredAt: Int64?
    public let cancellingAt: Int64?
    public let cancelledAt: Int64?
    public let requestCounts: BatchRequestCounts?
    public let errors: JSONValue?
    public let metadata: [String: String]?
    public let rawValue: JSONValue

    public init(from decoder: any Decoder) throws {
        rawValue = try JSONValue(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        object = try container.decodeIfPresent(String.self, forKey: .object)
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint)
        inputFileID = try container.decodeIfPresent(String.self, forKey: .inputFileID)
        completionWindow = try container.decodeIfPresent(String.self, forKey: .completionWindow)
        status = try container.decode(String.self, forKey: .status)
        outputFileID = try container.decodeIfPresent(String.self, forKey: .outputFileID)
        errorFileID = try container.decodeIfPresent(String.self, forKey: .errorFileID)
        createdAt = try container.decodeIfPresent(Int64.self, forKey: .createdAt)
        inProgressAt = try container.decodeIfPresent(Int64.self, forKey: .inProgressAt)
        expiresAt = try container.decodeIfPresent(Int64.self, forKey: .expiresAt)
        finalizingAt = try container.decodeIfPresent(Int64.self, forKey: .finalizingAt)
        completedAt = try container.decodeIfPresent(Int64.self, forKey: .completedAt)
        failedAt = try container.decodeIfPresent(Int64.self, forKey: .failedAt)
        expiredAt = try container.decodeIfPresent(Int64.self, forKey: .expiredAt)
        cancellingAt = try container.decodeIfPresent(Int64.self, forKey: .cancellingAt)
        cancelledAt = try container.decodeIfPresent(Int64.self, forKey: .cancelledAt)
        requestCounts = try container.decodeIfPresent(BatchRequestCounts.self, forKey: .requestCounts)
        errors = try container.decodeIfPresent(JSONValue.self, forKey: .errors)
        metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata)
    }

    public func encode(to encoder: any Encoder) throws {
        try rawValue.encode(to: encoder)
    }

    enum CodingKeys: String, CodingKey {
        case id, object, endpoint, status, errors, metadata
        case inputFileID = "input_file_id"
        case completionWindow = "completion_window"
        case outputFileID = "output_file_id"
        case errorFileID = "error_file_id"
        case createdAt = "created_at"
        case inProgressAt = "in_progress_at"
        case expiresAt = "expires_at"
        case finalizingAt = "finalizing_at"
        case completedAt = "completed_at"
        case failedAt = "failed_at"
        case expiredAt = "expired_at"
        case cancellingAt = "cancelling_at"
        case cancelledAt = "cancelled_at"
        case requestCounts = "request_counts"
    }
}

/// Creates and manages asynchronous request batches.
public struct BatchesService: Sendable {
    private let client: OpenAIClient

    public init(client: OpenAIClient) {
        self.client = client
    }

    public func create(_ request: BatchRequest, options: RequestOptions = .init()) async throws -> Batch {
        try await client.send(.post, path: "batches", body: request, options: options)
    }

    /// Lists batches. Supply `after` and `limit` through `options.query`.
    public func list(options: RequestOptions = .init()) async throws -> Page<Batch> {
        try await client.send(.get, path: "batches", options: options)
    }

    public func retrieve(_ id: String, options: RequestOptions = .init()) async throws -> Batch {
        try await client.send(.get, path: "batches/\(OpenAIClient.pathComponent(id))", options: options)
    }

    /// Requests cancellation; a job may remain `cancelling` while partial results are finalized.
    public func cancel(_ id: String, options: RequestOptions = .init()) async throws -> Batch {
        try await client.send(.post, path: "batches/\(OpenAIClient.pathComponent(id))/cancel", options: options)
    }
}
