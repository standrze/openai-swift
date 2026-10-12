import Foundation
import XCTest

@testable import OpenAI

final class RequestMutationTests: XCTestCase, @unchecked Sendable {
    func testHeaderQueryAndBodyReplacementAreAppliedOnEachAttempt() async throws {
        var configuration = testConfiguration(maxRetries: 1)
        configuration.headers["X-Delete"] = "default"
        configuration.accessTokenProvider = {
            XCTFail("Deleted auth must bypass acquisition")
            return "wrong"
        }
        let transport = RecordingTransport(send: [.response(jsonResponse(status: 503)), .response(jsonResponse())])
        var options = RequestOptions(query: ["remove": "original", "repeat": "first"])
        options.headerMutations = [
            .delete("Authorization"), .delete("X-Delete"), .set("X-Repeat", "first"), .add("X-Repeat", "second"),
        ]
        options.queryMutations = [.delete("remove"), .add("repeat", "second"), .set("literal", "a+b c")]
        options.bodyOverride = RequestBodyOverride(contentType: "application/octet-stream", data: Data([0, 255, 3]))
        options.baseURL = URL(string: "https://other.test/custom")!
        let _: TestDocument = try await OpenAIClient(configuration: configuration, transport: transport).send(
            .post, path: "resource", body: ["ignored": true], options: options)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.httpBody, Data([0, 255, 3]))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Repeat"), "first,second")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Delete"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.url?.host, "other.test")
            XCTAssertEqual(request.url?.path, "/custom/resource")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(query.filter { $0.name == "repeat" }.map(\.value), ["first", "second"])
            XCTAssertFalse(query.contains { $0.name == "remove" })
            XCTAssertEqual(query.first { $0.name == "literal" }?.value, "a+b c")
        }
    }

    func testInvalidHeaderMutationIsRejectedBeforeTransport() async throws {
        let transport = RecordingTransport()
        var options = RequestOptions()
        options.headerMutations = [.add("x-header", "value\r\nInjected: true")]
        do {
            let _: TestDocument = try await OpenAIClient(configuration: testConfiguration(), transport: transport).send(
                .get, path: "models", options: options)
            XCTFail("Expected invalid header")
        } catch let error as OpenAIClientError {
            guard case .invalidConfiguration = error else { return XCTFail("Wrong error") }
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testServerDirectedRetryLimitsPreserveOriginalFailure() async throws {
        var configuration = testConfiguration(maxRetries: 2)
        configuration.maxServerRetryDelay = 120
        let transport = RecordingTransport(send: [.response(jsonResponse(status: 429, headers: ["Retry-After": "121"]))]
        )
        do {
            let _: TestDocument = try await OpenAIClient(configuration: configuration, transport: transport).send(
                .get, path: "models")
            XCTFail("Expected original failure")
        } catch let error as APIError { XCTAssertEqual(error.statusCode, 429) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        let decision = try HTTPRetryPolicy.decision(
            attempt: 0, headers: ["Retry-After": "90"], configuration: configuration)
        XCTAssertTrue(decision.shouldRetry)
        XCTAssertEqual(decision.delay, 90)
        let capped = try HTTPRetryPolicy.decision(
            attempt: 0, headers: ["Retry-After": "2"], configuration: configuration, maxDelay: 1)
        XCTAssertFalse(capped.shouldRetry)
        let fallback = try HTTPRetryPolicy.decision(
            attempt: 0, headers: ["Retry-After-Ms": "nan", "Retry-After": "0.1"], configuration: configuration)
        XCTAssertEqual(fallback.delay, 0.1)
    }
}
