import Foundation
import XCTest

@testable import OpenAI

final class OllamaCompatibilityTests: XCTestCase {
    func testRawModelRequestsPreservePrefixOptionsAndUnknownMetadata() async throws {
        for rawBytes in [false, true] {
            let transport = RecordingTransport(send: [
                .response(jsonResponse("404 page not found", status: 404)),
                .response(
                    jsonResponse(
                        #"{"data":[{"id":"org/model:latest","vendor":{"revision":9007199254740993}}]}"#,
                        headers: ["Content-Length": "1000", "ETag": "list-only", "X-Request-ID": "listing"])),
            ])
            let configuration = ClientConfiguration.ollama(
                baseURL: URL(string: "https://example.test/proxy%20name/v1")!)
            let client = OpenAIClient(configuration: configuration, transport: transport)
            let options = RequestOptions(headers: ["X-Trace": "raw"], query: ["literal": "a+b"])
            let path = "models/" + OpenAIClient.pathComponent("org/model:latest")
            let response =
                try await
                (rawBytes
                ? client.request(.get, path: path, options: options)
                : client.download(path: path, options: options))
            let value = try OpenAIJSON.decode(JSONValue.self, from: response.data)
            XCTAssertEqual(value["id"]?.stringValue, "org/model:latest")
            XCTAssertTrue(String(decoding: response.data, as: UTF8.self).contains("9007199254740993"))
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.header("Content-Length"), String(response.data.count))
            XCTAssertNil(response.header("ETag"))
            XCTAssertEqual(response.header("X-Request-ID"), "listing")
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 2)
            XCTAssertEqual(requests[1].url?.absoluteString, "https://example.test/proxy%20name/v1/models?literal=a%2Bb")
            XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Trace") == "raw" })
        }
    }

    func testRawStreamFallbackReleasesBothConnectionsAndPreservesMissing404() async throws {
        for found in [false, true] {
            let cancellations = CancellationRecorder()
            let original = #"{"error":{"message":"original"}}"#
            let listing = found ? #"{"data":[{"id":"org/model:latest"}]}"# : #"{"data":[]}"#
            let transport = RecordingTransport(stream: [
                .response(streamResponse(text: original, status: 404, cancel: { cancellations.record() })),
                .response(streamResponse(text: listing, cancel: { cancellations.record() })),
            ])
            let client = OpenAIClient(configuration: .ollama(), transport: transport)
            do {
                let response = try await client.streamBytes(path: "models/org%2Fmodel%3Alatest")
                defer { response.cancel() }
                var data = Data()
                for try await chunk in response.body { data.append(chunk) }
                XCTAssertTrue(found)
                XCTAssertEqual(try OpenAIJSON.decode(OpenAIModel.self, from: data).id, "org/model:latest")
            } catch let error as APIError {
                XCTAssertFalse(found)
                XCTAssertEqual(error.message, "original")
                XCTAssertEqual(error.statusCode, 404)
            }
            XCTAssertEqual(cancellations.count, 2)
        }
    }

    func testRawFallbackDoesNotInterceptOtherRoutesMethodsBodiesOrFailedListings() async throws {
        for (method, path, body, listing) in [
            (HTTPMethod.delete, "models/org%2Fmodel", nil as Data?, nil as String?),
            (.get, "models/org/model", nil, nil),
            (.get, "files/org%2Fmodel", nil, nil),
            (.get, "models/org%2Fmodel", Data("body".utf8), nil),
            (.get, "models/org%2Fmodel", nil, "invalid JSON"),
        ] {
            var responses: [RecordingTransport.SendOutcome] = [
                .response(jsonResponse(#"{"error":{"message":"original"}}"#, status: 404))
            ]
            if let listing { responses.append(.response(jsonResponse(listing))) }
            let transport = RecordingTransport(send: responses)
            let client = OpenAIClient(configuration: .ollama(), transport: transport)
            do {
                _ = try await client.request(method, path: path, data: body)
                XCTFail("Expected original error")
            } catch let error as APIError {
                XCTAssertEqual(error.message, "original")
            }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, listing == nil ? 1 : 2)
        }
    }

    func testNamespacedModel404FallsBackToAdvertisedMetadataOnlyForOllama() async throws {
        let transport = RecordingTransport(send: [
            .response(jsonResponse("404 page not found", status: 404)),
            .response(jsonResponse(#"{"object":"list","data":[{"id":"org/model:latest","owned_by":"org"}]}"#)),
        ])
        let client = OpenAIClient(configuration: .ollama(), transport: transport)
        let model = try await client.models.retrieve("org/model:latest", options: .init(headers: ["X-Trace": "live"]))
        XCTAssertEqual(model.id, "org/model:latest")
        XCTAssertEqual(model.ownedBy, "org")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[0].url!.absoluteString.contains("org%2Fmodel%3Alatest"))
        XCTAssertEqual(requests[1].url?.path, "/v1/models")
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Trace") == "live" })
    }

    func testModelFallbackDoesNotMaskUnknownIDsOrOtherErrors() async throws {
        for (ollama, id, status, listing) in [
            (false, "org/model:latest", 404, false),
            (true, "missing:latest", 404, false),
            (true, "org/model:latest", 403, false),
            (true, "org/model:latest", 404, true),
        ] {
            var responses: [RecordingTransport.SendOutcome] = [
                .response(jsonResponse(#"{"error":{"message":"original failure"}}"#, status: status))
            ]
            if listing { responses.append(.response(jsonResponse(#"{"data":[{"id":"other/model:latest"}]}"#))) }
            let transport = RecordingTransport(send: responses)
            let configuration = ollama ? ClientConfiguration.ollama() : testConfiguration()
            let client = OpenAIClient(configuration: configuration, transport: transport)
            do {
                _ = try await client.models.retrieve(id)
                XCTFail("Original model error must be preserved")
            } catch let error as APIError {
                XCTAssertEqual(error.statusCode, status)
                XCTAssertEqual(error.message, "original failure")
            }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, listing ? 2 : 1)
        }
    }
}
