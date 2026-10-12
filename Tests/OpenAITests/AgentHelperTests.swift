import Foundation
import XCTest

@testable import OpenAI

final class AgentHelperTests: XCTestCase {
    private func turn(_ status: String = "in_progress", subagent: String? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["id": "t", "session_id": "s", "status": .string(status)]
        if let subagent { fields["subagent_id"] = .string(subagent) }
        return .object(fields)
    }
    private func event(_ type: String, _ fields: [String: JSONValue] = [:]) -> JSONValue {
        var value = fields
        value["type"] = .string("agent.session." + type)
        value["event_id"] = .string(UUID().uuidString)
        value["session_id"] = "s"
        value["turn_id"] = "t"
        return .object(value)
    }
    private func message(_ text: String, index: Int64 = 0, phase: String = "final_answer") -> JSONValue {
        event(
            "turn.item.done",
            [
                "output_index": .integer(index),
                "item": [
                    "type": "message", "role": "assistant", "status": "completed", "turn_id": "t",
                    "phase": .string(phase),
                    "content": [["type": "output_text", "text": .string(text)]],
                ],
            ])
    }
    private func stream(
        _ events: [JSONValue], transport: RecordingTransport? = nil,
        handlers: [String: AgentToolHandler] = [:]
    ) -> AgentSessionStream {
        let pair = AsyncThrowingStream<JSONValue, any Error>.makeStream()
        for event in events { pair.continuation.yield(event) }
        pair.continuation.finish()
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport ?? RecordingTransport())
        return AgentSessionStream(
            stream: OpenAIStream(pair.stream, cancel: {}), service: AgentsService(client: client),
            sessionID: "s", options: .init(), handlers: handlers, allowEOF: true)
    }
    private var completed: [JSONValue] {
        [
            event("turn.created", ["turn": turn()]), message("second", index: 1),
            message("comment", phase: "commentary"),
            message("first"), event("turn.completed", ["turn": turn("completed")]), event("idle"),
        ]
    }

    func testFinalResultOrderingFilteringAndCache() async throws {
        let stream = stream(completed + [message("later")])
        let result = try await stream.finalResult()
        XCTAssertEqual(result.outputText, "firstsecond")
        XCTAssertEqual(result.sessionID, "s")
        XCTAssertEqual(result.turnID, "t")
        let cached = try await stream.finalResult()
        XCTAssertEqual(cached, result)
    }

    func testProgressRequiresEarlyCollection() async throws {
        let late = stream(completed)
        _ = try await late.next()
        do {
            _ = try await late.finalResult()
            XCTFail("Late collection accepted")
        } catch let error as AgentTurnResultError { XCTAssertEqual(error.reason, "collection_not_enabled") }
        let enabled = stream(completed)
        try await enabled.withResultCollection()
        _ = try await enabled.next()
        let result = try await enabled.finalResult()
        XCTAssertEqual(result.outputText, "firstsecond")
    }

    func testFailureIncompleteAndRequiredAction() async throws {
        for (events, expected) in [
            ([event("turn.created", ["turn": turn()]), event("turn.failed", ["turn": turn("failed")])], "turn_failed"),
            ([event("turn.created", ["turn": turn()]), message("partial")], "observation_incomplete"),
            (
                [
                    event(
                        "requires_action",
                        ["session": ["required_actions": [["type": "function_call", "name": "unknown"]]]])
                ], "requires_action"
            ),
            ([event("failed")], "session_failed"),
        ] {
            do {
                _ = try await stream(events).finalResult()
                XCTFail("Expected failure")
            } catch let error as AgentTurnResultError { XCTAssertEqual(error.reason, expected) }
        }
    }

    func testRootIdentityAndSubagents() async throws {
        let sub = event("turn.created", ["turn": turn(subagent: "child")])
        let result = try await stream([sub] + completed).finalResult()
        XCTAssertEqual(result.outputText, "firstsecond")
        let conflicting = event("turn.created", ["turn": ["id": "different", "session_id": "s"]])
        do {
            _ = try await stream([conflicting]).finalResult()
            XCTFail("Conflicting root accepted")
        } catch let error as AgentTurnResultError { XCTAssertEqual(error.reason, "observation_failed") }
    }

    func testRegisteredToolsAreDeferredAndDeduplicated() async throws {
        let transport = RecordingTransport(send: [.response(jsonResponse("{}"))])
        let call = event(
            "turn.item.added",
            [
                "item": [
                    "type": "function_call", "turn_id": "t", "call_id": "c", "name": "run", "arguments": "{\"x\":1}",
                ]
            ])
        let count = CancellationRecorder()
        let stream = stream(
            [call, call] + completed, transport: transport,
            handlers: [
                "run": { args in
                    XCTAssertEqual(args["x"], 1)
                    count.record()
                    return ["ok": true]
                }
            ])
        try await stream.withResultCollection()
        _ = try await stream.next()
        XCTAssertEqual(count.count, 0)
        let result = try await stream.finalResult()
        XCTAssertEqual(result.outputText, "firstsecond")
        XCTAssertEqual(count.count, 1)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        let body = try JSONDecoder().decode(JSONValue.self, from: requests[0].httpBody!)
        XCTAssertEqual(body["events"]?[0]?["success"], true)
        XCTAssertEqual(body["events"]?[0]?["output"], "{\"ok\":true}")
        XCTAssertNotNil(requests[0].value(forHTTPHeaderField: "Idempotency-Key"))
    }

    func testToolFailureRedactsApplicationError() async throws {
        let transport = RecordingTransport(send: [.response(jsonResponse("{}"))])
        let call = event(
            "turn.item.added",
            [
                "item": [
                    "type": "function_call", "turn_id": "t", "call_id": "c", "name": "run", "arguments": [:],
                ]
            ])
        _ = try await stream(
            [call] + completed, transport: transport,
            handlers: [
                "run": { _ in
                    throw OpenAIClientError.invalidConfiguration("private secret")
                }
            ]
        ).finalResult()
        let requests = await transport.requests
        let body = String(decoding: requests[0].httpBody!, as: UTF8.self)
        XCTAssertTrue(body.contains("Tool handler failed."))
        XCTAssertFalse(body.contains("private secret"))
    }

    func testTypedOutputNormalizationAndParseErrors() async throws {
        let schema: JSONValue = ["type": "object", "properties": ["answer": ["type": ["string", "null"]]]]
        let output = try AgentOutput<JSONValue>(schema: schema)
        XCTAssertEqual(output.format["schema"]?["required"], ["answer"])
        XCTAssertEqual(output.format["schema"]?["additionalProperties"], false)
        let result = AgentTurnResult(turn: turn("completed"), messages: [message("{\"answer\":\"yes\"}")["item"]!])
        XCTAssertEqual(try output.parseResult(result).output, ["answer": "yes"])
        let invalid = AgentTurnResult(turn: turn("completed"), messages: [message("private secret")["item"]!])
        do {
            _ = try output.parseResult(invalid)
            XCTFail("Invalid output accepted")
        } catch let error as AgentOutputParseError {
            XCTAssertEqual(error.result.outputText, "private secret")
            XCTAssertFalse(error.description.contains("private secret"))
        }
    }

    func testOutputSchemaRejectsUnsupportedStructure() throws {
        let invalid: [JSONValue] = [
            ["type": "array"], ["type": "object", "additionalProperties": true],
            ["type": "object", "properties": ["x": ["oneOf": []]]],
            ["type": "object", "properties": ["x": ["type": "string", "format": "uri"]]],
            ["type": "object", "properties": ["x": ["$ref": "https://example.test/schema"]]],
            ["type": "object", "properties": ["x": ["type": "integer", "enum": ["string"]]]],
        ]
        for schema in invalid { XCTAssertThrowsError(try AgentOutput<JSONValue>(schema: schema)) }
    }

    func testFollowupSubscribesBeforeInputAndResolvesIdempotencyHeaders() async throws {
        for header in ["explicit", ""] {
            let transport = RecordingTransport(
                send: [.response(jsonResponse(#"{"id":"s","status":"idle"}"#)), .response(jsonResponse("{}"))],
                stream: [.response(streamResponse(text: "data: [DONE]\n\n"))])
            var configuration = testConfiguration()
            configuration.headers["Idempotency-Key"] = "inherited"
            let service = AgentsService(client: OpenAIClient(configuration: configuration, transport: transport))
            var options = RequestOptions()
            options.headerMutations = [.set("Idempotency-Key", header)]
            let stream = try await service.stream(
                sessionID: "s", input: "hello", idempotencyKey: "parameter", options: options)
            stream.close()
            let requests = await transport.requests
            XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "POST"])
            let key = requests[2].value(forHTTPHeaderField: "Idempotency-Key")
            if header.isEmpty { XCTAssertFalse(key?.isEmpty ?? true) } else { XCTAssertEqual(key, header) }
            XCTAssertEqual(
                try OpenAIJSON.decode(JSONValue.self, from: requests[2].httpBody!)["events"]?[0]?["input"]?[0]?[
                    "content"]?[0]?["text"], "hello")
        }
    }

    func testClosePreventsDeferredToolExecution() async throws {
        let count = CancellationRecorder()
        let call = event(
            "turn.item.added",
            [
                "item": [
                    "type": "function_call", "turn_id": "t", "call_id": "c", "name": "run", "arguments": [:],
                ]
            ])
        let stream = stream(
            [call] + completed,
            handlers: [
                "run": { _ in
                    count.record()
                    return .null
                }
            ])
        _ = try await stream.next()
        stream.close()
        let next = try await stream.next()
        XCTAssertNil(next)
        XCTAssertEqual(count.count, 0)
    }

    func testInvalidToolOutputIsReplacedByGenericFailure() async throws {
        let transport = RecordingTransport(send: [.response(jsonResponse("{}"))])
        let call = event(
            "turn.item.added",
            [
                "item": [
                    "type": "function_call", "turn_id": "t", "call_id": "c", "name": "run", "arguments": [:],
                ]
            ])
        _ = try await stream([call] + completed, transport: transport, handlers: ["run": { _ in [.number(.nan)] }])
            .finalResult()
        let requests = await transport.requests
        let result = try OpenAIJSON.decode(JSONValue.self, from: requests[0].httpBody!)["events"]?[0]
        XCTAssertEqual(result?["success"], false)
        XCTAssertNil(result?["output"])
        XCTAssertEqual(result?["error"], "Tool handler failed.")
    }
}
