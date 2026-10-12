import Foundation
import XCTest

@testable import OpenAI

final class ResourceTests: XCTestCase {
    func testResponseRequestEncodesInputAndSnakeCaseParameters() throws {
        let schema: JSONValue = ["type": "object", "properties": ["city": ["type": "string"]]]
        var request = ResponseRequest(
            model: "local-model",
            input: .items([
                ResponseInput.message("Find weather"),
                ResponseInput.functionResult(callID: "call_1", output: "Sunny"),
            ]))
        request.maxOutputTokens = 300
        request.previousResponseID = "resp_1"
        request.parallelToolCalls = false
        request.tools = [ResponseInput.functionTool(name: "weather", parameters: schema, strict: true)]
        request.toolChoice = ["type": "function", "name": "weather"]
        let value = try JSONValue.encode(request)

        XCTAssertEqual(value["max_output_tokens"], 300)
        XCTAssertEqual(value["previous_response_id"], "resp_1")
        XCTAssertEqual(value["parallel_tool_calls"], false)
        XCTAssertNil(value["maxOutputTokens"])
        XCTAssertNil(value["stream"])
        XCTAssertEqual(value["input"]?[1]?["call_id"], "call_1")
        XCTAssertEqual(value["tools"]?[0]?["parameters"], schema)
        XCTAssertEqual(value["tools"]?[0]?["strict"], true)
        XCTAssertEqual(try JSONValue.encode(ResponseInput.text("Hello")), "Hello")
        XCTAssertEqual(try value.decode(ResponseRequest.self).input, request.input)
    }

    func testResponseRetainsUnknownFieldsAndProvidesTextAndCalls() throws {
        let value: JSONValue = [
            "id": "resp_1", "status": "completed", "model": "local-model", "created_at": 123,
            "output": [
                [
                    "type": "message", "id": "msg_1", "role": "assistant",
                    "content": [
                        ["type": "output_text", "text": "Hello", "annotations": [], "future": true],
                        ["type": "refusal", "refusal": "No"],
                        ["type": "output_text", "text": " world"],
                    ],
                ],
                ["type": "function_call", "call_id": "call_1", "name": "weather", "arguments": "{}"],
                ["type": "future_tool", "content": "opaque", "arguments": ["city": "Ashburn"]],
            ],
            "usage": ["input_tokens": 7, "output_tokens": 2, "total_tokens": 9],
            "vendor": ["cache": true],
        ]
        let response = try value.decode(Response.self)

        XCTAssertEqual(response.outputText, "Hello world")
        XCTAssertEqual(response.functionCalls, [.init(callID: "call_1", name: "weather", arguments: "{}")])
        XCTAssertEqual(response.output[0].content[1].refusal, "No")
        XCTAssertEqual(response.output[2].rawValue["content"], "opaque")
        XCTAssertEqual(response.usage?.totalTokens, 9)
        XCTAssertEqual(try JSONValue.encode(response), value)
    }

    func testResponseEventsPreserveFutureDeltasAndTopLevelErrors() throws {
        let delta: JSONValue = [
            "type": "response.output_text.delta", "sequence_number": 2,
            "output_index": 0, "content_index": 0, "item_id": "msg_1", "delta": "Hello",
        ]
        let textEvent = try delta.decode(ResponseEvent.self)
        XCTAssertEqual(textEvent.textDelta, "Hello")
        XCTAssertEqual(textEvent.itemID, "msg_1")
        XCTAssertEqual(textEvent.sequenceNumber, 2)
        XCTAssertEqual(try JSONValue.encode(textEvent), delta)

        let future: JSONValue = [
            "type": "vendor.future", "delta": ["bytes": [1, 2]], "response": "opaque",
        ]
        let futureEvent = try future.decode(ResponseEvent.self)
        XCTAssertNil(futureEvent.textDelta)
        XCTAssertNil(futureEvent.response)
        XCTAssertEqual(try JSONValue.encode(futureEvent), future)

        let error: JSONValue = ["type": "error", "code": "server_error", "message": "Unavailable", "param": nil]
        let errorEvent = try error.decode(ResponseEvent.self)
        XCTAssertEqual(errorEvent.code, "server_error")
        XCTAssertEqual(errorEvent.message, "Unavailable")
        XCTAssertEqual(try JSONValue.encode(errorEvent), error)
    }

