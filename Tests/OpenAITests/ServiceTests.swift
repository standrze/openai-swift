import Foundation
import XCTest

@testable import OpenAI

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

final class ServiceTests: XCTestCase {
    func testChatCreateAndStreamOverrideConflictingStreamOptions() async throws {
        let transport = RecordingTransport(
            send: [.response(jsonResponse(#"{"id":"chat_1","choices":[]}"#))],
            stream: [.response(streamResponse(text: "data: [DONE]\n\n"))]
        )
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)
        let request = ChatCompletionRequest(model: "local-model", messages: [.user("Hello")])

        _ = try await client.chat.completions.create(
            request, options: .init(extraBody: ["stream": true, "vendor_option": 7])
        )
        let stream = try await client.chat.completions.stream(
            request, options: .init(extraBody: ["stream": false])
        )
        stream.cancel()

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.path, "/proxy/v1/chat/completions")
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(try body(requests[0])["stream"], false)
        XCTAssertEqual(try body(requests[0])["vendor_option"], 7)
        XCTAssertEqual(try body(requests[0])["messages"]?[0]?["content"], "Hello")
        XCTAssertEqual(try body(requests[1])["stream"], true)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Accept"), "text/event-stream")
    }

    func testResponseCreateAndStreamOverrideConflictingStreamOptions() async throws {
        let transport = RecordingTransport(
            send: [.response(jsonResponse(#"{"id":"resp_1","output":[]}"#))],
            stream: [.response(streamResponse(text: "data: [DONE]\n\n"))]
        )
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)
        let request = ResponseRequest(model: "local-model", input: "Hello")

        _ = try await client.responses.create(request, options: .init(extraBody: ["stream": true]))
        let stream = try await client.responses.stream(request, options: .init(extraBody: ["stream": false]))
        stream.cancel()

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.path, "/proxy/v1/responses")
        XCTAssertEqual(try body(requests[0])["input"], "Hello")
        XCTAssertEqual(try body(requests[0])["stream"], false)
        XCTAssertEqual(try body(requests[1])["stream"], true)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Accept"), "text/event-stream")
    }

    func testResponseRetrieveStreamUsesQueryAndSupportsResumption() async throws {
        let transport = RecordingTransport(
            send: [.response(jsonResponse(#"{"id":"resp_1","output":[]}"#))],
            stream: [.response(streamResponse(text: "data: [DONE]\n\n"))]
        )
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)

        _ = try await client.responses.retrieve("resp_1", options: .init(query: ["stream": "true"]))
        let stream = try await client.responses.retrieveStream(
            "resp_1", startingAfter: 42, options: .init(query: ["stream": "false"])
        )
        stream.cancel()

        let requests = await transport.requests
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertEqual(try query(requests[0])["stream"], "false")
        XCTAssertEqual(requests[1].httpMethod, "GET")
        XCTAssertEqual(try query(requests[1])["stream"], "true")
        XCTAssertEqual(try query(requests[1])["starting_after"], "42")
        XCTAssertNil(requests[1].httpBody)
    }

    func testModelIdentifiersRemainSingleEncodedPathComponents() async throws {
        let transport = RecordingTransport(send: [.response(jsonResponse(#"{"id":"org/model:latest?x#fragment"}"#))])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)

        let model = try await client.models.retrieve("org/model:latest?x#fragment")

        let requests = await transport.requests
        XCTAssertEqual(model.id, "org/model:latest?x#fragment")
        XCTAssertEqual(
            requests.first?.url?.absoluteString,
            "https://example.test/proxy/v1/models/org%2Fmodel%3Alatest%3Fx%23fragment"
        )
        XCTAssertEqual(requests.first?.httpMethod, "GET")
        XCTAssertNil(requests.first?.httpBody)
    }

    func testEmbeddingsSendTokenBatchesAndEncodingFormat() async throws {
        let transport = RecordingTransport(send: [.response(jsonResponse(#"{"data":[]}"#))])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)
        let request = EmbeddingRequest(
            model: "local-embed", input: .tokenArrays([[1, 2], [3]]), dimensions: 32, encodingFormat: "base64"
        )

        _ = try await client.embeddings.create(request)

        let requests = await transport.requests
        let sent = try XCTUnwrap(requests.first)
        let value = try body(sent)
        XCTAssertEqual(sent.url?.path, "/proxy/v1/embeddings")
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(value["input"], [[1, 2], [3]])
        XCTAssertEqual(value["dimensions"], 32)
        XCTAssertEqual(value["encoding_format"], "base64")
    }

    func testFileUploadSendsMultipartPurposeAndOriginalBytes() async throws {
        let transport = RecordingTransport(send: [
            .response(jsonResponse(#"{"id":"file_1","filename":"requests.jsonl"}"#))
        ])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)
        let bytes = Data([0, 255, 1, 127])

        let file = try await client.files.upload(
            filename: "requests.jsonl", data: bytes, purpose: "batch", contentType: "application/jsonl",
            fields: ["purpose": "wrong", "expires_after[seconds]": "3600"]
        )

        let requests = await transport.requests
        let sent = try XCTUnwrap(requests.first)
        let data = try XCTUnwrap(sent.httpBody)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(file.id, "file_1")
        XCTAssertEqual(sent.url?.path, "/proxy/v1/files")
        XCTAssertTrue(
            sent.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        XCTAssertTrue(text.contains("name=\"purpose\"\r\n\r\nbatch\r\n"))
        XCTAssertFalse(text.contains("\r\nwrong\r\n"))
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"requests.jsonl\""))
        XCTAssertTrue(text.contains("Content-Type: application/jsonl"))
        XCTAssertNotNil(data.range(of: bytes))
    }

    func testAudioPreservesSpeechBytesAndSubtitleFormats() async throws {
        let audio = Data([0, 255, 82, 73, 70, 70])
        let subtitles = "1\n00:00:00,000 --> 00:00:01,000\nHello\n"
        let translated = "WEBVTT\n\n00:00.000 --> 00:01.000\nHello\n"
        let transport = RecordingTransport(send: [
            .response(HTTPResponse(data: audio, statusCode: 200, headers: ["Content-Type": "audio/wav"])),
            .response(HTTPResponse(data: Data(subtitles.utf8), statusCode: 200)),
            .response(HTTPResponse(data: Data(translated.utf8), statusCode: 200)),
        ])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)

        let speech = try await client.audio.speech(
            SpeechRequest(model: "local-tts", input: "Hello", voice: "voice", responseFormat: "wav")
        )
        let transcription = try await client.audio.transcribe(
            filename: "sample.wav", data: audio, model: "local-asr", fields: ["response_format": "srt"]
        )
        let translation = try await client.audio.translate(
            filename: "sample.wav", data: audio, model: "local-asr", fields: ["response_format": "vtt"]
        )

        XCTAssertEqual(speech.data, audio)
        XCTAssertEqual(speech.header("Content-Type"), "audio/wav")
        XCTAssertEqual(transcription.data, Data(subtitles.utf8))
        XCTAssertEqual(translation.data, Data(translated.utf8))
        let requests = await transport.requests
        XCTAssertEqual(requests[0].url?.path, "/proxy/v1/audio/speech")
        XCTAssertEqual(try body(requests[0])["response_format"], "wav")
        XCTAssertEqual(requests[1].url?.path, "/proxy/v1/audio/transcriptions")
        XCTAssertTrue(String(decoding: try XCTUnwrap(requests[1].httpBody), as: UTF8.self).contains("\r\nsrt\r\n"))
        XCTAssertEqual(requests[2].url?.path, "/proxy/v1/audio/translations")
        XCTAssertTrue(String(decoding: try XCTUnwrap(requests[2].httpBody), as: UTF8.self).contains("\r\nvtt\r\n"))
    }

    func testImageGenerationAndEditingForceNonstreamingResults() async throws {
        let transport = RecordingTransport(send: [
            .response(jsonResponse(#"{"data":[]}"#)),
            .response(jsonResponse(#"{"data":[]}"#)),
        ])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)

        _ = try await client.images.generate(
            ImageGenerationRequest(prompt: "A landscape", model: "local-image"),
            options: .init(extraBody: ["stream": true])
        )
        _ = try await client.images.edit(
            fields: ["prompt": "Add clouds", "stream": "true"],
            files: [
                MultipartFile(fieldName: "image", filename: "image.png", data: Data([1, 2]), contentType: "image/png")
            ]
        )

        let requests = await transport.requests
        XCTAssertEqual(requests[0].url?.path, "/proxy/v1/images/generations")
        XCTAssertEqual(try body(requests[0])["prompt"], "A landscape")
        XCTAssertEqual(try body(requests[0])["stream"], false)
        XCTAssertEqual(requests[1].url?.path, "/proxy/v1/images/edits")
        let multipart = String(decoding: try XCTUnwrap(requests[1].httpBody), as: UTF8.self)
        XCTAssertTrue(multipart.contains("name=\"stream\"\r\n\r\nfalse\r\n"))
        XCTAssertTrue(multipart.contains("name=\"image\"; filename=\"image.png\""))
        XCTAssertTrue(multipart.contains("\r\nAdd clouds\r\n"))
    }

    func testBatchCreationSendsFileEndpointAndCompletionWindow() async throws {
        let transport = RecordingTransport(send: [.response(jsonResponse(#"{"id":"batch_1","status":"validating"}"#))])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)
        var request = BatchRequest(inputFileID: "file_1", endpoint: "/v1/chat/completions")
        request.metadata = ["source": "test"]

        let batch = try await client.batches.create(request)

        let requests = await transport.requests
        let sent = try XCTUnwrap(requests.first)
        let value = try body(sent)
        XCTAssertEqual(batch.status, "validating")
        XCTAssertEqual(sent.url?.path, "/proxy/v1/batches")
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(value["input_file_id"], "file_1")
        XCTAssertEqual(value["endpoint"], "/v1/chat/completions")
        XCTAssertEqual(value["completion_window"], "24h")
        XCTAssertEqual(value["metadata"]?["source"], "test")
    }

    func testImageSSERequestsEnableStreamingForJSONAndMultipart() async throws {
        let event = "data: {\"type\":\"image_generation.partial_image\",\"b64_json\":\"aGVsbG8=\"}\n\n"
        let transport = RecordingTransport(stream: [
            .response(streamResponse(text: event)),
            .response(streamResponse(text: "data: [DONE]\n\n")),
            .response(streamResponse(text: "data: [DONE]\n\n")),
        ])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)

        let generated = try await client.images.stream(
            ImageGenerationRequest(prompt: "A landscape", model: "local-image"),
            options: .init(extraBody: ["stream": false])
        )
        var iterator = generated.makeAsyncIterator()
        let partial = try await iterator.next()
        XCTAssertEqual(partial?["type"], "image_generation.partial_image")
        XCTAssertEqual(partial?["b64_json"], "aGVsbG8=")
        generated.cancel()
        let flexible = try await client.images.stream(
            JSONValue.object(["prompt": "A lake"]), options: .init(extraBody: ["stream": false])
        )
        flexible.cancel()
        let edited = try await client.images.streamEdit(
            fields: ["prompt": "Add clouds", "stream": "false"],
            files: [MultipartFile(fieldName: "image", filename: "image.png", data: Data([1, 2]))]
        )
        edited.cancel()

        let requests = await transport.requests
        XCTAssertEqual(try body(requests[0])["stream"], true)
        XCTAssertEqual(try body(requests[1])["stream"], true)
        XCTAssertEqual(requests[2].url?.path, "/proxy/v1/images/edits")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertTrue(requests[2].value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data;") == true)
        let multipart = String(decoding: try XCTUnwrap(requests[2].httpBody), as: UTF8.self)
        XCTAssertTrue(multipart.contains("name=\"stream\"\r\n\r\ntrue\r\n"))
        XCTAssertTrue(multipart.contains("name=\"image\"; filename=\"image.png\""))
    }

    func testAudioSSEAndRepeatedTimestampFieldsUseTheirRequiredWireFormats() async throws {
        let transport = RecordingTransport(
            send: [.response(jsonResponse(#"{"text":"Hello","words":[],"segments":[]}"#))],
            stream: [
                .response(streamResponse(text: "data: [DONE]\n\n")),
                .response(streamResponse(text: "data: {\"type\":\"transcript.text.delta\",\"delta\":\"Hello\"}\n\n")),
            ]
        )
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)
        let timestamps = [
            MultipartField(name: "timestamp_granularities[]", value: "word"),
            MultipartField(name: "timestamp_granularities[]", value: "segment"),
        ]

        let speech = try await client.audio.speechStream(
            SpeechRequest(model: "local-tts", input: "Hello", voice: "voice"),
            options: .init(extraBody: ["stream_format": "audio"])
        )
        speech.cancel()
        let transcription = try await client.audio.transcribeStream(
            filename: "sample.wav", data: Data([1, 2]), model: "local-asr",
            fields: timestamps + [MultipartField(name: "stream", value: "false")]
        )
        var iterator = transcription.makeAsyncIterator()
        let delta = try await iterator.next()
        XCTAssertEqual(delta?["delta"], "Hello")
        transcription.cancel()
        _ = try await client.audio.transcribeJSON(
            filename: "sample.wav", data: Data([1, 2]), model: "local-asr",
            fields: timestamps + [MultipartField(name: "response_format", value: "verbose_json")]
        )

        let requests = await transport.requests
        XCTAssertEqual(requests[0].url?.path, "/proxy/v1/audio/speech")
        XCTAssertEqual(try body(requests[0])["stream_format"], "sse")
        XCTAssertEqual(requests[1].url?.path, "/proxy/v1/audio/transcriptions")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Accept"), "text/event-stream")
        let streamingBody = String(decoding: try XCTUnwrap(requests[1].httpBody), as: UTF8.self)
        XCTAssertTrue(streamingBody.contains("name=\"stream\"\r\n\r\ntrue\r\n"))
        XCTAssertFalse(streamingBody.contains("name=\"stream\"\r\n\r\nfalse\r\n"))
        let completedBody = String(decoding: try XCTUnwrap(requests[2].httpBody), as: UTF8.self)
        XCTAssertEqual(completedBody.components(separatedBy: "name=\"timestamp_granularities[]\"").count - 1, 2)
        XCTAssertTrue(completedBody.contains("\r\nword\r\n"))
        XCTAssertTrue(completedBody.contains("\r\nsegment\r\n"))
        XCTAssertTrue(completedBody.contains("\r\nverbose_json\r\n"))
    }

    private func body(_ request: URLRequest) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(request.httpBody))
    }

    private func query(_ request: URLRequest) throws -> [String: String] {
        let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
}
