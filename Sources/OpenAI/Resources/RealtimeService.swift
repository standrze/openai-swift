import Foundation

/// Realtime REST setup and call control. WebRTC media remains owned by the application.
public struct RealtimeService: Sendable {
    let client: OpenAIClient
    public let sessions: APIResource
    public let transcriptionSessions: APIResource
    public let clientSecrets: APIResource
    public let calls: APIResource
    public let translationClientSecrets: APIResource

    public init(client: OpenAIClient) {
        self.client = client
        sessions = client.resource("realtime/sessions")
        transcriptionSessions = client.resource("realtime/transcription_sessions")
        clientSecrets = client.resource("realtime/client_secrets")
        calls = client.resource("realtime/calls")
        translationClientSecrets = client.resource("realtime/translations/client_secrets")
    }

    /// Creates a WebRTC call from an SDP offer and optional session configuration.
    /// The result contains SDP answer bytes and the call location in HTTP headers.
    public func createCall(
        sdp: String, session: JSONValue? = nil, options: RequestOptions = .init()
    ) async throws -> HTTPResponse {
        var fields = [MultipartField(name: "sdp", value: sdp, contentType: "application/sdp")]
        if let session {
            let json = String(decoding: try JSONEncoder().encode(session), as: UTF8.self)
            fields.append(MultipartField(name: "session", value: json, contentType: "application/json"))
        }
        return try await client.uploadResponse(path: "realtime/calls", fields: fields, files: [], options: options)
    }

    /// Sends a raw SDP offer for compatible servers that accept `application/sdp` instead of multipart.
    public func createCallWithRawSDP(_ sdp: String, options: RequestOptions = .init()) async throws -> HTTPResponse {
        try await client.request(
            .post, path: "realtime/calls", data: Data(sdp.utf8), contentType: "application/sdp", options: options)
    }

    public func acceptCall(_ id: String, session: JSONValue, options: RequestOptions = .init()) async throws {
        _ = try await client.download(
            .post, path: callPath(id, "accept"), body: session, options: options)
    }

    public func hangupCall(_ id: String, options: RequestOptions = .init()) async throws {
        _ = try await client.download(.post, path: callPath(id, "hangup"), options: options)
    }

    public func referCall(_ id: String, targetURI: String, options: RequestOptions = .init()) async throws {
        _ = try await client.download(
            .post, path: callPath(id, "refer"), body: JSONValue.object(["target_uri": .string(targetURI)]),
            options: options)
    }

    public func rejectCall(_ id: String, statusCode: Int? = nil, options: RequestOptions = .init()) async throws {
        var body: [String: JSONValue] = [:]
        if let statusCode { body["status_code"] = .integer(Int64(statusCode)) }
        _ = try await client.download(
            .post, path: callPath(id, "reject"), body: JSONValue.object(body), options: options)
    }

    private func callPath(_ id: String, _ action: String) -> String {
        "realtime/calls/" + OpenAIClient.pathComponent(id) + "/" + action
    }
}
