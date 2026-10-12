import Foundation
import XCTest

@testable import OpenAI

final class ChatTests: XCTestCase {
    func testOllamaReasoningIsRetainedSeparatelyFromAnswerAndProviderReasoningContent() throws {
        // Shape captured from Ollama 0.31.1 serving gpt-oss:latest.
        let raw = Data(
            #"{"role":"assistant","content":"4","reasoning":"Simple math.","reasoning_content":"alternate"}"#.utf8)
        let message = try OpenAIJSON.decode(ChatMessage.self, from: raw)
        XCTAssertEqual(message.reasoning, "Simple math.")
        XCTAssertEqual(message.reasoningContent, "alternate")
        XCTAssertEqual(message.text, "4")
        let projected = try JSONValue.encode(message.asAssistantMessage())
        XCTAssertEqual(projected["reasoning"], "Simple math.")
        XCTAssertEqual(projected["reasoning_content"], "alternate")
    }

    func testOllamaReasoningDeltasAccumulateWithoutBecomingAnswerText() throws {
        var accumulator = ChatCompletionAccumulator()
        for raw in [
            #"{"id":"chatcmpl-live","choices":[{"index":0,"delta":{"role":"assistant","reasoning":"Simple "}}]}"#,
            #"{"id":"chatcmpl-live","choices":[{"index":0,"delta":{"reasoning":"math.","reasoning_content":"other"}}]}"#,
            #"{"id":"chatcmpl-live","choices":[{"index":0,"delta":{"content":"4"},"finish_reason":"stop"}]}"#,
        ] {
            let chunk = try OpenAIJSON.decode(ChatCompletionChunk.self, from: Data(raw.utf8))
            XCTAssertTrue(accumulator.add(chunk))
        }
        let message = try XCTUnwrap(accumulator.completion?.choices.first?.message)
        XCTAssertEqual(message.reasoning, "Simple math.")
        XCTAssertEqual(message.reasoningContent, "other")
        XCTAssertEqual(message.text, "4")
    }

    func testMessagesEncodeTextMultimodalAndToolResults() throws {
        let messages: [ChatMessage] = [
            .system("Follow the user's instructions."),
            .developer("Return concise answers."),
            .user(
                .parts([
                    .text("Describe this image."),
                    .imageURL(.init(url: "data:image/png;base64,AAAA", detail: "high")),
                    .inputAudio(.init(data: "AAAA", format: "wav")),
                    .file(.init(fileID: "file_1")),
                ])),
            .assistant(toolCalls: [.init(id: "call_1", function: .init(name: "weather", arguments: "{}"))]),
            .tool("Sunny", toolCallID: "call_1"),
        ]
        let request = ChatCompletionRequest(model: "local-model", messages: messages, maxCompletionTokens: 100)
        let value = try JSONValue.encode(request)

        XCTAssertEqual(value["max_completion_tokens"], 100)
        XCTAssertNil(value["maxCompletionTokens"])
        XCTAssertEqual(value["messages"]?[2]?["content"]?[1]?["image_url"]?["detail"], "high")
        XCTAssertEqual(value["messages"]?[2]?["content"]?[2]?["input_audio"]?["format"], "wav")
        XCTAssertEqual(value["messages"]?[2]?["content"]?[3]?["file"]?["file_id"], "file_1")
        XCTAssertEqual(value["messages"]?[4]?["tool_call_id"], "call_1")
        XCTAssertEqual(try value.decode(ChatCompletionRequest.self), request)
    }

    func testStructuredOutputAndFunctionToolWireShapes() throws {
        let schema: JSONValue = [
            "type": "object",
            "properties": ["city": ["type": "string"]],
            "required": ["city"],
            "additionalProperties": false,
        ]
        let request = ChatCompletionRequest(
            model: "local-model",
            messages: [.user("Weather in Ashburn?")],
            tools: [.function(.init(name: "weather", parameters: schema, strict: true))],
            toolChoice: .function("weather"),
            responseFormat: .jsonSchema(.init(name: "weather_result", schema: schema, strict: true)),
            streamOptions: .init(includeUsage: true)
        )
        let value = try JSONValue.encode(request)

        XCTAssertEqual(value["tools"]?[0]?["type"], "function")
        XCTAssertEqual(value["tools"]?[0]?["function"]?["parameters"], schema)
        XCTAssertEqual(value["tool_choice"]?["function"]?["name"], "weather")
        XCTAssertEqual(value["response_format"]?["json_schema"]?["schema"], schema)
        XCTAssertEqual(value["stream_options"]?["include_usage"], true)
        XCTAssertEqual(try value.decode(ChatCompletionRequest.self), request)
    }

    func testUnknownPartsToolsFormatsAndToolChoicesRoundTrip() throws {
        let part: JSONValue = ["type": "vendor_video", "video_url": "https://example.test/clip"]
        let tool: JSONValue = ["type": "vendor_search", "index": "notes"]
        let format: JSONValue = ["type": "vendor_grammar", "grammar": "root ::= 'ok'"]
        let choice: JSONValue = ["type": "vendor_required", "tool": "search"]

        XCTAssertEqual(try JSONValue.encode(part.decode(ChatContentPart.self)), part)
        XCTAssertEqual(try JSONValue.encode(tool.decode(ChatTool.self)), tool)
        XCTAssertEqual(try JSONValue.encode(format.decode(ChatResponseFormat.self)), format)
        XCTAssertEqual(try JSONValue.encode(choice.decode(ChatToolChoice.self)), choice)
        XCTAssertEqual(try JSONValue.string("vendor_auto").decode(ChatToolChoice.self), .mode("vendor_auto"))
    }

    func testAccumulatorMergesSparseChoicesAndInterleavedToolFragments() throws {
        var accumulator = ChatCompletionAccumulator()
        XCTAssertNil(accumulator.completion)
        accumulator.add(
            .init(
                id: "response_1",
                choices: [
                    .init(index: 2, delta: .init(content: "Hello", reasoningContent: "Think ")),
                    .init(
                        index: 0,
                        delta: .init(
                            role: "assistant",
                            toolCalls: [
                                .init(index: 3, id: "call_", function: .init(name: "wea", arguments: "{\"city\":")),
                                .init(index: 0, id: "other", function: .init(name: "clock", arguments: "{")),
                            ])),
                ], created: 1, model: "local-model"))
        accumulator.add(
            .init(
                id: "response_1",
                choices: [
                    .init(
                        index: 0,
                        delta: .init(toolCalls: [
                            .init(index: 0, function: .init(arguments: "}")),
                            .init(index: 3, id: "3", function: .init(name: "ther", arguments: "\"Ashburn\"}")),
                        ]), finishReason: "tool_calls"),
                    .init(
                        index: 2, delta: .init(content: " world", reasoningContent: "carefully"), finishReason: "stop"),
                ]))
        accumulator.add(.init(id: "response_1", choices: [], usage: .init(totalTokens: 21)))
        let result = try XCTUnwrap(accumulator.completion)

        XCTAssertEqual(result.choices.map(\.index), [0, 2])
        XCTAssertEqual(result.choices[1].message.text, "Hello world")
        XCTAssertEqual(result.choices[1].message.reasoningContent, "Think carefully")
        XCTAssertEqual(result.choices[0].message.toolCalls?.map(\.id), ["other", "call_3"])
        XCTAssertEqual(result.choices[0].message.toolCalls?[1].function.name, "weather")
        XCTAssertEqual(result.choices[0].message.toolCalls?[1].function.arguments, "{\"city\":\"Ashburn\"}")
        XCTAssertEqual(result.choices[0].finishReason, "tool_calls")
        XCTAssertEqual(result.usage?.totalTokens, 21)
        XCTAssertEqual(result.created, 1)
        XCTAssertEqual(result.model, "local-model")
        XCTAssertEqual(result.object, "chat.completion")
        XCTAssertFalse(accumulator.add(.init(id: "another_response", choices: [])))
        XCTAssertEqual(accumulator.completion, result)
        accumulator.reset()
        XCTAssertNil(accumulator.completion)
    }

    func testAccumulatorPreservesEmptyContentRefusalLogprobsAndLegacyFunction() throws {
        var accumulator = ChatCompletionAccumulator()
        accumulator.add(
            .init(
                id: "r",
                choices: [
                    .init(
                        index: 0, delta: .init(content: "", refusal: "Cannot ", functionCall: .init(name: "get_")),
                        logprobs: .init(refusal: [.init(token: "Cannot", logprob: -0.1)]))
                ]))
        accumulator.add(
            .init(
                id: "r",
                choices: [
                    .init(
                        index: 0, delta: .init(refusal: "help", functionCall: .init(name: "info", arguments: "{}")),
                        finishReason: "provider_finish",
                        logprobs: .init(refusal: [.init(token: "help", logprob: -0.2)]))
                ]))
        let choice = try XCTUnwrap(accumulator.completion?.choices.first)

        XCTAssertEqual(choice.message.text, "")
        XCTAssertEqual(choice.message.refusal, "Cannot help")
        XCTAssertEqual(choice.message.functionCall, .init(name: "get_info", arguments: "{}"))
        XCTAssertEqual(choice.logprobs?.refusal?.map(\.token), ["Cannot", "help"])
        XCTAssertEqual(choice.finishReason, "provider_finish")
    }

    func testResponseDecodesNullableFieldsAndUsageDetails() throws {
        let fixture =
            #"{"id":"c","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":null,"refusal":null,"reasoning_content":"done","tool_calls":[{"id":"call","type":"function","function":{"name":"weather","arguments":"{}"}}]},"finish_reason":"tool_calls","logprobs":null}],"usage":{"prompt_tokens":8,"completion_tokens":5,"total_tokens":13,"prompt_tokens_details":{"cached_tokens":4},"completion_tokens_details":{"reasoning_tokens":2}},"service_tier":"local"}"#
        let result = try JSONDecoder().decode(ChatCompletion.self, from: Data(fixture.utf8))

        XCTAssertNil(result.choices[0].message.content)
        XCTAssertEqual(result.choices[0].message.reasoningContent, "done")
        XCTAssertEqual(result.usage?.promptTokensDetails?.cachedTokens, 4)
        XCTAssertEqual(result.usage?.completionTokensDetails?.reasoningTokens, 2)
        XCTAssertEqual(result.serviceTier, "local")
    }

    func testLegacyPromptShapesAndNullableProbabilities() throws {
        let prompts: [CompletionPrompt] = [
            .text("Hi"), .texts(["Hi", "Bye"]), .tokens([1, 2]), .tokenBatches([[1], [2]]),
        ]
        for prompt in prompts {
            let request = CompletionRequest(model: "local-model", prompt: prompt, maxTokens: 4, stop: ["END", "STOP"])
            let value = try JSONValue.encode(request)
            XCTAssertEqual(try value.decode(CompletionRequest.self), request)
            XCTAssertEqual(value["max_tokens"], 4)
            XCTAssertEqual(value["stop"], ["END", "STOP"])
        }
        let fixture =
            #"{"id":"legacy","choices":[{"index":0,"text":"Hi","finish_reason":null,"logprobs":{"tokens":["Hi"],"token_logprobs":[null],"top_logprobs":[null],"text_offset":[0]}}]}"#
        let response = try JSONDecoder().decode(Completion.self, from: Data(fixture.utf8))
        XCTAssertEqual(response.choices.first?.text, "Hi")
        XCTAssertEqual(response.choices.first?.logprobs?.tokenLogprobs?.count, 1)
        XCTAssertNil(response.choices.first?.logprobs?.tokenLogprobs?.first ?? nil)
    }

    func testFunctionArgumentsDecodeIntoApplicationModel() throws {
        struct Arguments: Decodable, Equatable { var city: String }
        let call = ChatFunctionCall(name: "weather", arguments: #"{"city":"Ashburn"}"#)
        XCTAssertEqual(try call.decodeArguments(as: Arguments.self), Arguments(city: "Ashburn"))
        XCTAssertThrowsError(try ChatFunctionCall(name: "weather", arguments: "{").decodeArguments(as: Arguments.self))
    }

    func testAudioAccumulatorAppendsPayloadAndTranscriptWhileKeepingMetadata() throws {
        var accumulator = ChatCompletionAccumulator()
        accumulator.add(
            .init(
                id: "audio",
                choices: [
                    .init(index: 0, delta: .init(audio: ["id": "audio_1", "data": "AAAA", "transcript": "Hello "]))
                ]))
        accumulator.add(
            .init(
                id: "audio",
                choices: [
                    .init(index: 0, delta: .init(audio: ["data": "BBBB", "transcript": "there", "expires_at": 123]))
                ]))
        let audio = try XCTUnwrap(accumulator.completion?.choices.first?.message.audio)
        XCTAssertEqual(audio["id"], "audio_1")
        XCTAssertEqual(audio["data"], "AAAABBBB")
        XCTAssertEqual(audio["transcript"], "Hello there")
        XCTAssertEqual(audio["expires_at"], 123)
    }
}
