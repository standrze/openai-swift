import Foundation

/// Polls indexing and video resources, preserving failed/cancelled terminal records for inspection.
extension APIResource {
    public func pollStatus(
        _ id: String, pollIntervalMilliseconds: Int = 0, options: RequestOptions = .init()
    ) async throws -> JSONValue {
        var scoped = mergedOptions(options)
        scoped.headers["X-Stainless-Poll-Helper"] = "true"
        if pollIntervalMilliseconds > 0 {
            scoped.headers["X-Stainless-Poll-Interval"] = String(pollIntervalMilliseconds)
        }
        let pollingOptions = scoped
        let active: Set<String> = path == "videos" ? ["queued", "in_progress"] : ["in_progress"]
        let terminal: Set<String> = path == "videos" ? ["completed", "failed"] : ["completed", "failed", "cancelled"]
        return try await RequestDeadline.run(until: pollingOptions.deadline) {
            var interval: TimeInterval?
            while true {
                try Task.checkCancellation()
                let result = try await client.withResponse { client in
                    try await client.send(
                        .get, path: path + "/" + OpenAIClient.pathComponent(id), options: pollingOptions
                    ) as JSONValue
                }
                let status = result.value["status"]?.stringValue ?? ""
                if terminal.contains(status) { return result.value }
                guard active.contains(status) else {
                    throw OpenAIClientError.invalidConfiguration("Unknown resource status during polling")
                }
                if interval == nil {
                    interval = Polling.interval(
                        milliseconds: pollIntervalMilliseconds, headers: result.response.headers)
                }
                try await Task.sleep(for: .seconds(interval!))
            }
        }
    }

    public func createAndPoll(
        _ body: JSONValue, pollIntervalMilliseconds: Int = 0, options: RequestOptions = .init()
    ) async throws -> JSONValue {
        let record = try await create(body, options: options)
        guard let id = record["id"]?.stringValue, !id.isEmpty else { throw OpenAIClientError.invalidResponse }
        return try await pollStatus(id, pollIntervalMilliseconds: pollIntervalMilliseconds, options: options)
    }
}

enum Polling {
    static func interval(milliseconds: Int, headers: [String: String]) -> TimeInterval {
        if milliseconds > 0 { return min(Double(milliseconds) / 1000, 9_223_372_036) }
        guard let raw = headers.first(where: { $0.key.lowercased() == "openai-poll-after-ms" })?.value,
            let value = Double(raw), value > 0,
            raw.dropFirst(raw.first == "+" ? 1 : 0).allSatisfy({ $0.isASCII && $0.isNumber })
        else { return 1 }
        return min(value / 1000, 8)
    }
}

/// A reusable in-memory upload description for multi-file workflows.
public struct FileUpload: Sendable {
    public var filename: String
    public var data: Data
    public var purpose: String
    public var contentType: String
    public var fields: [String: String]

    public init(
        filename: String, data: Data, purpose: String = "assistants",
        contentType: String = "application/octet-stream", fields: [String: String] = [:]
    ) {
        self.filename = filename
        self.data = data
        self.purpose = purpose
        self.contentType = contentType
        self.fields = fields
    }

    func upload(client: OpenAIClient, options: RequestOptions) async throws -> FileObject {
        try await FilesService(client: client).upload(
            filename: filename, data: data, purpose: purpose, contentType: contentType, fields: fields, options: options
        )
    }
}

extension VectorStoresService {
    public func uploadFile(
        _ file: FileUpload, storeID: String, options: RequestOptions = .init()
    ) async throws -> JSONValue {
        let uploaded = try await file.upload(client: stores.client, options: options)
        return try await files(storeID).create(["file_id": .string(uploaded.id)], options: options)
    }

    public func uploadFileAndPoll(
        _ file: FileUpload, storeID: String, pollIntervalMilliseconds: Int = 0, options: RequestOptions = .init()
    ) async throws -> JSONValue {
        let record = try await uploadFile(file, storeID: storeID, options: options)
        guard let id = record["id"]?.stringValue else { throw OpenAIClientError.invalidResponse }
        return try await files(storeID).pollStatus(
            id, pollIntervalMilliseconds: pollIntervalMilliseconds, options: options)
    }

    /// Uploads concurrently, then attaches the complete batch. Uploaded files remain application-owned on failure.
    public func uploadFileBatchAndPoll(
        _ uploads: [FileUpload], storeID: String, fileIDs: [String] = [], pollIntervalMilliseconds: Int = 0,
        options: RequestOptions = .init()
    ) async throws -> JSONValue {
        guard !uploads.isEmpty else {
            throw OpenAIClientError.invalidConfiguration("At least one file upload is required")
        }
        let uploaded = try await withThrowingTaskGroup(of: Result<(Int, String), any Error>.self) { group in
            for (index, file) in uploads.enumerated() {
                group.addTask {
                    do {
                        return .success((index, try await file.upload(client: stores.client, options: options).id))
                    } catch { return .failure(error) }
                }
            }
            var results: [(Int, String)] = []
            var failure: (any Error)?
            for try await result in group {
                switch result {
                case .success(let value): results.append(value)
                case .failure(let error): if failure == nil { failure = error }
                }
            }
            if let failure { throw failure }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return try await fileBatches(storeID).createAndPoll(
            ["file_ids": .array((fileIDs + uploaded).map(JSONValue.string))],
            pollIntervalMilliseconds: pollIntervalMilliseconds, options: options)
    }
}

extension VideosService {
    public func pollStatus(
        _ id: String, pollIntervalMilliseconds: Int = 0, options: RequestOptions = .init()
    ) async throws -> JSONValue {
        try await videos.pollStatus(id, pollIntervalMilliseconds: pollIntervalMilliseconds, options: options)
    }

    public func createAndPoll(
        fields: [String: String], files: [MultipartFile] = [], pollIntervalMilliseconds: Int = 0,
        options: RequestOptions = .init()
    ) async throws -> JSONValue {
        let video = try await create(fields: fields, files: files, options: options)
        guard let id = video["id"]?.stringValue else { throw OpenAIClientError.invalidResponse }
        return try await pollStatus(id, pollIntervalMilliseconds: pollIntervalMilliseconds, options: options)
    }
}
