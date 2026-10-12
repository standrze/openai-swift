import Foundation
import XCTest

@testable import OpenAI

final class ResponseWebSocketAccumulatorTests: XCTestCase {
    private func event(_ json: String) throws -> ResponseEvent {
        try OpenAIJSON.decode(ResponseEvent.self, from: Data(json.utf8))
    }
    func testLaneBindingTerminalAndTransactionalRejection() throws {
        var accumulator = ResponseWebSocketAccumulator()
        try accumulator.add(event(#"{"type":"unknown","stream_id":"ignored"}"#))
        try accumulator.add(event(#"{"type":"response.created","stream_id":"a","response":{"id":"r","output":[]}}"#))
        try accumulator.add(
            event(
                #"{"type":"response.output_text.delta","stream_id":"a","item_id":"m","output_index":7,"content_index":4,"delta":"answer"}"#
            ))
        XCTAssertEqual(accumulator.detailedSnapshot.streamID, "a")
        XCTAssertEqual(accumulator.detailedSnapshot.output.first?.outputIndex, 7)
        XCTAssertEqual(accumulator.detailedSnapshot.output.first?.content[4]?["text"], "answer")
        XCTAssertThrowsError(
            try accumulator.add(
                event(
                    #"{"type":"response.output_text.delta","stream_id":"b","item_id":"m","output_index":7,"content_index":4,"delta":"bad"}"#
                )))
        for index in ["1.0", "\"1\"", "-1", "true", "9223372036854775808"] {
            XCTAssertThrowsError(
                try accumulator.add(
                    event(
                        "{\"type\":\"response.output_text.delta\",\"stream_id\":\"a\",\"item_id\":\"m\",\"output_index\":\(index),\"content_index\":0,\"delta\":\"bad\"}"
                    )))
        }
        XCTAssertEqual(accumulator.snapshot.outputText, "answer")
        try accumulator.add(
            event(#"{"type":"response.failed","stream_id":"a","response":{"id":"r","status":"failed"}}"#))
        XCTAssertEqual(accumulator.detailedSnapshot.terminalEvent, "response.failed")
        XCTAssertThrowsError(
            try accumulator.add(event(#"{"type":"response.created","stream_id":"a","response":{"id":"next"}}"#)))
        accumulator.reset()
        XCTAssertNil(accumulator.detailedSnapshot.streamID)
        XCTAssertTrue(accumulator.snapshot.output.isEmpty)
    }

    func testAnnotationsPreserveSparseIndicesAndCannotCreateItems() throws {
        var accumulator = ResponseWebSocketAccumulator()
        let annotation =
            #"{"type":"response.output_text.annotation.added","stream_id":"a","item_id":"m","output_index":0,"content_index":0,"annotation_index":9,"annotation":{"type":"citation"}}"#
        try accumulator.add(event(annotation))
        XCTAssertNil(accumulator.detailedSnapshot.streamID)
        try accumulator.add(
            event(
                #"{"type":"response.output_text.delta","stream_id":"a","item_id":"m","output_index":0,"content_index":0,"delta":"text"}"#
            ))
        try accumulator.add(event(annotation))
        XCTAssertEqual(accumulator.detailedSnapshot.output.first?.annotations[0]?[9]?["type"], "citation")
        XCTAssertNil(accumulator.detailedSnapshot.output.first?.content[0]?["annotations"])
        try accumulator.add(event(annotation.replacingOccurrences(of: "\"a\"", with: "\"other\"")))
        XCTAssertEqual(accumulator.snapshot.outputText, "text")
    }

    func testMalformedTerminalAndProtocolErrorDoNotFabricateSuccess() throws {
        var accumulator = ResponseWebSocketAccumulator()
        for payload in [
            #"{"type":"response.completed"}"#,
            #"{"type":"response.completed","response":{"id":"r","output":{}}}"#,
            #"{"type":"response.completed","response":{"id":"r","output":[{"type":"function_call","arguments":4}]}}"#,
            #"{"type":"error","error":{"code":"failure"}}"#,
        ] { XCTAssertThrowsError(try accumulator.add(event(payload))) }
        XCTAssertNil(accumulator.snapshot.terminalEvent)
        XCTAssertNil(accumulator.detailedSnapshot.streamID)
    }
}
