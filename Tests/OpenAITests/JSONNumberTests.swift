import Foundation
import XCTest

@testable import OpenAI

final class JSONNumberTests: XCTestCase {
    func testExactDynamicNumbersSurviveDecodeMutationAndHTTPForwarding() async throws {
        let data = Data(#"{"huge":1e999,"integer":18446744073709551615,"fraction":1.0000000000000001}"#.utf8)
        let value = try OpenAIJSON.decode(JSONValue.self, from: data)
        XCTAssertEqual(value["huge"], .rawNumber(try JSONNumber("1e999")))
        XCTAssertEqual(value["integer"], .rawNumber(try JSONNumber("18446744073709551615")))
        XCTAssertEqual(value["fraction"], .rawNumber(try JSONNumber("1.0000000000000001")))
        let roundTrip = try OpenAIJSON.decode(JSONValue.self, from: value.encodedData())
        XCTAssertEqual(roundTrip, value)
        let transport = RecordingTransport(send: [.response(jsonResponse("{}"))])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)
        let _: JSONValue = try await client.send(
            .post, path: "custom", body: value, options: .init(extraBody: ["added": true]))
        let requests = await transport.requests
        let forwarded = try OpenAIJSON.decode(JSONValue.self, from: requests[0].httpBody!)
        XCTAssertEqual(forwarded["huge"], value["huge"])
        XCTAssertEqual(forwarded["added"], true)
    }

    func testIntegerSchemaConstraintsUseExactDecimalValue() throws {
        for (text, expected) in [
            ("1.0000000000000001", false), ("18446744073709551615", true), ("100e-2", true),
            ("1e999999999999999999999999999", true), ("1e-999999999999999999999999999", false), ("0e-9999", true),
        ] {
            XCTAssertEqual(try JSONNumber(text).isInteger, expected)
        }
        let invalid = Data(#"{"type":"object","properties":{"x":{"type":"integer","const":1.0000000000000001}}}"#.utf8)
        XCTAssertThrowsError(
            try AgentOutput<JSONValue>(schemaJSON: invalid) { try OpenAIJSON.decode(JSONValue.self, from: $0) })
        let valid = Data(#"{"type":"object","properties":{"x":{"type":"integer","const":18446744073709551615}}}"#.utf8)
        let output = try AgentOutput<JSONValue>(schemaJSON: valid) { try OpenAIJSON.decode(JSONValue.self, from: $0) }
        XCTAssertTrue(String(decoding: try output.format.encodedData(), as: UTF8.self).contains("18446744073709551615"))
    }

    func testFoundationEncodingIsExactOrFailsExplicitly() throws {
        let precise = try JSONNumber("1.0000000000000001")
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(precise), as: UTF8.self), precise.rawValue)
        XCTAssertThrowsError(try JSONEncoder().encode(JSONNumber("1e999")))
        for invalid in ["NaN", "01", "1x", "true", "1\n2"] { XCTAssertThrowsError(try JSONNumber(invalid)) }
    }
}
