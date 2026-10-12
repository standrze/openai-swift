import Foundation

/// Embedding input in any of the four formats accepted by the compatible API.
public enum EmbeddingInput: Codable, Sendable, Equatable, ExpressibleByStringLiteral {
    case text(String)
    case texts([String])
    case tokens([Int])
    case tokenArrays([[Int]])

    public init(stringLiteral value: String) {
        self = .text(value)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else if let texts = try? container.decode([String].self) {
            self = .texts(texts)
        } else if let tokens = try? container.decode([Int].self) {
            self = .tokens(tokens)
        } else {
            self = .tokenArrays(try container.decode([[Int]].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value): try container.encode(value)
        case .texts(let value): try container.encode(value)
        case .tokens(let value): try container.encode(value)
        case .tokenArrays(let value): try container.encode(value)
        }
    }
}

/// Parameters for embedding text or tokenized input.
public struct EmbeddingRequest: Codable, Sendable {
    public var model: String
    public var input: EmbeddingInput
    public var dimensions: Int?
    public var encodingFormat: String?
    public var user: String?

    public init(model: String, input: EmbeddingInput, dimensions: Int? = nil, encodingFormat: String? = nil) {
        self.model = model
        self.input = input
        self.dimensions = dimensions
        self.encodingFormat = encodingFormat
    }

    enum CodingKeys: String, CodingKey {
        case model, input, dimensions, user
        case encodingFormat = "encoding_format"
    }
}

/// A vector as numeric values or the API's original base64 representation.
public enum EmbeddingVector: Codable, Sendable, Equatable {
    case floats([Double])
    case base64(String)

    public var floats: [Double]? {
        guard case .floats(let values) = self else { return nil }
        return values
    }

    public var base64: String? {
        guard case .base64(let value) = self else { return nil }
        return value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let encoded = try? container.decode(String.self) {
            self = .base64(encoded)
        } else {
            self = .floats(try container.decode([Double].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .floats(let values): try container.encode(values)
        case .base64(let value): try container.encode(value)
        }
    }
}

/// A generated embedding and its original input index.
public struct Embedding: Codable, Sendable, Equatable {
    public let object: String?
    public let index: Int
    public let embedding: EmbeddingVector
}

/// A batch of embedding vectors with token usage.
public struct EmbeddingResponse: Codable, Sendable, Equatable {
    public let object: String?
    public let data: [Embedding]
    public let model: String?
    public let usage: EmbeddingUsage?
}

/// Token accounting returned by the embeddings API.
public struct EmbeddingUsage: Codable, Sendable, Equatable {
    public let promptTokens: Int?
    public let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case totalTokens = "total_tokens"
    }
}

/// Creates numeric or base64 embeddings.
public struct EmbeddingsService: Sendable {
    private let client: OpenAIClient

    public init(client: OpenAIClient) {
        self.client = client
    }

    public func create(
        _ request: EmbeddingRequest,
        options: RequestOptions = .init()
    ) async throws -> EmbeddingResponse {
        try await client.send(.post, path: "embeddings", body: request, options: options)
    }
}
