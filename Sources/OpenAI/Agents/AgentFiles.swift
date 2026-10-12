import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public struct AgentPreparedFiles: Sendable {
    public var files: [JSONValue] = []
    public var uploads: [FileObject] = []
    public init() {}
}

/// Successful uploads remain available for explicit cleanup when a later upload or staging operation fails.
public struct AgentFilePreparationError: Error, Sendable, CustomStringConvertible {
    public let prepared: AgentPreparedFiles
    public let cause: any Error
    public var description: String { "Cannot prepare beta agent files" }
}

public struct AgentStagedFile: Sendable {
    public let file: JSONValue
    public let upload: FileObject
    public let input: JSONValue
}

extension AgentsService {
    /// Maps clean absolute /workspace file destinations to application-controlled local files.
    /// Sources must remain stable during preparation. Upload ownership and cleanup belong to the caller.
    public func prepareFiles(
        _ files: [String: URL], options: RequestOptions = .init()
    ) async throws -> AgentPreparedFiles {
        try Task.checkCancellation()
        let selected = try AgentLocalFiles.preflight(files)
        let scoped = environments.mergedOptions(options)
        if selected.count > 1 {
            var request = URLRequest(url: sessions.client.configuration.baseURL)
            for (name, value) in sessions.client.configuration.headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
            for (name, value) in scoped.headers { request.setValue(value, forHTTPHeaderField: name) }
            for mutation in scoped.headerMutations { try mutation.apply(to: &request) }
            guard request.value(forHTTPHeaderField: "Idempotency-Key")?.isEmpty ?? true else {
                throw OpenAIClientError.invalidConfiguration("Multi-file preparation cannot reuse one Idempotency-Key")
            }
        }
        var prepared = AgentPreparedFiles()
        do {
            for item in selected {
                try Task.checkCancellation()
                let data = try item.read()
                let upload = try await FilesService(client: sessions.client).upload(
                    filename: item.source.lastPathComponent, data: data, purpose: "user_data", options: scoped)
                prepared.uploads.append(upload)
                prepared.files.append([
                    "type": "file_id", "file_id": .string(upload.id), "path": .string(item.destination),
                ])
            }
            return prepared
        } catch { throw AgentFilePreparationError(prepared: prepared, cause: error) }
    }

    /// Selects files once with explicit, relative POSIX glob patterns. Selected symlinks and symlink parents are skipped.
    public func prepareDirectory(
        _ directory: URL, destination: String, include: [String], options: RequestOptions = .init()
    ) async throws -> AgentPreparedFiles {
        let files = try AgentLocalFiles.select(directory: directory, destination: destination, include: include)
        return try await prepareFiles(files, options: options)
    }

    public func uploadEnvironmentFile(
        environmentID: String, source: URL, destination: String, options: RequestOptions = .init()
    ) async throws -> AgentStagedFile {
        guard !environmentID.isEmpty else { throw OpenAIClientError.invalidConfiguration("Environment ID is required") }
        let prepared = try await prepareFiles([destination: source], options: options)
        do {
            let file = try await environmentFiles(environmentID).create(prepared.files[0], options: options)
            return AgentStagedFile(file: file, upload: prepared.uploads[0], input: prepared.files[0])
        } catch { throw AgentFilePreparationError(prepared: prepared, cause: error) }
    }

    public func artifacts(for result: AgentTurnResult) -> AgentResultArtifacts {
        AgentResultArtifacts(service: self, sessionID: result.sessionID, turnID: result.turnID)
    }
}

/// Selects immutable artifacts belonging to exactly one result turn.
public struct AgentResultArtifacts: Sendable {
    let service: AgentsService
    let sessionID: String
    let turnID: String

    public func find(path: String, options: RequestOptions = .init()) async throws -> JSONValue {
        guard !sessionID.isEmpty, !turnID.isEmpty else {
            throw OpenAIClientError.invalidConfiguration("Result turn is required")
        }
        var found: JSONValue?
        for try await item in service.artifacts(sessionID).all(options: options) {
            guard item["turn_id"]?.stringValue == turnID, item["path"]?.stringValue == path else { continue }
            if let found, found["id"] != item["id"] {
                throw OpenAIClientError.invalidConfiguration("Multiple artifacts match the result turn and path")
            }
            found = item
        }
        guard let found else {
            throw OpenAIClientError.invalidConfiguration("No artifact matches the result turn and path")
        }
        return found
    }

    /// Streams content to the application's writer; a remote path is never used as a local filename.
    @discardableResult
    public func download(
        path: String, options: RequestOptions = .init(), write: @Sendable (Data) async throws -> Void
    ) async throws -> JSONValue {
        let artifact = try await find(path: path, options: options)
        guard let id = artifact["id"]?.stringValue else { throw OpenAIClientError.invalidResponse }
        let resource = service.artifacts(sessionID)
        let response = try await resource.client.streamBytes(
            path: resource.path + "/" + OpenAIClient.pathComponent(id) + "/content",
            options: resource.mergedOptions(options))
        defer { response.cancel() }
        do {
            for try await data in response.body {
                try Task.checkCancellation()
                try await write(data)
            }
        } catch { throw AgentArtifactDownloadError(artifact: artifact, cause: error) }
        return artifact
    }
}

public struct AgentArtifactDownloadError: Error, Sendable {
    public let artifact: JSONValue
    public let cause: any Error
}