    func testEmbeddingInputAndOutputWireFormats() throws {
        let inputs: [(EmbeddingInput, JSONValue)] = [
            (.text("one"), "one"),
            (.texts(["one", "two"]), ["one", "two"]),
            (.tokens([1, 2]), [1, 2]),
            (.tokenArrays([[1, 2], [3]]), [[1, 2], [3]]),
        ]
        for (input, value) in inputs {
            XCTAssertEqual(try JSONValue.encode(input), value)
            XCTAssertEqual(try value.decode(EmbeddingInput.self), input)
        }

        let floatResponse: JSONValue = [
            "data": [["index": 0, "embedding": [0.25, -0.5]]],
            "usage": ["prompt_tokens": 2, "total_tokens": 2],
        ]
        let response = try floatResponse.decode(EmbeddingResponse.self)
        XCTAssertEqual(response.data[0].embedding.floats, [0.25, -0.5])
        XCTAssertEqual(response.usage?.promptTokens, 2)
        let base64: JSONValue = "AACAPw=="
        XCTAssertEqual(try base64.decode(EmbeddingVector.self).base64, "AACAPw==")

        let request = EmbeddingRequest(model: "local-embed", input: .texts(["one"]), encodingFormat: "base64")
        XCTAssertEqual(try JSONValue.encode(request)["encoding_format"], "base64")
    }

    func testModelsDecodeMinimalCompatibleProviderResponses() throws {
        let value: JSONValue = ["data": [["id": "local/model:latest", "owned_by": "library"]]]
        let models = try value.decode(Page<OpenAIModel>.self)

        XCTAssertEqual(models.data.first?.id, "local/model:latest")
        XCTAssertEqual(models.data.first?.ownedBy, "library")
        XCTAssertNil(models.data.first?.created)
    }

    func testFilesDecodeMetadataAndSnakeCaseTimestamps() throws {
        let value: JSONValue = [
            "id": "file_1", "filename": "requests.jsonl", "purpose": "batch", "bytes": 250,
            "created_at": 123, "expires_at": 456, "status_details": "Ready",
        ]
        let file = try value.decode(FileObject.self)

        XCTAssertEqual(file.bytes, 250)
        XCTAssertEqual(file.createdAt, 123)
        XCTAssertEqual(file.expiresAt, 456)
        XCTAssertEqual(file.statusDetails, "Ready")
    }

    func testImagesDecodeBase64BytesAndEncodeGenerationParameters() throws {
        let value: JSONValue = ["data": [["b64_json": "aGVsbG8=", "revised_prompt": "A landscape"]]]
        let response = try value.decode(ImageResponse.self)

        XCTAssertEqual(response.data.first?.data, Data("hello".utf8))
        XCTAssertEqual(response.data.first?.revisedPrompt, "A landscape")
        var request = ImageGenerationRequest(prompt: "A landscape", model: "local-image")
        request.responseFormat = "b64_json"
        request.outputCompression = 80
        let requestValue = try JSONValue.encode(request)
        XCTAssertEqual(requestValue["response_format"], "b64_json")
        XCTAssertEqual(requestValue["output_compression"], 80)
    }

    func testAudioDecodesVerboseTranscriptionAndEncodesSpeechFormat() throws {
        let value: JSONValue = [
            "text": "Hello", "duration": 1.25, "language": "english",
            "segments": [["start": 0, "end": 1.25, "text": "Hello"]],
        ]
        let transcription = try value.decode(AudioTranscription.self)

        XCTAssertEqual(transcription.text, "Hello")
        XCTAssertEqual(transcription.duration, 1.25)
        XCTAssertEqual(transcription.segments?.first?["end"], 1.25)
        let request = SpeechRequest(model: "local-tts", input: "Hello", voice: "voice", responseFormat: "wav")
        XCTAssertEqual(try JSONValue.encode(request)["response_format"], "wav")
    }

