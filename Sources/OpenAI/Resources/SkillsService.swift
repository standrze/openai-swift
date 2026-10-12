import Foundation

/// Uploads skill bundles and versions, and downloads their original archives.
public struct SkillsService: Sendable {
    public let skills: APIResource

    public init(client: OpenAIClient) { skills = client.resource("skills") }

    /// Creates a skill from multipart `files` parts, preserving filenames and bytes.
    public func create(
        fields: [String: String] = [:], files: [MultipartFile], options: RequestOptions = .init()
    ) async throws -> JSONValue {
        try await skills.client.upload(path: skills.path, fields: fields, files: files, options: options)
    }

    public func retrieve(_ id: String, options: RequestOptions = .init()) async throws -> JSONValue {
        try await skills.retrieve(id, options: options)
    }

    public func update(_ id: String, body: JSONValue, options: RequestOptions = .init()) async throws -> JSONValue {
        try await skills.update(id, body: body, options: options)
    }

    public func list(options: RequestOptions = .init()) async throws -> Page<JSONValue> {
        try await skills.list(options: options)
    }

    public func delete(_ id: String, options: RequestOptions = .init()) async throws -> JSONValue {
        try await skills.delete(id, options: options)
    }

    public func content(_ id: String, options: RequestOptions = .init()) async throws -> HTTPResponse {
        try await skills.client.download(
            .get, path: skills.path + "/" + OpenAIClient.pathComponent(id) + "/content", options: options)
    }

    public func versions(_ skillID: String) -> APIResource { skills.nested(skillID, "versions") }

    /// Creates a version from uploaded files. Version metadata is returned unchanged as JSON.
    public func createVersion(
        _ skillID: String, fields: [String: String] = [:], files: [MultipartFile], options: RequestOptions = .init()
    ) async throws -> JSONValue {
        try await skills.client.upload(path: versions(skillID).path, fields: fields, files: files, options: options)
    }

    public func versionContent(
        _ version: String, skillID: String, options: RequestOptions = .init()
    ) async throws -> HTTPResponse {
        try await skills.client.download(
            .get, path: versions(skillID).path + "/" + OpenAIClient.pathComponent(version) + "/content",
            options: options)
    }
}
