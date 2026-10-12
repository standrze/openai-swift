import Foundation

/// Creates, edits, extends, and downloads videos using schema-flexible metadata.
public struct VideosService: Sendable {
    public let videos: APIResource

    public init(client: OpenAIClient) { videos = client.resource("videos") }

    /// Creates a video with form parameters and an optional `input_reference` file.
    public func create(
        fields: [String: String], files: [MultipartFile] = [], options: RequestOptions = .init()
    ) async throws -> JSONValue {
        try await videos.client.upload(path: "videos", fields: fields, files: files, options: options)
    }

    /// Creates a video referencing an existing image by file ID or URL, using nested multipart field names.
    public func create(
        prompt: String, model: String? = nil, seconds: String? = nil, size: String? = nil,
        referenceFileID: String? = nil, referenceImageURL: String? = nil, options: RequestOptions = .init()
    ) async throws -> JSONValue {
        var fields = ["prompt": prompt]
        if let model { fields["model"] = model }
        if let seconds { fields["seconds"] = seconds }
        if let size { fields["size"] = size }
        if let referenceFileID { fields["input_reference[file_id]"] = referenceFileID }
        if let referenceImageURL { fields["input_reference[image_url]"] = referenceImageURL }
        return try await create(fields: fields, options: options)
    }

    public func retrieve(_ id: String, options: RequestOptions = .init()) async throws -> JSONValue {
        try await videos.retrieve(id, options: options)
    }

    public func list(options: RequestOptions = .init()) async throws -> Page<JSONValue> {
        try await videos.list(options: options)
    }

    public func delete(_ id: String, options: RequestOptions = .init()) async throws -> JSONValue {
        try await videos.delete(id, options: options)
    }

    /// Downloads video or a requested variant such as `thumbnail` or `spritesheet`.
    public func content(
        _ id: String, variant: String? = nil, options: RequestOptions = .init()
    ) async throws -> HTTPResponse {
        var options = options
        if let variant { options.query["variant"] = variant }
        return try await videos.client.download(
            .get, path: "videos/" + OpenAIClient.pathComponent(id) + "/content", options: options)
    }

    public func createCharacter(
        name: String, filename: String, data: Data, contentType: String = "video/mp4", options: RequestOptions = .init()
    ) async throws -> JSONValue {
        try await videos.client.upload(
            path: "videos/characters", fields: ["name": name],
            files: [MultipartFile(fieldName: "video", filename: filename, data: data, contentType: contentType)],
            options: options)
    }

    public func retrieveCharacter(_ id: String, options: RequestOptions = .init()) async throws -> JSONValue {
        try await videos.client.send(
            .get, path: "videos/characters/" + OpenAIClient.pathComponent(id), options: options)
    }

    public func edit(
        fields: [String: String], files: [MultipartFile] = [], options: RequestOptions = .init()
    ) async throws -> JSONValue {
        try await videos.client.upload(path: "videos/edits", fields: fields, files: files, options: options)
    }

    /// Edits an existing completed video using the multipart `video[id]` reference field.
    public func edit(_ videoID: String, prompt: String, options: RequestOptions = .init()) async throws -> JSONValue {
        try await edit(fields: ["prompt": prompt, "video[id]": videoID], options: options)
    }

    public func extend(
        fields: [String: String], files: [MultipartFile] = [], options: RequestOptions = .init()
    ) async throws -> JSONValue {
        try await videos.client.upload(path: "videos/extensions", fields: fields, files: files, options: options)
    }

    /// Extends an existing completed video. Seconds is the server's string duration value.
    public func extend(
        _ videoID: String, prompt: String, seconds: String, options: RequestOptions = .init()
    ) async throws -> JSONValue {
        try await extend(fields: ["prompt": prompt, "seconds": seconds, "video[id]": videoID], options: options)
    }

    public func remix(_ id: String, prompt: String, options: RequestOptions = .init()) async throws -> JSONValue {
        try await videos.action(id, "remix", body: ["prompt": .string(prompt)], options: options)
    }
}
