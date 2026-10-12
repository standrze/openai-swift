import Foundation

/// Common speech synthesis parameters. The returned audio format defaults to the server's choice.
public struct SpeechRequest: Codable, Sendable {
    public var model: String
    public var input: String
    public var voice: String
    public var instructions: String?
    public var responseFormat: String?
    public var speed: Double?

    public init(model: String, input: String, voice: String, responseFormat: String? = nil) {
        self.model = model
        self.input = input
        self.voice = voice
        self.responseFormat = responseFormat
    }

    enum CodingKeys: String, CodingKey {
        case model, input, voice, instructions, speed
        case responseFormat = "response_format"
    }
}

/// JSON transcription or translation output, including optional verbose timing information.
public struct AudioTranscription: Codable, Sendable, Equatable {
    public let text: String
    public let language: String?
    public let duration: Double?
    public let segments: [JSONValue]?
    public let words: [JSONValue]?
    public let usage: JSONValue?
    public let logprobs: [JSONValue]?
}

/// Synthesizes speech and uploads audio for transcription or translation.
public struct AudioService: Sendable {
    private let client: OpenAIClient

    public init(client: OpenAIClient) {
        self.client = client
    }

    /// Creates a custom voice from consent metadata and an `audio_sample` multipart file.
    public func createVoice(
        fields: [String: String], files: [MultipartFile], options: RequestOptions = .init()
    ) async throws -> JSONValue {
        try await client.upload(path: "audio/voices", fields: fields, files: files, options: options)
    }

    /// Returns audio bytes and their content type. No JSON decoding is performed.
    public func speech(_ request: SpeechRequest, options: RequestOptions = .init()) async throws -> HTTPResponse {
        try await client.download(.post, path: "audio/speech", body: request, options: options)
    }

    /// Sends flexible speech parameters, including provider-defined voices and formats.
    public func speech(_ request: JSONValue, options: RequestOptions = .init()) async throws -> HTTPResponse {
        try await client.download(.post, path: "audio/speech", body: request, options: options)
    }

    /// Requests speech SSE events using `stream_format: sse`. Events can contain base64 audio fragments.
    /// This differs from raw audio byte streaming; consume event payloads and decode audio in the application.
    public func speechStream(
        _ request: SpeechRequest,
        options: RequestOptions = .init()
    ) async throws -> OpenAIStream<JSONValue> {
        var options = options
        options.extraBody["stream_format"] = .string("sse")
        return try await client.stream(path: "audio/speech", body: request, options: options)
    }

    /// Requests speech SSE events with flexible JSON parameters, including provider-defined voice objects.
    public func speechStream(
        _ request: JSONValue,
        options: RequestOptions = .init()
    ) async throws -> OpenAIStream<JSONValue> {
        var options = options
        options.extraBody["stream_format"] = .string("sse")
        return try await client.stream(path: "audio/speech", body: request, options: options)
    }

    /// Returns the server's original transcription payload, supporting JSON, text, SRT, and VTT.
    public func transcribe(
        filename: String,
        data: Data,
        model: String,
        contentType: String = "application/octet-stream",
        fields: [String: String] = [:],
        options: RequestOptions = .init()
    ) async throws -> HTTPResponse {
        var fields = fields
        fields["model"] = model
        let file = MultipartFile(fieldName: "file", filename: filename, data: data, contentType: contentType)
        return try await client.uploadResponse(
            path: "audio/transcriptions", fields: fields, files: [file], options: options
        )
    }

    /// Returns a typed JSON transcription. Set `response_format` to `verbose_json` for timing information.
    public func transcribeJSON(
        filename: String,
        data: Data,
        model: String,
        contentType: String = "application/octet-stream",
        fields: [String: String] = [:],
        options: RequestOptions = .init()
    ) async throws -> AudioTranscription {
        var fields = fields
        fields["model"] = model
        if fields["response_format"] == nil { fields["response_format"] = "json" }
        let file = MultipartFile(fieldName: "file", filename: filename, data: data, contentType: contentType)
        return try await client.upload(path: "audio/transcriptions", fields: fields, files: [file], options: options)
    }

