import Foundation

/// Metadata for an uploaded file. Timestamps use Unix seconds.
public struct FileObject: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let object: String?
    public let bytes: Int64?
    public let createdAt: Int64?
    public let expiresAt: Int64?
    public let filename: String
    public let purpose: String?
    public let status: String?
    public let statusDetails: String?

    enum CodingKeys: String, CodingKey {
        case id, object, bytes, filename, purpose, status
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case statusDetails = "status_details"
    }
}

/// Uploads, lists, downloads, and deletes API files.
public struct FilesService: Sendable {
    private let client: OpenAIClient

    public init(client: OpenAIClient) {
        self.client = client
    }

    /// Uploads in-memory file bytes. Additional multipart parameters may be supplied in `fields`.
    public func upload(
        filename: String,
        data: Data,
        purpose: String,
        contentType: String = "application/octet-stream",
        fields: [String: String] = [:],
        options: RequestOptions = .init()
    ) async throws -> FileObject {
        var fields = fields
        fields["purpose"] = purpose
        let file = MultipartFile(fieldName: "file", filename: filename, data: data, contentType: contentType)
        return try await client.upload(path: "files", fields: fields, files: [file], options: options)
    }

    /// Lists files. Filters and pagination parameters are supplied through `options.query`.
    public func list(options: RequestOptions = .init()) async throws -> Page<FileObject> {
        try await client.send(.get, path: "files", options: options)
    }

    public func retrieve(_ id: String, options: RequestOptions = .init()) async throws -> FileObject {
        try await client.send(.get, path: "files/\(OpenAIClient.pathComponent(id))", options: options)
    }

    public func delete(_ id: String, options: RequestOptions = .init()) async throws -> DeletedObject {
        try await client.send(.delete, path: "files/\(OpenAIClient.pathComponent(id))", options: options)
    }

    /// Downloads original bytes with response headers and status available to the caller.
    public func content(_ id: String, options: RequestOptions = .init()) async throws -> HTTPResponse {
        try await client.download(.get, path: "files/\(OpenAIClient.pathComponent(id))/content", options: options)
    }
}
