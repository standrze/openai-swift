import Foundation
import XCTest

@testable import OpenAI

final class TransportTests: XCTestCase {
    func testRetryableStatusRetriesAndReturnsSuccessfulResponse() async throws {
        let transport = RecordingTransport(send: [
            .response(jsonResponse(#"{"error":{"message":"busy"}}"#, status: 429)),
            .response(jsonResponse(#"{"error":{"message":"temporarily unavailable"}}"#, status: 503)),
            .response(jsonResponse()),
        ])
        let client = OpenAIClient(configuration: testConfiguration(maxRetries: 2), transport: transport)

        let document: TestDocument = try await client.send(.get, path: "models")

        XCTAssertEqual(document.value, "ready")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.allSatisfy { $0.url == requests.first?.url })
    }

    func testConnectionFailureRetriesWithinConfiguredLimit() async throws {
        let transport = RecordingTransport(send: [
            .failure(URLError(.networkConnectionLost)),
            .response(jsonResponse()),
        ])
        let client = OpenAIClient(configuration: testConfiguration(maxRetries: 1), transport: transport)

        let document: TestDocument = try await client.send(.get, path: "models")

        XCTAssertEqual(document.value, "ready")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testRequestCanDisableConfiguredRetries() async throws {
        let transport = RecordingTransport(send: [
            .response(jsonResponse(#"{"error":{"message":"busy"}}"#, status: 429)),
            .response(jsonResponse()),
        ])
        let client = OpenAIClient(configuration: testConfiguration(maxRetries: 3), transport: transport)

        do {
            let _: TestDocument = try await client.send(.get, path: "models", options: RequestOptions(maxRetries: 0))
            XCTFail("Expected rate-limit error")
        } catch let error as APIError {
            XCTAssertEqual(error.statusCode, 429)
        }

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testAPIErrorPreservesStructuredDetailsAndResponseMetadata() async throws {
        let body =
            #"{"error":{"message":"Unknown model","type":"invalid_request_error","code":"model_not_found","param":"model"}}"#
        let transport = RecordingTransport(send: [
            .response(jsonResponse(body, status: 404, headers: ["X-Request-ID": "req-123", "X-Trace": "trace"]))
        ])
        let client = OpenAIClient(configuration: testConfiguration(maxRetries: 2), transport: transport)

        do {
            let _: TestDocument = try await client.send(.get, path: "models/missing")
            XCTFail("Expected API error")
        } catch let error as APIError {
            XCTAssertEqual(error.statusCode, 404)
            XCTAssertEqual(error.message, "Unknown model")
            XCTAssertEqual(error.type, "invalid_request_error")
            XCTAssertEqual(error.code, .string("model_not_found"))
            XCTAssertEqual(error.param, .string("model"))
            XCTAssertEqual(error.requestID, "req-123")
            XCTAssertEqual(error.responseBody, Data(body.utf8))
        }

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testNonJSONServerFailureStillProducesAPIError() async throws {
        let transport = RecordingTransport(send: [
            .response(jsonResponse("gateway unavailable", status: 502))
        ])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)

        do {
            let _: TestDocument = try await client.send(.get, path: "models")
            XCTFail("Expected API error")
        } catch let error as APIError {
            XCTAssertEqual(error.statusCode, 502)
            XCTAssertTrue(error.message.contains("gateway unavailable"))
            XCTAssertEqual(error.responseBody, Data("gateway unavailable".utf8))
        }
    }

    func testRetriesStopAtConfiguredLimit() async throws {
        let transport = RecordingTransport(send: [
            .response(jsonResponse(#"{"error":{"message":"first"}}"#, status: 500)),
            .response(jsonResponse(#"{"error":{"message":"last"}}"#, status: 500)),
            .response(jsonResponse()),
        ])
        let client = OpenAIClient(configuration: testConfiguration(maxRetries: 1), transport: transport)

        do {
            let _: TestDocument = try await client.send(.get, path: "models")
            XCTFail("Expected final API error")
        } catch let error as APIError {
            XCTAssertEqual(error.message, "last")
        }

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
    }
}
