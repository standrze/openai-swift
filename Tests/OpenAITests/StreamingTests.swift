import Foundation
import XCTest

@testable import OpenAI

final class StreamingTests: XCTestCase {
    func testParserHandlesFragmentedUTF8BOMAndAllLineEndings() throws {
        let wire =
            "\u{FEFF}: keepalive\r\ndata: {\"value\":\"café 🌙\"}\r\n\r\n"
            + "data: second\r\rdata: third\n\n"
        var parser = SSEParser()
        var events: [ServerSentEvent] = []

        for byte in wire.utf8 {
            events += try parser.append(Data([byte]))
        }
        events += try parser.finish()

        XCTAssertEqual(events.map(\.data), [#"{"value":"café 🌙"}"#, "second", "third"])
    }

    func testParserCombinesMultilineDataAndReadsEventMetadata() throws {
        var parser = SSEParser()
        let events = try parser.append(
            Data(
                """
                : ignored comment
                event: response.output_text.delta
                id: event-7
                retry: 250
                unknown: ignored
                data: first line
                data: second line


                """.utf8))

        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.data, "first line\nsecond line")
        XCTAssertEqual(event.event, "response.output_text.delta")
        XCTAssertEqual(event.id, "event-7")
        XCTAssertEqual(event.retry, 250)
    }

    func testParserIgnoresFramesWithoutDataAndAllowsEmptyData() throws {
        var parser = SSEParser()
        let events = try parser.append(Data(": ping\n\nevent: ignored\n\ndata:\n\n".utf8))

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.data, "")
    }

    func testParserEnforcesMaximumEventSize() throws {
        var parser = SSEParser(maxEventBytes: 16)

        XCTAssertThrowsError(try parser.append(Data(("data: " + String(repeating: "x", count: 100)).utf8))) {
            guard case OpenAIClientError.streamEventTooLarge = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
    }

    func testParserRejectsTruncatedEventAtEndOfConnection() throws {
        var parser = SSEParser()
        XCTAssertTrue(try parser.append(Data("data: partial\n".utf8)).isEmpty)

        XCTAssertThrowsError(try parser.finish()) {
            guard case OpenAIClientError.invalidStream = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
    }

    func testParserRejectsInvalidUTF8InsteadOfReplacingBytes() throws {
        var parser = SSEParser()
        let bytes = Array("data: ".utf8) + [0xC3, 0x28, 10, 10]

        XCTAssertThrowsError(try parser.append(Data(bytes))) {
            guard case OpenAIClientError.invalidStream = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
    }

    func testClientDecodesEventsAndStopsAtDoneMarker() async throws {
        let wire =
            "data: {\"value\":\"one\"}\n\ndata: {\"value\":\"two\"}\n\n"
            + "data: [DONE]\n\ndata: {\"value\":\"ignored\"}\n\n"
        let transport = RecordingTransport(stream: [.response(streamResponse(text: wire))])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)

        let stream: OpenAIStream<TestDocument> = try await client.stream(
            path: "chat/completions",
            body: TestDocument(value: "request"),
            options: RequestOptions(extraBody: ["stream": true])
        )
        var values: [String] = []
        for try await event in stream {
            values.append(event.value)
        }

        XCTAssertEqual(values, ["one", "two"])
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(object["stream"] as? Bool, true)
    }

    func testClientDecodesEventsAcrossArbitraryByteBoundaries() async throws {
        let wire = "data: {\"value\":\"café 🌙\"}\r\n\r\ndata: [DONE]\r\n\r\n"
        let chunks = wire.utf8.map { Data([$0]) }
        let transport = RecordingTransport(stream: [.response(streamResponse(chunks: chunks))])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)

        let stream: OpenAIStream<TestDocument> = try await client.stream(
            path: "chat/completions",
            body: TestDocument(value: "request")
        )
        var documents: [TestDocument] = []
        for try await event in stream {
            documents.append(event)
        }

        XCTAssertEqual(documents, [TestDocument(value: "café 🌙")])
    }

    func testMalformedEventFailsWithDecodingError() async throws {
        let transport = RecordingTransport(stream: [.response(streamResponse(text: "data: {bad-json}\n\n"))])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)
        let stream: OpenAIStream<TestDocument> = try await client.stream(
            path: "responses",
            body: TestDocument(value: "request")
        )

        do {
            for try await _ in stream {}
            XCTFail("Expected malformed event to fail")
        } catch OpenAIClientError.decoding(let message) {
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testErrorEnvelopeInsideSuccessfulStreamProducesAPIError() async throws {
        let wire =
            "event: error\ndata: {\"error\":{\"message\":\"generation failed\","
            + "\"type\":\"server_error\",\"code\":\"failed\"}}\n\n"
        let transport = RecordingTransport(stream: [
            .response(streamResponse(text: wire, headers: ["x-request-id": "req-stream"]))
        ])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)
        let stream: OpenAIStream<TestDocument> = try await client.stream(
            path: "responses",
            body: TestDocument(value: "request")
        )

        do {
            for try await _ in stream {}
            XCTFail("Expected an API error from the event")
        } catch let error as APIError {
            XCTAssertEqual(error.message, "generation failed")
            XCTAssertEqual(error.type, "server_error")
            XCTAssertEqual(error.code, .string("failed"))
            XCTAssertEqual(error.requestID, "req-stream")
        }
    }

    func testStreamHTTPFailureUsesStructuredAPIError() async throws {
        let transport = RecordingTransport(stream: [
            .response(
                streamResponse(
                    text: #"{"error":{"message":"not authorized","type":"authentication_error"}}"#,
                    status: 401,
                    headers: ["Content-Type": "application/json", "x-request-id": "req-auth"]
                ))
        ])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)

        do {
            let _: OpenAIStream<TestDocument> = try await client.stream(
                path: "responses",
                body: TestDocument(value: "request")
            )
            XCTFail("Expected streaming request to reject an HTTP failure")
        } catch let error as APIError {
            XCTAssertEqual(error.statusCode, 401)
            XCTAssertEqual(error.message, "not authorized")
            XCTAssertEqual(error.requestID, "req-auth")
        }
    }

    func testExplicitCancellationReleasesUnderlyingTransportOnce() async throws {
        let cancellation = CancellationRecorder()
        let response = HTTPStreamResponse(
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            body: AsyncThrowingStream { _ in },
            cancel: { cancellation.record() }
        )
        let transport = RecordingTransport(stream: [.response(response)])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)
        let stream: OpenAIStream<TestDocument> = try await client.stream(
            path: "responses",
            body: TestDocument(value: "request")
        )

        stream.cancel()
        stream.cancel()

        XCTAssertEqual(cancellation.count, 1)
    }

    func testStreamTransportFailureAfterAnEventIsPropagated() async throws {
        let response = HTTPStreamResponse(
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            body: AsyncThrowingStream { continuation in
                continuation.yield(Data("data: {\"value\":\"first\"}\n\n".utf8))
                continuation.finish(throwing: URLError(.networkConnectionLost))
            }
        )
        let transport = RecordingTransport(stream: [.response(response)])
        let client = OpenAIClient(configuration: testConfiguration(maxRetries: 2), transport: transport)
        let stream: OpenAIStream<TestDocument> = try await client.stream(
            path: "responses",
            body: TestDocument(value: "request")
        )
        var values: [String] = []

        do {
            for try await event in stream {
                values.append(event.value)
            }
            XCTFail("Expected transport failure")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }

        XCTAssertEqual(values, ["first"])
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1, "A stream must not be replayed after delivering events")
    }
}
