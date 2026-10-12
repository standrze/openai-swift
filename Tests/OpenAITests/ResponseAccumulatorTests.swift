import Foundation
import XCTest

@testable import OpenAI

final class ResponseAccumulatorTests: XCTestCase {
    func testTextDeltaExcludesReasoningRefusalAndToolArguments() throws {
        for type in [
            "response.reasoning_summary_text.delta", "response.reasoning_text.delta",
            "response.function_call_arguments.delta", "response.refusal.delta", "provider.unknown.delta",
        ] {
            let raw: JSONValue = ["type": .string(type), "delta": "separate channel"]
            let event = try raw.decode(ResponseEvent.self)
            XCTAssertNil(event.textDelta, type)
            XCTAssertEqual(event.delta, "separate channel")
        }
        let event = try event(#"{"type":"response.output_text.delta","delta":"answer"}"#)
        XCTAssertEqual(event.textDelta, "answer")
    }

    func testAccumulatesSparseMessagePartsInIndexOrderAndReplacesDoneText() throws {
        var accumulator = ResponseAccumulator()
        try accumulator.add(event(#"{"type":"response.created","response":{"id":"resp-1","output":[]}}"#))
        try accumulator.add(
            event(
                #"{"type":"response.output_text.delta","output_index":4,"content_index":3,"item_id":"msg-4","delta":"later"}"#
            ))
        try accumulator.add(
            event(
                #"{"type":"response.output_text.delta","output_index":1,"content_index":2,"item_id":"msg-1","delta":"hel"}"#
            ))
        try accumulator.add(
            event(
                #"{"type":"response.output_text.delta","output_index":1,"content_index":2,"item_id":"msg-1","delta":"lo"}"#
            ))
        try accumulator.add(
            event(
                #"{"type":"response.output_text.done","output_index":1,"content_index":2,"item_id":"msg-1","text":"Hello!"}"#
            ))

        XCTAssertEqual(accumulator.snapshot.id, "resp-1")
        XCTAssertEqual(accumulator.snapshot.output.map(\.id), ["msg-1", "msg-4"])
        XCTAssertEqual(accumulator.snapshot.outputText, "Hello!later")
        XCTAssertNil(accumulator.snapshot.terminalEvent)
        XCTAssertNil(accumulator.snapshot.response)
    }

    func testContentPartAndItemDonePayloadsReplaceFragmentsAndKeepExtensions() throws {
        var accumulator = ResponseAccumulator()
        try accumulator.add(
            event(
                #"{"type":"response.output_item.added","output_index":0,"item":{"id":"msg-1","type":"message","role":"assistant","content":[],"vendor":"retained"}}"#
            ))
        try accumulator.add(
            event(
                #"{"type":"response.content_part.added","output_index":0,"content_index":0,"item_id":"msg-1","part":{"type":"output_text","text":"draft","annotations":[]}}"#
            ))
        try accumulator.add(
            event(
                #"{"type":"response.output_text.delta","output_index":0,"content_index":0,"item_id":"msg-1","delta":" fragment"}"#
            ))
        try accumulator.add(
            event(
                #"{"type":"response.content_part.done","output_index":0,"content_index":0,"item_id":"msg-1","part":{"type":"output_text","text":"authoritative part","annotations":[{"type":"citation"}]}}"#
            ))
        XCTAssertEqual(accumulator.snapshot.outputText, "authoritative part")
        XCTAssertEqual(accumulator.snapshot.output.first?.rawValue["vendor"], "retained")
        XCTAssertEqual(accumulator.snapshot.output.first?.content.first?.annotations?.count, 1)

        try accumulator.add(
            event(
                #"{"type":"response.output_item.done","output_index":0,"item":{"id":"msg-1","type":"message","status":"completed","content":[]}}"#
            ))

        XCTAssertEqual(accumulator.snapshot.outputText, "")
        XCTAssertEqual(accumulator.snapshot.output.first?.status, "completed")
    }

    func testAccumulatesRefusalAndFunctionArgumentsWithAuthoritativeDoneValues() throws {
        var accumulator = ResponseAccumulator()
        try accumulator.add(
            event(
                #"{"type":"response.refusal.delta","output_index":0,"content_index":0,"item_id":"msg-1","delta":"cannot "}"#
            ))
        try accumulator.add(
            event(
                #"{"type":"response.refusal.delta","output_index":0,"content_index":0,"item_id":"msg-1","delta":"help"}"#
            ))
        try accumulator.add(
            event(
                #"{"type":"response.refusal.done","output_index":0,"content_index":0,"item_id":"msg-1","refusal":"I cannot help."}"#
            ))
        try accumulator.add(
            event(
                #"{"type":"response.output_item.added","output_index":2,"item":{"id":"call-1","type":"function_call","name":"weather","call_id":"tool-1","arguments":""}}"#
            ))
        try accumulator.add(
            event(
                #"{"type":"response.function_call_arguments.delta","output_index":2,"item_id":"call-1","delta":"{\"city\":"}"#
            ))
        try accumulator.add(
            event(
                #"{"type":"response.function_call_arguments.delta","output_index":2,"item_id":"call-1","delta":"\"Boston\"}"}"#
            ))
        XCTAssertEqual(accumulator.snapshot.output.last?.arguments, #"{"city":"Boston"}"#)
        try accumulator.add(
            event(
                #"{"type":"response.function_call_arguments.done","output_index":2,"item_id":"call-1","arguments":"{\"city\":\"Paris\"}"}"#
            ))

        XCTAssertEqual(accumulator.snapshot.output.first?.content.first?.refusal, "I cannot help.")
        XCTAssertEqual(accumulator.snapshot.outputText, "")
        XCTAssertEqual(accumulator.snapshot.output.last?.functionCall?.name, "weather")
        XCTAssertEqual(accumulator.snapshot.output.last?.functionCall?.arguments, #"{"city":"Paris"}"#)
    }

    func testTerminalSnapshotRetainsOmittedOutputAndHonorsExplicitEmptyOutput() throws {
        for terminal in ["response.completed", "response.failed", "response.incomplete"] {
            var accumulator = ResponseAccumulator()
            try accumulator.add(event(#"{"type":"response.in_progress","response":{"id":"resp-1"}}"#))
            try accumulator.add(
                event(#"{"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":"retained"}"#))
            try accumulator.add(event("{\"type\":\"\(terminal)\",\"response\":{\"id\":\"resp-1\"}}"))

            XCTAssertEqual(accumulator.snapshot.outputText, "retained")
            XCTAssertEqual(accumulator.snapshot.terminalEvent, terminal)
            XCTAssertEqual(accumulator.snapshot.response?.id, "resp-1")
            XCTAssertTrue(accumulator.snapshot.response?.output.isEmpty == true)

            try accumulator.add(event("{\"type\":\"\(terminal)\",\"response\":{\"id\":\"resp-1\",\"output\":[]}}"))
            XCTAssertTrue(accumulator.snapshot.output.isEmpty)
        }
    }

    func testTerminalResponseReplacesOutputAndMixedResponseIDsAreRejectedWithoutMutation() throws {
        var accumulator = ResponseAccumulator()
        try accumulator.add(event(#"{"type":"response.created","response":{"id":"resp-1"}}"#))
        try accumulator.add(
            event(#"{"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":"draft"}"#))
        XCTAssertThrowsError(
            try accumulator.add(
                event(
                    #"{"type":"response.output_text.delta","response_id":"resp-2","output_index":0,"content_index":0,"delta":"wrong"}"#
                ))
        ) {
            guard case OpenAIClientError.invalidStream = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertEqual(accumulator.snapshot.outputText, "draft")
        try accumulator.add(
            event(
                #"{"type":"response.completed","response":{"id":"resp-1","status":"completed","output":[{"type":"message","id":"final","content":[{"type":"output_text","text":"final server text"}]}]}}"#
            ))

        XCTAssertEqual(accumulator.snapshot.outputText, "final server text")
        XCTAssertEqual(accumulator.snapshot.response?.outputText, "final server text")
        XCTAssertEqual(accumulator.snapshot.output.first?.id, "final")
    }

    func testConflictingItemIDStartsFreshAndResetClearsAllState() throws {
        var accumulator = ResponseAccumulator()
        try accumulator.add(
            event(
                #"{"type":"response.output_item.added","output_index":0,"item":{"id":"old","type":"message","role":"assistant","content":[{"type":"output_text","text":"old text"}]}}"#
            ))
        try accumulator.add(
            event(
                #"{"type":"response.output_text.delta","output_index":0,"content_index":0,"item_id":"new","delta":"fresh"}"#
            ))
        try accumulator.add(
            event(#"{"type":"response.future_event","response_id":"ignored","provider_payload":{"ignored":true}}"#))

        XCTAssertEqual(accumulator.snapshot.output.first?.id, "new")
        XCTAssertEqual(accumulator.snapshot.outputText, "fresh")
        XCTAssertNil(accumulator.snapshot.id)
        XCTAssertNil(accumulator.snapshot.output.first?.role)

        accumulator.reset()

        XCTAssertNil(accumulator.snapshot.id)
        XCTAssertTrue(accumulator.snapshot.output.isEmpty)
        XCTAssertEqual(accumulator.snapshot.outputText, "")
        XCTAssertNil(accumulator.snapshot.terminalEvent)
        XCTAssertNil(accumulator.snapshot.response)
        try accumulator.add(event(#"{"type":"response.created","response":{"id":"resp-new"}}"#))
        XCTAssertEqual(accumulator.snapshot.id, "resp-new")
    }

    private func event(_ json: String) throws -> ResponseEvent {
        try JSONDecoder().decode(ResponseEvent.self, from: Data(json.utf8))
    }
}
