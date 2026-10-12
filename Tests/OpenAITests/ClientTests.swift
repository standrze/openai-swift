import Foundation
import XCTest

@testable import OpenAI

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

final class ClientTests: XCTestCase {
    func testRequestPreservesBasePathAndAppliesAuthentication() async throws {
        let transport = RecordingTransport(send: [.response(jsonResponse())])
        let configuration = ClientConfiguration(
            apiKey: "secret",
            baseURL: URL(string: "https://example.test/gateway/v1/")!,
            organization: "org-example",
            project: "proj-example",
            headers: ["X-Client": "swift"],
            timeout: 31,
            maxRetries: 0
        )
        let client = OpenAIClient(configuration: configuration, transport: transport)

        let document: TestDocument = try await client.send(.get, path: "models")

        XCTAssertEqual(document.value, "ready")
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://example.test/gateway/v1/models")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "OpenAI-Organization"), "org-example")
        XCTAssertEqual(request.value(forHTTPHeaderField: "OpenAI-Project"), "proj-example")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Client"), "swift")
        XCTAssertEqual(request.timeoutInterval, 31)
        XCTAssertNil(request.httpBody)
    }

    func testRequestOptionsOverrideHeadersTimeoutAndJSONBody() async throws {
        let transport = RecordingTransport(send: [.response(jsonResponse())])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)
        let options = RequestOptions(
            headers: ["authorization": "Bearer per-request", "X-Trace": "trace-1"],
            query: ["after": "file/a+b c", "limit": "2"],
            extraBody: [
                "value": "overridden",
                "temperature": 0.25,
                "vendor_extension": ["enabled": true],
            ],
            timeout: 9
        )

        let _: TestDocument = try await client.send(
            .post,
            path: "responses",
            body: TestDocument(value: "original"),
            options: options
        )

        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer per-request")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Trace"), "trace-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 9)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query, ["after": "file/a+b c", "limit": "2"])
        XCTAssertTrue(components.percentEncodedQuery?.contains("%2B") == true)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(object["value"] as? String, "overridden")
        XCTAssertEqual(object["temperature"] as? Double, 0.25)
        XCTAssertEqual((object["vendor_extension"] as? [String: Bool])?["enabled"], true)
    }

    func testOllamaConfigurationDoesNotAddAuthorization() async throws {
        let transport = RecordingTransport(send: [.response(jsonResponse())])
        let client = OpenAIClient(configuration: .ollama(), transport: transport)

        let _: TestDocument = try await client.send(.get, path: "models")

        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:11434/v1/models")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "OpenAI-Organization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "OpenAI-Project"))
    }

    func testRequestPreservesEncodedIdentifierAsOnePathComponent() async throws {
        let transport = RecordingTransport(send: [.response(jsonResponse())])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)

        let _: TestDocument = try await client.send(.get, path: "files/file%2Fname%20with%20spaces")

        let requests = await transport.requests
        XCTAssertEqual(
            requests.first?.url?.absoluteString,
            "https://example.test/proxy/v1/files/file%2Fname%20with%20spaces"
        )
    }

    func testRejectsPathsThatCanEscapeConfiguredEndpoint() async throws {
        let invalidPaths = [
            "../models",
            "files/../models",
            "files/%2E%2E/models",
            "https://elsewhere.test/models",
            "//elsewhere.test/models",
            "models?limit=5",
            "models#fragment",
        ]
        let transport = RecordingTransport()
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)

        for path in invalidPaths {
            do {
                let _: TestDocument = try await client.send(.get, path: path)
                XCTFail("Expected invalidPath for \(path)")
            } catch OpenAIClientError.invalidPath {
                // Every invalid path must fail before reaching the transport.
            }
        }

        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testDecodingFailureHasSDKErrorType() async throws {
        let transport = RecordingTransport(send: [.response(jsonResponse(#"{"unexpected":true}"#))])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)

        do {
            let _: TestDocument = try await client.send(.get, path: "models")
            XCTFail("Expected a decoding error")
        } catch OpenAIClientError.decoding(let message) {
            XCTAssertFalse(message.isEmpty)
        }
    }
}
