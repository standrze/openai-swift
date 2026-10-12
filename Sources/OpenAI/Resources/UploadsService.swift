import Foundation

/// The multipart upload lifecycle. Uploaded part identifiers are supplied explicitly when completing an upload.
public struct UploadsService: Sendable {
    public let uploads: APIResource

    public init(client: OpenAIClient) { uploads = client.resource("uploads") }

    public func create(_ body: JSONValue, options: RequestOptions = .init()) async throws -> JSONValue {
        try await uploads.create(body, options: options)
    }

    public func create(
        filename: String, bytes: Int64, mimeType: String, purpose: String, options: RequestOptions = .init()
    ) async throws -> JSONValue {
        try await create(
            [
                "filename": .string(filename), "bytes": .integer(bytes),
                "mime_type": .string(mimeType), "purpose": .string(purpose),
            ], options: options)
    }

    public func parts(_ uploadID: String) -> APIResource { uploads.nested(uploadID, "parts") }

    /// Uploads one binary part in the required multipart `data` field.
    public func addPart(
        _ uploadID: String, data: Data, filename: String = "part", options: RequestOptions = .init()
    ) async throws -> JSONValue {
        try await uploads.client.upload(
            path: parts(uploadID).path, fields: [:],
            files: [MultipartFile(fieldName: "data", filename: filename, data: data)], options: options)
    }

    public func complete(
        _ uploadID: String, partIDs: [String], md5: String? = nil, options: RequestOptions = .init()
    ) async throws -> JSONValue {
        var body: [String: JSONValue] = ["part_ids": .array(partIDs.map(JSONValue.string))]
        if let md5 { body["md5"] = .string(md5) }
        return try await uploads.action(uploadID, "complete", body: .object(body), options: options)
    }

    public func cancel(_ uploadID: String, options: RequestOptions = .init()) async throws -> JSONValue {
        try await uploads.action(uploadID, "cancel", options: options)
    }
}
