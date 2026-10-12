import Foundation

/// Common image generation parameters. Provider-specific fields use request options' `extraBody`.
public struct ImageGenerationRequest: Codable, Sendable {
    public var model: String?
    public var prompt: String
    public var n: Int?
    public var size: String?
    public var quality: String?
    public var responseFormat: String?
    public var style: String?
    public var user: String?
    public var background: String?
    public var outputFormat: String?
    public var outputCompression: Int?
    public var moderation: String?

    public init(prompt: String, model: String? = nil, n: Int? = nil, size: String? = nil) {
        self.prompt = prompt
        self.model = model
        self.n = n
        self.size = size
    }

    enum CodingKeys: String, CodingKey {
        case model, prompt, n, size, quality, style, user, background, moderation
        case responseFormat = "response_format"
        case outputFormat = "output_format"
        case outputCompression = "output_compression"
    }
}

/// An image URL or base64 payload returned by generation, editing, or variation.
public struct GeneratedImage: Codable, Sendable, Equatable {
    public let url: String?
    public let base64JSON: String?
    public let revisedPrompt: String?

    /// Decodes base64 image bytes when the response contains an inline payload.
    public var data: Data? {
        base64JSON.flatMap { Data(base64Encoded: $0) }
    }

    enum CodingKeys: String, CodingKey {
        case url
        case base64JSON = "b64_json"
        case revisedPrompt = "revised_prompt"
    }
}

/// An image operation result with optional token accounting.
public struct ImageResponse: Codable, Sendable, Equatable {
    public let created: Int64?
    public let data: [GeneratedImage]
    public let usage: JSONValue?
    public let background: String?
    public let outputFormat: String?
    public let quality: String?
    public let size: String?

    enum CodingKeys: String, CodingKey {
        case created, data, usage, background, quality, size
        case outputFormat = "output_format"
    }
}

/// Generates images and sends multipart image editing or variation requests.
public struct ImagesService: Sendable {
    private let client: OpenAIClient

    public init(client: OpenAIClient) {
        self.client = client
    }

    public func generate(
        _ request: ImageGenerationRequest,
        options: RequestOptions = .init()
    ) async throws -> ImageResponse {
        var options = options
        options.extraBody["stream"] = .bool(false)
        return try await client.send(.post, path: "images/generations", body: request, options: options)
    }

    /// Sends a flexible JSON generation request while preserving the typed image result.
    public func generate(_ request: JSONValue, options: RequestOptions = .init()) async throws -> ImageResponse {
        var options = options
        options.extraBody["stream"] = .bool(false)
        return try await client.send(.post, path: "images/generations", body: request, options: options)
    }

    /// Streams partial and completed image events. Event payloads retain all provider-defined fields.
    public func stream(
        _ request: ImageGenerationRequest,
        options: RequestOptions = .init()
    ) async throws -> OpenAIStream<JSONValue> {
        var options = options
        options.extraBody["stream"] = .bool(true)
        return try await client.stream(path: "images/generations", body: request, options: options)
    }

    /// Streams a flexible JSON image generation request.
    public func stream(_ request: JSONValue, options: RequestOptions = .init()) async throws -> OpenAIStream<JSONValue>
    {
        var options = options
        options.extraBody["stream"] = .bool(true)
        return try await client.stream(path: "images/generations", body: request, options: options)
    }

    /// Edits uploaded images. Use multipart field names `image`, `image[]`, and `mask` as the server requires.
    public func edit(
        fields: [String: String],
        files: [MultipartFile],
        options: RequestOptions = .init()
    ) async throws -> ImageResponse {
        var fields = fields
        fields["stream"] = "false"
        return try await client.upload(path: "images/edits", fields: fields, files: files, options: options)
    }

    /// Streams image editing events from a multipart upload. The caller consumes and cancels the stream.
    public func streamEdit(
        fields: [String: String],
        files: [MultipartFile],
        options: RequestOptions = .init()
    ) async throws -> OpenAIStream<JSONValue> {
        var fields = fields
        fields["stream"] = "true"
        return try await client.uploadStream(path: "images/edits", fields: fields, files: files, options: options)
    }

    /// Creates variations using an uploaded `image` multipart field.
    public func variations(
        fields: [String: String] = [:],
        files: [MultipartFile],
        options: RequestOptions = .init()
    ) async throws -> ImageResponse {
        try await client.upload(path: "images/variations", fields: fields, files: files, options: options)
    }
}