    func testModerationKeepsDynamicCategoryNames() throws {
        let value: JSONValue = [
            "id": "mod_1", "model": "local-moderation",
            "results": [
                [
                    "flagged": true, "categories": ["future/category": true],
                    "category_scores": ["future/category": 0.75],
                    "category_applied_input_types": ["future/category": ["text", "image"]],
                ]
            ],
        ]
        let response = try value.decode(ModerationResponse.self)

        XCTAssertEqual(response.results.first?.categories["future/category"], true)
        XCTAssertEqual(response.results.first?.categoryScores["future/category"], 0.75)
        XCTAssertEqual(response.results.first?.categoryAppliedInputTypes?["future/category"], ["text", "image"])
    }

    func testBatchesPreserveLifecycleMetadataAndUnknownFields() throws {
        let value: JSONValue = [
            "id": "batch_1", "status": "completed", "input_file_id": "file_1",
            "output_file_id": "file_2", "created_at": 123, "completed_at": 456,
            "request_counts": ["total": 2, "completed": 1, "failed": 1],
            "vendor_status": ["phase": 7],
        ]
        let batch = try value.decode(Batch.self)

        XCTAssertEqual(batch.inputFileID, "file_1")
        XCTAssertEqual(batch.outputFileID, "file_2")
        XCTAssertEqual(batch.requestCounts?.failed, 1)
        XCTAssertEqual(batch.completedAt, 456)
        XCTAssertEqual(try JSONValue.encode(batch), value)
        let request = BatchRequest(inputFileID: "file_1", endpoint: "/v1/chat/completions")
        XCTAssertEqual(try JSONValue.encode(request)["completion_window"], "24h")
    }

    func testPageRetainsOpaqueNextAndNextPageMetadata() throws {
        let next = try JSONValue.object(["data": [], "has_more": true, "next": "opaque/next"]).decode(
            Page<JSONValue>.self)
        let nextPage = try JSONValue.object(["data": [], "next_page": "page-token"]).decode(Page<JSONValue>.self)

        XCTAssertEqual(next.next, "opaque/next")
        XCTAssertEqual(nextPage.nextPage, "page-token")
        XCTAssertEqual(try JSONValue.encode(nextPage)["next_page"], "page-token")
    }