    /// Transcribes audio with repeated multipart fields, such as both `timestamp_granularities[]` values.
    public func transcribe(
        filename: String,
        data: Data,
        model: String,
        contentType: String = "application/octet-stream",
        fields: [MultipartField],
        options: RequestOptions = .init()
    ) async throws -> HTTPResponse {
        var fields = fields.filter { $0.name != "model" }
        fields.append(MultipartField(name: "model", value: model))
        let file = MultipartFile(fieldName: "file", filename: filename, data: data, contentType: contentType)
        return try await client.uploadResponse(
            path: "audio/transcriptions", fields: fields, files: [file], options: options
        )
    }

    /// Returns JSON transcription output while preserving repeated multipart request fields.
    public func transcribeJSON(
        filename: String,
        data: Data,
        model: String,
        contentType: String = "application/octet-stream",
        fields: [MultipartField],
        options: RequestOptions = .init()
    ) async throws -> AudioTranscription {
        var fields = fields.filter { $0.name != "model" }
        fields.append(MultipartField(name: "model", value: model))
        if !fields.contains(where: { $0.name == "response_format" }) {
            fields.append(MultipartField(name: "response_format", value: "json"))
        }
        let file = MultipartFile(fieldName: "file", filename: filename, data: data, contentType: contentType)
        return try await client.upload(path: "audio/transcriptions", fields: fields, files: [file], options: options)
    }

    /// Streams transcription events. The model must support streaming; this sets multipart `stream` to `true`.
    public func transcribeStream(
        filename: String,
        data: Data,
        model: String,
        contentType: String = "application/octet-stream",
        fields: [String: String] = [:],
        options: RequestOptions = .init()
    ) async throws -> OpenAIStream<JSONValue> {
        var fields = fields
        fields["model"] = model
        fields["stream"] = "true"
        let file = MultipartFile(fieldName: "file", filename: filename, data: data, contentType: contentType)
        return try await client.uploadStream(
            path: "audio/transcriptions", fields: fields, files: [file], options: options
        )
    }

    /// Streams transcription events with repeated multipart fields, preserving their order.
    public func transcribeStream(
        filename: String,
        data: Data,
        model: String,
        contentType: String = "application/octet-stream",
        fields: [MultipartField],
        options: RequestOptions = .init()
    ) async throws -> OpenAIStream<JSONValue> {
        var fields = fields.filter { $0.name != "model" && $0.name != "stream" }
        fields.append(MultipartField(name: "model", value: model))
        fields.append(MultipartField(name: "stream", value: "true"))
        let file = MultipartFile(fieldName: "file", filename: filename, data: data, contentType: contentType)
        return try await client.uploadStream(
            path: "audio/transcriptions", fields: fields, files: [file], options: options
        )
    }

    /// Translates audio into English, retaining the requested JSON or subtitle representation.
    public func translate(
        filename: String,
        data: Data,
        model: String,
        contentType: String = "application/octet-stream",
        fields: [String: String] = [:],
        options: RequestOptions = .init()
    ) async throws -> HTTPResponse {
        var fields = fields
        fields["model"] = model
        let file = MultipartFile(fieldName: "file", filename: filename, data: data, contentType: contentType)
        return try await client.uploadResponse(
            path: "audio/translations", fields: fields, files: [file], options: options)
    }

    /// Returns a typed JSON English translation.
    public func translateJSON(
        filename: String,
        data: Data,
        model: String,
        contentType: String = "application/octet-stream",
        fields: [String: String] = [:],
        options: RequestOptions = .init()
    ) async throws -> AudioTranscription {
        var fields = fields
        fields["model"] = model
        if fields["response_format"] == nil { fields["response_format"] = "json" }
        let file = MultipartFile(fieldName: "file", filename: filename, data: data, contentType: contentType)
        return try await client.upload(path: "audio/translations", fields: fields, files: [file], options: options)
    }
}
