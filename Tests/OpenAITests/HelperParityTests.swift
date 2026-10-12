import Foundation
import XCTest

@testable import OpenAI

final class HelperParityTests: XCTestCase {
    func testPollingHeadersAndTerminalFailure() async throws {
        let transport = RecordingTransport(send: [
            .response(jsonResponse(#"{"id":"f","status":"in_progress"}"#, headers: ["openai-poll-after-ms": "1"])),
            .response(jsonResponse(#"{"id":"f","status":"failed","last_error":{"code":"invalid"}}"#)),
        ])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)
        let result = try await client.vectorStores.files("store").pollStatus("f", pollIntervalMilliseconds: 1)
        XCTAssertEqual(result["status"], "failed")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-Stainless-Poll-Helper"), "true")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-Stainless-Poll-Interval"), "1")
        XCTAssertEqual(Polling.interval(milliseconds: 0, headers: ["OpenAI-Poll-After-Ms": "9000"]), 8)
        XCTAssertEqual(Polling.interval(milliseconds: 0, headers: ["openai-poll-after-ms": "-2"]), 1)
        XCTAssertEqual(Polling.interval(milliseconds: 0, headers: ["openai-poll-after-ms": "1.5"]), 1)
        XCTAssertEqual(Polling.interval(milliseconds: 9000, headers: [:]), 9)
    }

    func testPollDeadlineBoundsWaitAndNestedOptions() async throws {
        let transport = RecordingTransport(send: [.response(jsonResponse(#"{"id":"f","status":"in_progress"}"#))])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)
        var options = RequestOptions()
        options.deadline = Date().addingTimeInterval(0.03)
        options.headerMutations = [.set("Test-Nested", "yes")]
        do {
            _ = try await client.vectorStores.files("s").pollStatus("f", options: options)
            XCTFail("Deadline ignored")
        } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
        let requests = await transport.requests
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Test-Nested"), "yes")
    }

    func testUnknownPollingStateFailsWithoutAnotherRequest() async throws {
        let transport = RecordingTransport(send: [.response(jsonResponse(#"{"status":"new_state"}"#))])
        let resource = OpenAIClient(configuration: testConfiguration(), transport: transport).vectorStores.files("s")
        do {
            _ = try await resource.pollStatus("f")
            XCTFail("Unknown status accepted")
        } catch {}
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testUploadAttachAndPoll() async throws {
        let transport = RecordingTransport(send: [
            .response(jsonResponse(#"{"id":"f","filename":"a.txt"}"#)),
            .response(jsonResponse(#"{"id":"f","status":"in_progress"}"#)),
            .response(jsonResponse(#"{"id":"f","status":"completed"}"#)),
        ])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)
        let result = try await client.vectorStores.uploadFileAndPoll(
            FileUpload(filename: "a.txt", data: Data("hello".utf8)), storeID: "s")
        XCTAssertEqual(result["status"], "completed")
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.url!.lastPathComponent }, ["files", "files", "f"])
        XCTAssertTrue(String(decoding: requests[0].httpBody!, as: UTF8.self).contains("assistants"))
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: requests[1].httpBody!), ["file_id": "f"])
    }

    func testAccumulatorCompletionBoundariesAndRejectedChunk() throws {
        var accumulator = ChatCompletionAccumulator()
        func chunk(_ delta: ChatCompletionDelta, choice: Int = 2, id: String = "c") -> ChatCompletionChunk {
            ChatCompletionChunk(id: id, choices: [.init(index: choice, delta: delta)])
        }
        XCTAssertTrue(accumulator.add(chunk(.init(content: "answer"))))
        XCTAssertNil(accumulator.justFinishedContent())
        XCTAssertTrue(
            accumulator.add(
                chunk(.init(toolCalls: [.init(index: -1, id: "t", function: .init(name: "run", arguments: "{}"))]))))
        XCTAssertEqual(accumulator.justFinishedContent(), "answer")
        XCTAssertEqual(accumulator.justFinishedContent(forChoice: 2), "answer")
        XCTAssertTrue(
            accumulator.add(chunk(.init(toolCalls: [.init(index: 1, id: "u", function: .init(name: "next"))]))))
        XCTAssertEqual(accumulator.justFinishedToolCall()?.name, "run")
        XCTAssertEqual(accumulator.justFinishedToolCall()?.index, 0)
        XCTAssertFalse(accumulator.add(chunk(.init(content: "bad"), choice: 128)))
        XCTAssertNil(accumulator.justFinishedToolCall())
        XCTAssertFalse(accumulator.add(chunk(.init(toolCalls: [.init(index: Int.max)]))))
        XCTAssertEqual(accumulator.completion?.choices.first?.message.content, .text("answer"))
    }

    func testAccumulatorRefusalAndValueIsolation() {
        var accumulator = ChatCompletionAccumulator()
        accumulator.add(.init(id: "c", choices: [.init(index: 0, delta: .init(refusal: "No"))]))
        var copy = accumulator
        accumulator.add(.init(id: "c", choices: [.init(index: 0, finishReason: "stop")]))
        XCTAssertEqual(accumulator.justFinishedRefusal(), "No")
        XCTAssertNil(copy.justFinishedRefusal())
        copy.reset()
        XCTAssertNil(copy.completion)
    }

    func testCustomToolResponseProjectsToAssistantInput() throws {
        let message = try OpenAIJSON.decode(
            ChatMessage.self,
            from: Data(
                #"{"role":"assistant","content":"","audio":{"id":"a","data":"response-only"},"annotations":[{}],"tool_calls":[{"id":"t","type":"custom","custom":{"name":"script","input":"print(1)"}}]}"#
                    .utf8))
        let input = try JSONValue.encode(message.asAssistantMessage())
        XCTAssertNil(input["content"])
        XCTAssertNil(input["annotations"])
        XCTAssertEqual(input["audio"], ["id": "a"])
        XCTAssertNil(input["tool_calls"]?[0]?["function"])
        XCTAssertEqual(input["tool_calls"]?[0]?["custom"]?["input"], "print(1)")
    }
}
