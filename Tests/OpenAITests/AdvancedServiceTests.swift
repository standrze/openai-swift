import Foundation
import XCTest

@testable import OpenAI

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

final class AdvancedServiceTests: XCTestCase {
    func testResourceDefaultsPropagateAndMergeCaseInsensitiveHeaders() async throws {
        let transport = RecordingTransport(send: [.response(jsonResponse("{}"))])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)
        let resource = APIResource(
            client: client, path: "agents",
            defaultOptions: .init(
                headers: ["OpenAI-Beta": "agents=v1", "X-Trace": "inherited"],
                query: ["limit": "2"], extraBody: ["default": true],
                timeout: 17, maxRetries: 0, queryItems: [.init(name: "include[]", value: "one")]))

        _ = try await resource.nested("agent/a", "events").create(
            ["event": "start"],
            options: .init(
                headers: ["openai-beta": "agents=v2"], query: ["limit": "3"], extraBody: ["default": false],
                queryItems: [.init(name: "include[]", value: "two")]))

        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "OpenAI-Beta"), "agents=v2")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Trace"), "inherited")
        XCTAssertEqual(request.timeoutInterval, 17)
        XCTAssertEqual(try body(request)["default"], false)
        let query =
            try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)).queryItems ?? []
        XCTAssertEqual(query.filter { $0.name == "include[]" }.compactMap(\.value), ["one", "two"])
        XCTAssertEqual(query.first { $0.name == "limit" }?.value, "3")
        XCTAssertTrue(request.url?.absoluteString.contains("agents/agent%2Fa/events") == true)
    }

    func testBetaResourcesApplyTheirRequiredVersions() async throws {
        let transport = RecordingTransport(send: [
            .response(jsonResponse(#"{"id":"resp_1","output":[]}"#)),
            .response(jsonResponse("{}")), .response(jsonResponse("{}")), .response(jsonResponse("{}")),
        ])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)

        _ = try await client.beta.responses.create(.init(model: "local", input: "Hello"))
        _ = try await client.beta.assistants.create(["model": "local"])
        _ = try await client.beta.agents.environmentFiles("env/a").create(["file_id": "file_1"])
        _ = try await client.beta.chatKit.sessions.create(["user": "user_1"])

        let requests = await transport.requests
        XCTAssertTrue(requests[0].url?.absoluteString.contains("beta=true") == true)
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "OpenAI-Beta"))
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "OpenAI-Beta"), "assistants=v2")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "OpenAI-Beta"), "agents=v1")
        XCTAssertEqual(requests[3].value(forHTTPHeaderField: "OpenAI-Beta"), "chatkit_beta=v1")
    }

    func testThreadRunSubmissionAndStreamingUseToolOutputRoute() async throws {
        let transport = RecordingTransport(
            send: [.response(jsonResponse("{}")), .response(jsonResponse("{}"))],
            stream: [.response(streamResponse(text: "data: [DONE]\n\n"))])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)
        let outputs: [JSONValue] = [["tool_call_id": "call_1", "output": "Sunny"]]

        _ = try await client.threads.createAndRun(["assistant_id": "asst_1"])
        _ = try await client.threads.submitToolOutputs(
            "run/a", threadID: "thread/a", outputs: outputs, options: .init(extraBody: ["stream": true]))
        let stream = try await client.threads.submitToolOutputsStream(
            "run/a", threadID: "thread/a", outputs: outputs, options: .init(extraBody: ["stream": false]))
        stream.cancel()

        let requests = await transport.requests
        XCTAssertEqual(requests[0].url?.path, "/proxy/v1/threads/runs")
        XCTAssertTrue(
            requests[1].url?.absoluteString.hasSuffix("threads/thread%2Fa/runs/run%2Fa/submit_tool_outputs") == true)
        XCTAssertEqual(try body(requests[1])["tool_outputs"], .array(outputs))
        XCTAssertEqual(try body(requests[1])["stream"], false)
        XCTAssertEqual(try body(requests[2])["stream"], true)
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "OpenAI-Beta"), "assistants=v2")
    }

    func testUploadPartsUseBinaryDataAndCompletionPreservesOrder() async throws {
        let transport = RecordingTransport(send: Array(repeating: .response(jsonResponse("{}")), count: 3))
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)

        _ = try await client.uploads.create(
            filename: "file.jsonl", bytes: 4, mimeType: "application/jsonl", purpose: "batch")
        _ = try await client.uploads.addPart("upload/a", data: Data([0, 255, 1, 2]))
        _ = try await client.uploads.complete("upload/a", partIDs: ["part_2", "part_1"], md5: "checksum")

        let requests = await transport.requests
        XCTAssertEqual(try body(requests[0])["mime_type"], "application/jsonl")
        XCTAssertEqual(try body(requests[0])["bytes"], 4)
        XCTAssertTrue(requests[1].url?.absoluteString.hasSuffix("uploads/upload%2Fa/parts") == true)
        XCTAssertTrue(try multipart(requests[1]).contains("name=\"data\"; filename=\"part\""))
        XCTAssertNotNil(try XCTUnwrap(requests[1].httpBody).range(of: Data([0, 255, 1, 2])))
        XCTAssertEqual(try body(requests[2])["part_ids"], ["part_2", "part_1"])
        XCTAssertEqual(try body(requests[2])["md5"], "checksum")
    }

    func testVectorStoreAndCheckpointSpecialRoutes() async throws {
        let transport = RecordingTransport(send: [
            .response(jsonResponse("{}")), .response(jsonResponse("{}")), .response(jsonResponse(#"{"data":[]}"#)),
            .response(jsonResponse("{}")), .response(jsonResponse("{}")), .response(jsonResponse("{}")),
        ])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)

        _ = try await client.vectorStores.fileContent("file/a", storeID: "store/a")
        _ = try await client.vectorStores.cancelFileBatch("batch/a", storeID: "store/a")
        _ = try await client.vectorStores.listBatchFiles("batch/a", storeID: "store/a")
        _ = try await client.fineTuning.createPermission(
            checkpointID: "checkpoint/a", body: ["project_ids": ["proj_1"]])
        _ = try await client.fineTuning.deletePermission("permission/a", checkpointID: "checkpoint/a")
        _ = try await client.fineTuning.validateGrader(["grader": ["type": "string_check"]])

        let requests = await transport.requests
        let suffixes = [
            "vector_stores/store%2Fa/files/file%2Fa/content", "vector_stores/store%2Fa/file_batches/batch%2Fa/cancel",
            "vector_stores/store%2Fa/file_batches/batch%2Fa/files",
            "fine_tuning/checkpoints/checkpoint%2Fa/permissions",
            "fine_tuning/checkpoints/checkpoint%2Fa/permissions/permission%2Fa", "fine_tuning/alpha/graders/validate",
        ]
        for (request, suffix) in zip(requests, suffixes) {
            XCTAssertTrue(request.url?.absoluteString.hasSuffix(suffix) == true)
        }
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "GET", "POST", "DELETE", "POST"])
        XCTAssertEqual(try body(requests[3])["project_ids"], ["proj_1"])
    }

    func testSkillBundlesAndVersionContentUseMultipartAndBinary() async throws {
        let bytes = Data([0, 255, 3])
        let transport = RecordingTransport(send: [
            .response(jsonResponse("{}")), .response(jsonResponse("{}")),
            .response(HTTPResponse(data: bytes, statusCode: 200)),
        ])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)
        let file = MultipartFile(fieldName: "files", filename: "skill.zip", data: bytes, contentType: "application/zip")

        _ = try await client.skills.create(files: [file])
        _ = try await client.skills.createVersion("skill/a", files: [file])
        let content = try await client.skills.versionContent("2", skillID: "skill/a")

        let requests = await transport.requests
        XCTAssertEqual(content.data, bytes)
        XCTAssertTrue(try multipart(requests[0]).contains("filename=\"skill.zip\""))
        XCTAssertTrue(requests[1].url?.absoluteString.hasSuffix("skills/skill%2Fa/versions") == true)
        XCTAssertTrue(requests[2].url?.absoluteString.hasSuffix("skills/skill%2Fa/versions/2/content") == true)
        XCTAssertEqual(requests[2].httpMethod, "GET")
    }

    func testVideoMultipartActionsAndContentVariant() async throws {
        let transport = RecordingTransport(send: [
            .response(jsonResponse("{}")), .response(jsonResponse("{}")), .response(jsonResponse("{}")),
            .response(jsonResponse("{}")), .response(HTTPResponse(data: Data([1, 2]), statusCode: 200)),
        ])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)

        _ = try await client.videos.create(prompt: "A landscape", model: "video-model", referenceFileID: "file_1")
        _ = try await client.videos.edit("video_1", prompt: "Add clouds")
        _ = try await client.videos.extend("video_1", prompt: "Continue", seconds: "8")
        _ = try await client.videos.remix("video/a", prompt: "At night")
        let content = try await client.videos.content("video/a", variant: "thumbnail")

        let requests = await transport.requests
        XCTAssertTrue(try multipart(requests[0]).contains("\r\nA landscape\r\n"))
        XCTAssertTrue(try multipart(requests[0]).contains("name=\"input_reference[file_id]\"\r\n\r\nfile_1\r\n"))
        XCTAssertEqual(requests[1].url?.path, "/proxy/v1/videos/edits")
        XCTAssertTrue(try multipart(requests[1]).contains("name=\"video[id]\"\r\n\r\nvideo_1\r\n"))
        XCTAssertEqual(requests[2].url?.path, "/proxy/v1/videos/extensions")
        XCTAssertEqual(try body(requests[3])["prompt"], "At night")
        XCTAssertTrue(requests[4].url?.absoluteString.hasSuffix("videos/video%2Fa/content?variant=thumbnail") == true)
        XCTAssertEqual(content.data, Data([1, 2]))
    }

    func testContainerAndAgentArtifactContentRetainBinaryBytes() async throws {
        let bytes = Data([0, 255, 3])
        let transport = RecordingTransport(
            send: [
                .response(jsonResponse("{}")), .response(HTTPResponse(data: bytes, statusCode: 200)),
                .response(HTTPResponse(data: bytes, statusCode: 200)),
                .response(HTTPResponse(data: Data(), statusCode: 204)),
            ],
            stream: [.response(streamResponse(text: "data: [DONE]\n\n"))])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)

        _ = try await client.containers.uploadFile("container/a", fields: ["file_id": "file_1"])
        let containerFile = try await client.containers.fileContent("file/a", containerID: "container/a")
        let artifact = try await client.agents.artifactContent("artifact/a", sessionID: "session/a")
        try await client.agents.submitEvent("session/a", body: ["type": "input_message", "text": "Hello"])
        let events = try await client.agents.streamEvents("session/a")
        events.cancel()

        let requests = await transport.requests
        XCTAssertEqual(containerFile.data, bytes)
        XCTAssertEqual(artifact.data, bytes)
        XCTAssertTrue(
            requests[1].url?.absoluteString.hasSuffix("containers/container%2Fa/files/file%2Fa/content") == true)
        XCTAssertTrue(
            requests[2].url?.absoluteString.hasSuffix("agents/sessions/session%2Fa/artifacts/artifact%2Fa/content")
                == true)
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "OpenAI-Beta"), "agents=v1")
        XCTAssertEqual(requests[3].httpMethod, "POST")
        XCTAssertEqual(requests[4].httpMethod, "GET")
        XCTAssertEqual(requests[4].value(forHTTPHeaderField: "Accept"), "text/event-stream")
    }

    func testRealtimeSDPOfferUsesExplicitPartContentTypesAndVoidControlResponses() async throws {
        let answer = Data("v=0\r\nanswer".utf8)
        let transport = RecordingTransport(send: [
            .response(HTTPResponse(data: answer, statusCode: 201, headers: ["Location": "/v1/realtime/calls/call_1"])),
            .response(HTTPResponse(data: Data(), statusCode: 200)),
            .response(HTTPResponse(data: Data(), statusCode: 204)),
            .response(HTTPResponse(data: Data(), statusCode: 200)),
            .response(HTTPResponse(data: Data(), statusCode: 200)),
        ])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)

        let call = try await client.realtime.createCall(
            sdp: "v=0\r\noffer", session: ["type": "realtime", "model": "realtime-model"])
        try await client.realtime.acceptCall("call/a", session: ["type": "realtime"])
        try await client.realtime.hangupCall("call/a")
        try await client.realtime.referCall("call/a", targetURI: "sip:person@example.test")
        try await client.realtime.rejectCall("call/a", statusCode: 486)

        let requests = await transport.requests
        XCTAssertEqual(call.data, answer)
        XCTAssertEqual(call.header("Location"), "/v1/realtime/calls/call_1")
        let offer = try multipart(requests[0])
        XCTAssertTrue(offer.contains("name=\"sdp\"\r\nContent-Type: application/sdp\r\n\r\nv=0\r\noffer"))
        XCTAssertTrue(offer.contains("name=\"session\"\r\nContent-Type: application/json"))
        XCTAssertTrue(requests[1].url?.absoluteString.hasSuffix("realtime/calls/call%2Fa/accept") == true)
        XCTAssertNil(requests[2].httpBody)
        XCTAssertEqual(try body(requests[3])["target_uri"], "sip:person@example.test")
        XCTAssertEqual(try body(requests[4])["status_code"], 486)
    }

    func testLiveRecordingsAndWebhookActionsUseSpecificRoutes() async throws {
        let transport = RecordingTransport(send: [
            .response(HTTPResponse(data: Data([1, 2]), statusCode: 200)),
            .response(jsonResponse("{}")), .response(jsonResponse("{}")), .response(jsonResponse("{}")),
        ])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)

        let recording = try await client.live.downloadRecording("session/a")
        _ = try await client.live.fork("session/a", body: ["metadata": ["purpose": "test"]])
        _ = try await client.webhooks.rotateSecret("webhook/a", body: ["expires_after": 60])
        _ = try await client.webhooks.test("webhook/a", body: ["event_type": "response.completed"])

        let requests = await transport.requests
        XCTAssertEqual(recording.data, Data([1, 2]))
        XCTAssertTrue(requests[0].url?.absoluteString.hasSuffix("live/sessions/session%2Fa/content") == true)
        XCTAssertTrue(requests[1].url?.absoluteString.hasSuffix("live/sessions/session%2Fa/fork") == true)
        XCTAssertTrue(requests[2].url?.absoluteString.hasSuffix("webhook_endpoints/webhook%2Fa/rotate_secret") == true)
        XCTAssertTrue(requests[3].url?.absoluteString.hasSuffix("webhook_endpoints/webhook%2Fa/test") == true)
        XCTAssertEqual(try body(requests[3])["event_type"], "response.completed")
    }

    func testVoiceAndProvenanceUploadsUseMultipart() async throws {
        let transport = RecordingTransport(send: [.response(jsonResponse("{}")), .response(jsonResponse("{}"))])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)

        _ = try await client.audio.createVoice(
            fields: ["name": "Voice", "consent": "consent_1", "type": "audio_sample"],
            files: [MultipartFile(fieldName: "audio_sample", filename: "sample.wav", data: Data([1, 2]))])
        _ = try await client.contentProvenanceChecks.create(
            files: [MultipartFile(fieldName: "file", filename: "image.png", data: Data([3, 4]))])

        let requests = await transport.requests
        XCTAssertEqual(requests[0].url?.path, "/proxy/v1/audio/voices")
        XCTAssertTrue(try multipart(requests[0]).contains("name=\"audio_sample\"; filename=\"sample.wav\""))
        XCTAssertEqual(requests[1].url?.path, "/proxy/v1/content_provenance_checks")
        XCTAssertTrue(try multipart(requests[1]).contains("filename=\"image.png\""))
    }

    private func body(_ request: URLRequest) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(request.httpBody))
    }

    private func multipart(_ request: URLRequest) throws -> String {
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data;") == true)
        return String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
    }
}
