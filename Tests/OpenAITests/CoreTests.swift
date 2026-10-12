import Foundation
import XCTest

@testable import OpenAI

final class CoreTests: XCTestCase {
    func testRawResponsesAcceptBinaryWhileJSONOperationsAndExplicitHeadersKeepTheirMediaTypes() async throws {
        let transport = RecordingTransport(
            send: (0..<6).map { _ in .response(jsonResponse()) },
            stream: [.response(streamResponse(chunks: [Data([0, 255])]))])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)
        let _: TestDocument = try await client.send(.get, path: "models")
        _ = try await client.download(.post, path: "audio/speech", body: JSONValue.object([:]))
        _ = try await client.request(.post, path: "realtime/calls", data: Data(), contentType: "application/sdp")
        _ = try await client.uploadResponse(path: "realtime/calls", fields: ["sdp": "v=0"], files: [])
        let _: TestDocument = try await client.upload(path: "files", fields: [MultipartField](), files: [])
        _ = try await client.download(path: "recording", options: .init(headers: ["accept": "audio/wav"]))
        let stream = try await client.streamBytes(path: "recording")
        defer { stream.cancel() }

        let requests = await transport.requests
        XCTAssertEqual(
            requests.map { $0.value(forHTTPHeaderField: "Accept") },
            ["application/json", "*/*", "*/*", "*/*", "application/json", "audio/wav", "*/*"])
    }

    func testPaginationIsLazyAndPreservesFiltersAcrossPages() async throws {
        let transport = RecordingTransport(send: [
            .response(jsonResponse(#"{"data":[{"id":"one"},{"id":"two"}],"has_more":true,"last_id":"two"}"#)),
            .response(jsonResponse(#"{"data":[{"id":"three"}],"has_more":false}"#)),
        ])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)
        let items = client.filesResource.all(options: RequestOptions(query: ["purpose": "batch", "limit": "2"]))
        let before = await transport.requests
        XCTAssertTrue(before.isEmpty)
        var ids: [String] = []
        for try await item in items { ids.append(try XCTUnwrap(item["id"]?.stringValue)) }
        XCTAssertEqual(ids, ["one", "two", "three"])
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        let query = URLComponents(url: try XCTUnwrap(requests.last?.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertTrue(query?.contains(URLQueryItem(name: "purpose", value: "batch")) == true)
        XCTAssertTrue(query?.contains(URLQueryItem(name: "after", value: "two")) == true)
    }

    func testRepeatedPaginationCursorFailsInsteadOfLooping() async throws {
        let page = #"{"data":[{"id":"one"}],"has_more":true,"last_id":"one"}"#
        let transport = RecordingTransport(send: [.response(jsonResponse(page)), .response(jsonResponse(page))])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)
        var iterator = client.resource("files").all().makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first?["id"], "one")
        do {
            _ = try await iterator.next()
            XCTFail("Expected repeated cursor error")
        } catch OpenAIClientError.pagination {}
    }

    func testNestedResourceEscapesIdentifiersAndSendsActionBody() async throws {
        let transport = RecordingTransport(send: [.response(jsonResponse("{}"))])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)
        _ = try await client.vectorStores.fileBatches("vs/a?b").action("batch#one", "cancel")
        let requests = await transport.requests
        XCTAssertEqual(
            requests.first?.url?.absoluteString,
            "https://example.test/proxy/v1/vector_stores/vs%2Fa%3Fb/file_batches/batch%23one/cancel")
    }

    func testServerCanDisableRetriesForRetryableStatus() async throws {
        let transport = RecordingTransport(send: [
            .response(
                jsonResponse(
                    #"{"error":{"message":"do not retry"}}"#, status: 503, headers: ["x-should-retry": "false"]))
        ])
        let client = OpenAIClient(configuration: testConfiguration(maxRetries: 2), transport: transport)
        do {
            let _: JSONValue = try await client.send(.get, path: "models")
            XCTFail("Expected HTTP error")
        } catch let error as APIError { XCTAssertEqual(error.statusCode, 503) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testEmptySuccessCanBeConsumedWithoutInventedJSONObject() async throws {
        let transport = RecordingTransport(send: [.response(HTTPResponse(data: Data(), statusCode: 204))])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)
        let value: JSONValue = try await client.send(.delete, path: "responses/response-id")
        XCTAssertEqual(value, .null)
    }

    func testJSONRoundTripKeepsIntegerFalseAndExplicitNull() throws {
        let value: JSONValue = ["n": .integer(9_007_199_254_740_993), "enabled": false, "value": nil]
        let roundTrip = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(value, roundTrip)
        XCTAssertEqual(roundTrip["n"]?.intValue, 9_007_199_254_740_993)
    }

    func testMultipartRejectsHeaderInjectionBeforeNetworkRequest() async throws {
        let transport = RecordingTransport()
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)
        do {
            let _: JSONValue = try await client.upload(
                path: "files", fields: [:],
                files: [MultipartFile(fieldName: "file", filename: "bad\r\nX-Secret: value", data: Data())]
            )
            XCTFail("Expected invalid multipart name")
        } catch OpenAIClientError.invalidConfiguration {}
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testBoundedStreamFailsInsteadOfDroppingUnreadEvents() async throws {
        let wire = (0..<4).map { "data: {\"value\":\"\($0)\"}\n\n" }.joined()
        let transport = RecordingTransport(stream: [.response(streamResponse(text: wire))])
        var configuration = testConfiguration()
        configuration.maxBufferedEvents = 1
        let client = OpenAIClient(configuration: configuration, transport: transport)
        let stream: OpenAIStream<TestDocument> = try await client.stream(path: "events", body: JSONValue.object([:]))
        defer { stream.cancel() }
        // Let the producer fill the bounded buffer before beginning consumption.
        try await Task.sleep(for: .milliseconds(20))
        do {
            for try await _ in stream {}
            XCTFail("Expected event overflow")
        } catch OpenAIClientError.streamOverflow {}
    }

    func testNullableErrorFieldDoesNotTurnEventIntoFailure() async throws {
        let transport = RecordingTransport(stream: [
            .response(streamResponse(text: "data: {\"error\":null,\"value\":\"ok\"}\n\ndata: [DONE]\n\n"))
        ])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)
        let stream: OpenAIStream<TestDocument> = try await client.stream(path: "events", body: JSONValue.object([:]))
        var values: [String] = []
        for try await event in stream { values.append(event.value) }
        XCTAssertEqual(values, ["ok"])
    }

    func testModelStreamEOFWithoutTerminalEventFails() async throws {
        let event =
            #"{"object":"chat.completion.chunk","id":"one","choices":[{"index":0,"delta":{"content":"partial"}}]}"#
        let transport = RecordingTransport(stream: [.response(streamResponse(text: "data: \(event)\n\n"))])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)
        let stream: OpenAIStream<JSONValue> = try await client.stream(
            path: "chat/completions", body: JSONValue.object([:]))
        do {
            for try await _ in stream {}
            XCTFail("Expected premature EOF")
        } catch OpenAIClientError.invalidStream {}
    }
}

extension OpenAIClient {
    fileprivate var filesResource: APIResource { resource("files") }
}
