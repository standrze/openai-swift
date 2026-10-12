import Foundation
import XCTest

@testable import OpenAI

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

final class RequestDeadlineTests: XCTestCase, @unchecked Sendable {
    func testDefaultHasNoSDKDeadline() throws {
        XCTAssertEqual(ClientConfiguration.ollama().timeout, 0)
        XCTAssertNil(try RequestDeadline.end(timeout: 0, deadline: nil))
    }

    func testAuthenticationSharesInitialAttemptDeadline() async throws {
        var configuration = testConfiguration(maxRetries: 0)
        configuration.timeout = 0.03
        configuration.accessTokenProvider = {
            try await Task.sleep(for: .seconds(10))
            return "late"
        }
        let transport = RecordingTransport()
        let start = Date()
        do {
            let _: TestDocument = try await OpenAIClient(configuration: configuration, transport: transport).send(
                .get, path: "models")
            XCTFail("Expected auth timeout")
        } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testEveryRetryGetsItsOwnAttemptTimeout() async throws {
        var configuration = testConfiguration(maxRetries: 1)
        configuration.timeout = 0.03
        let transport = DeadlineTransport()
        do {
            let _: TestDocument = try await OpenAIClient(configuration: configuration, transport: transport).send(
                .get, path: "models")
            XCTFail("Expected timeout")
        } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
        let attempts = await transport.attempts
        XCTAssertEqual(attempts, 2)
    }

    func testAbsoluteDeadlineDoesNotRestartDuringRetryWait() async throws {
        var configuration = testConfiguration(maxRetries: 2)
        configuration.maxServerRetryDelay = 120
        let transport = RecordingTransport(send: [.response(jsonResponse(status: 429, headers: ["Retry-After": "1"]))])
        var options = RequestOptions()
        options.deadline = Date().addingTimeInterval(0.04)
        let start = Date()
        do {
            let _: TestDocument = try await OpenAIClient(configuration: configuration, transport: transport).send(
                .get, path: "models", options: options)
            XCTFail("Expected total deadline")
        } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testAttemptDeadlineContinuesAfterStreamHeaders() async throws {
        var configuration = testConfiguration(maxRetries: 0)
        configuration.timeout = 0.03
        let response = try await OpenAIClient(configuration: configuration, transport: DeadlineTransport()).streamBytes(
            path: "responses")
        do {
            for try await _ in response.body {}
            XCTFail("Expected body timeout")
        } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
    }
}

private actor DeadlineTransport: OpenAITransport {
    var attempts = 0
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        attempts += 1
        try await Task.sleep(for: .seconds(10))
        return HTTPResponse(data: Data(#"{"value":"late"}"#.utf8), statusCode: 200)
    }
    func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
        let pair = AsyncThrowingStream<Data, any Error>.makeStream()
        let producer = Task {
            do {
                try await Task.sleep(for: .seconds(10))
                pair.continuation.yield(Data("late".utf8))
                pair.continuation.finish()
            } catch { pair.continuation.finish(throwing: error) }
        }
        pair.continuation.onTermination = { @Sendable _ in producer.cancel() }
        return HTTPStreamResponse(statusCode: 200, body: pair.stream, cancel: { producer.cancel() })
    }
}
