import Foundation

/// Code-interpreter containers and their files. File content is returned as original bytes.
public struct ContainersService: Sendable {
    public let containers: APIResource

    public init(client: OpenAIClient) { containers = client.resource("containers") }

    public func create(_ body: JSONValue, options: RequestOptions = .init()) async throws -> JSONValue {
        try await containers.create(body, options: options)
    }

    public func retrieve(_ id: String, options: RequestOptions = .init()) async throws -> JSONValue {
        try await containers.retrieve(id, options: options)
    }

    public func list(options: RequestOptions = .init()) async throws -> Page<JSONValue> {
        try await containers.list(options: options)
    }

    public func delete(_ id: String, options: RequestOptions = .init()) async throws {
        _ = try await containers.client.download(
            .delete, path: containers.path + "/" + OpenAIClient.pathComponent(id), options: options)
    }

    public func files(_ containerID: String) -> APIResource { containers.nested(containerID, "files") }

    /// Uploads bytes in a multipart `file` field, or supply `file_id` through fields to copy an API file.
    public func uploadFile(
        _ containerID: String, fields: [String: String] = [:], files: [MultipartFile] = [],
        options: RequestOptions = .init()
    ) async throws -> JSONValue {
        try await containers.client.upload(
            path: self.files(containerID).path, fields: fields, files: files, options: options)
    }

    public func fileContent(
        _ fileID: String, containerID: String, options: RequestOptions = .init()
    ) async throws -> HTTPResponse {
        try await containers.client.download(
            .get, path: files(containerID).path + "/" + OpenAIClient.pathComponent(fileID) + "/content",
            options: options)
    }
}