    func testAdminNextCursorUsesAfterAndPreservesInheritedRepeatedFilters() async throws {
        let transport = RecordingTransport(send: [
            .response(jsonResponse(#"{"data":[{"id":"group-1"}],"has_more":true,"next":"opaque/group-1"}"#)),
            .response(jsonResponse(#"{"data":[{"id":"group-2"}],"has_more":false,"next":null}"#)),
        ])
        let resource = APIResource(
            client: OpenAIClient(configuration: testConfiguration(), transport: transport),
            path: "organization/groups",
            defaultOptions: RequestOptions(
                query: ["limit": "2"],
                queryItems: [
                    URLQueryItem(name: "filter[]", value: "first"), URLQueryItem(name: "filter[]", value: "second"),
                    URLQueryItem(name: "after", value: "initial"),
                ])
        )
        var ids: [String] = []

        for try await item in resource.all() { ids.append(try XCTUnwrap(item["id"]?.stringValue)) }

        XCTAssertEqual(ids, ["group-1", "group-2"])
        let requests = await transport.requests
        let query = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(requests.last?.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.filter { $0.name == "after" }.map(\.value), ["opaque/group-1"])
        XCTAssertEqual(query.filter { $0.name == "filter[]" }.map(\.value), ["first", "second"])
        XCTAssertEqual(query.first { $0.name == "limit" }?.value, "2")
    }

    func testAgentsEnvironmentFilesUsePageTokensRatherThanItemIDs() async throws {
        let transport = RecordingTransport(send: [
            .response(jsonResponse(#"{"data":[{"path":"/first"}],"has_more":true,"next":"opaque/file-page"}"#)),
            .response(jsonResponse(#"{"data":[{"path":"/second"}],"has_more":false,"next":null}"#)),
        ])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)
        var paths: [String] = []

        for try await item in client.resource("agents/environments/env-1/files").all() {
            paths.append(try XCTUnwrap(item["path"]?.stringValue))
        }

        XCTAssertEqual(paths, ["/first", "/second"])
        let requests = await transport.requests
        let query = URLComponents(url: try XCTUnwrap(requests.last?.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "page" }?.value, "opaque/file-page")
        XCTAssertNil(query?.first { $0.name == "after" })
    }

    func testUsageNextPageUsesPageAndRetainsTimeRange() async throws {
        let transport = RecordingTransport(send: [
            .response(
                jsonResponse(#"{"data":[{"start_time":100,"results":[]}],"has_more":true,"next_page":"usage-next"}"#)),
            .response(jsonResponse(#"{"data":[{"start_time":200,"results":[]}],"has_more":false,"next_page":null}"#)),
        ])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)
        var count = 0

        for try await _ in client.resource("organization/usage/completions").all(
            options: RequestOptions(query: ["start_time": "100"]))
        {
            count += 1
        }

        XCTAssertEqual(count, 2)
        let requests = await transport.requests
        let query = URLComponents(url: try XCTUnwrap(requests.last?.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "page" }?.value, "usage-next")
        XCTAssertEqual(query?.first { $0.name == "start_time" }?.value, "100")
    }

    func testExplicitCursorStyleContinuesWhenHasMoreIsOmitted() async throws {
        let transport = RecordingTransport(send: [
            .response(jsonResponse(#"{"data":[{"id":"skill-1"}]}"#)),
            .response(jsonResponse(#"{"data":[]}"#)),
        ])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)
        var count = 0

        for try await _ in client.resource("skills").all(pagination: .cursor) { count += 1 }

        XCTAssertEqual(count, 1)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        let query = URLComponents(url: try XCTUnwrap(requests.last?.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "after" }?.value, "skill-1")
    }

    func testUsageMissingPageTokenDoesNotFallBackToItemID() async throws {
        for path in ["organization/costs", "organization/usage/completions"] {
            let transport = RecordingTransport(send: [
                .response(jsonResponse(#"{"data":[{"id":"bucket-1"}],"has_more":true}"#))
            ])
            let client = OpenAIClient(configuration: testConfiguration(), transport: transport)

            do {
                for try await _ in client.resource(path).all() {}
                XCTFail("Usage pagination must require its page token")
            } catch OpenAIClientError.pagination(let message) {
                XCTAssertEqual(message, "Missing page continuation token")
            }

            let requests = await transport.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testExplicitConversationCursorUsesLastIDAndAutomaticCompatibleListsStop() async throws {
        let transport = RecordingTransport(send: [
            .response(jsonResponse(#"{"data":[{"id":"item-id"}],"last_id":"server-cursor"}"#)),
            .response(jsonResponse(#"{"data":[],"has_more":false}"#)),
            .response(jsonResponse(#"{"data":[{"id":"local-model"}]}"#)),
        ])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)
        for try await _ in client.resource("videos").all(pagination: .conversationCursor) {}
        for try await _ in client.resource("models").all() {}

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
        let query = URLComponents(url: try XCTUnwrap(requests[1].url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "after" }?.value, "server-cursor")
    }

    func testOpaqueTokenCyclesAndMissingTokensFailWithoutLooping() async throws {
        for secondPage in [
            #"{"data":[{"path":"/second"}],"has_more":true,"next":"repeated"}"#,
            #"{"data":[{"path":"/second"}],"has_more":true}"#,
        ] {
            let transport = RecordingTransport(send: [
                .response(jsonResponse(#"{"data":[{"path":"/first"}],"has_more":true,"next":"repeated"}"#)),
                .response(jsonResponse(secondPage)),
            ])
            let client = OpenAIClient(configuration: testConfiguration(), transport: transport)
            do {
                for try await _ in client.resource("custom/files").all(pagination: .token) {}
                XCTFail("Invalid opaque continuation must fail")
            } catch OpenAIClientError.pagination {}
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 2)
        }
    }
}
