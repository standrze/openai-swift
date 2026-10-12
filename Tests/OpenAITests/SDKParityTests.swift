import Foundation
import XCTest

@testable import OpenAI

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

final class SDKParityTests: XCTestCase, @unchecked Sendable {
    func testFinalOriginIsCheckedAfterMiddlewareAndSigning() async throws {
        let transport = RecordingTransport(send: [.response(jsonResponse())])
        var configuration = testConfiguration()
        configuration.prepareAttempt = { request, _ in
            var changed = request
            changed.url = URL(string: "https://other.test/v1/models")!
            return changed
        }
        do {
            let _: TestDocument = try await OpenAIClient(configuration: configuration, transport: transport)
                .send(.get, path: "models")
            XCTFail("Changed origin must be rejected before dispatch")
        } catch OpenAIClientError.invalidConfiguration {}
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testExactJSONMetadataAndUnknownFields() throws {
        let document = try JSONDocument(
            data: Data(
                #"{"number":9007199254740993123456,"nil":null,"nested":{"a.b":[1e+999,"x\\\"y"]},"dup":1,"dup":2}"#.utf8
            ))
        XCTAssertEqual(document.field(at: [.key("number")]).rawString, "9007199254740993123456")
        XCTAssertEqual(document.field(at: [.key("nil")]).presence, .null)
        XCTAssertEqual(document.field(at: [.key("absent")]).presence, .missing)
        XCTAssertEqual(document.field(at: [.key("nested"), .key("a.b"), .index(0)]).rawString, "1e+999")
        XCTAssertEqual(document.field(at: [.key("dup")]).rawString, "2")
        XCTAssertEqual(try document.extraFields(knownKeys: ["number", "nil", "nested"]).keys.sorted(), ["dup"])
    }

    func testRejectsInvalidJSONWithoutCrashing() {
        for value in ["", "[1,]", "{\"x\":}", "true false", "01", "--2", "1e", "{\"a\":1,}", "\"x\n\"", "["] {
            XCTAssertThrowsError(try JSONDocument(data: Data(value.utf8)), value)
        }
    }

    func testNestedMutationAndTypedResponseMetadata() async throws {
        let transport = RecordingTransport(send: [.response(jsonResponse(headers: ["x-request-id": "req-1"]))])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)
        var options = RequestOptions(extraBody: ["null": .null])
        options.jsonMutations = [
            .set([.key("nested"), .key("a.b")], [1, 2, 3]),
            .delete([.key("nested"), .key("a.b"), .index(1)]), .delete([.key("remove")]),
        ]
        let overrides = options
        let result = try await client.withResponse { scoped in
            let value: TestDocument = try await scoped.send(
                .post, path: "custom", body: ["remove": true], options: overrides)
            return value
        }
        XCTAssertEqual(result.value.value, "ready")
        XCTAssertEqual(result.response.header("X-Request-ID"), "req-1")
        XCTAssertEqual(try result.document.field(at: [.key("value")]).decode(String.self), "ready")
        let requests = await transport.requests
        let body = try JSONDecoder().decode(JSONValue.self, from: requests[0].httpBody!)
        XCTAssertNil(body["remove"])
        XCTAssertEqual(body["nested"]?["a.b"], [1, 3])
        XCTAssertEqual(body["null"], .null)
    }

    func testParameterOmissionAndNull() throws {
        struct Parameters: Encodable {
            enum CodingKeys: String, CodingKey { case omitted, null, value, override }
            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(JSONParameter<String>.omitted, forKey: .omitted)
                try container.encode(JSONParameter<String>.null, forKey: .null)
                try container.encode(JSONParameter.value("typed"), forKey: .value)
                try container.encode(JSONParameter<String>.override(["vendor": true]), forKey: .override)
            }
        }
        let body = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(Parameters()))
        XCTAssertNil(body["omitted"])
        XCTAssertEqual(body["null"], .null)
        XCTAssertEqual(body["value"], "typed")
        XCTAssertEqual(body["override"], ["vendor": true])
    }

    func testMiddlewareOrderAndSigningOnEveryAttempt() async throws {
        let log = MiddlewareLog()
        var config = testConfiguration(maxRetries: 1)
        config.middleware = [TraceMiddleware(id: "client", log: log)]
        config.prepareAttempt = { request, attempt in
            var request = request
            request.setValue(String(attempt), forHTTPHeaderField: "attempt")
            return request
        }
        let transport = RecordingTransport(send: [.response(jsonResponse(status: 503)), .response(jsonResponse())])
        var options = RequestOptions()
        options.middleware = [TraceMiddleware(id: "request", log: log)]
        let _: TestDocument = try await OpenAIClient(configuration: config, transport: transport).send(
            .get, path: "models", options: options)
        let values = await log.values
        XCTAssertEqual(
            values,
            [
                "client-in", "request-in", "request-out", "client-out", "client-in", "request-in", "request-out",
                "client-out",
            ])
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "attempt") }, ["0", "1"])
    }

    func testUnauthorizedRefreshAndExplicitHeaderIsolation() async throws {
        let issuer = RecordingTransport(send: [
            .response(jsonResponse(#"{"access_token":"old","token_type":"Bearer","expires_in":3600}"#)),
            .response(jsonResponse(#"{"access_token":"fresh","token_type":"Bearer","expires_in":3600}"#)),
        ])
        let provider = try OAuthTokenProvider(
            configuration: OAuthConfiguration(
                tokenURL: URL(string: "https://issuer.test/token")!,
                grant: .clientCredentials(clientID: "id", clientSecret: "secret")), transport: issuer)
        var config = testConfiguration(maxRetries: 1)
        config.authenticate(using: provider)
        let transport = RecordingTransport(send: [.response(jsonResponse(status: 401)), .response(jsonResponse())])
        let _: TestDocument = try await OpenAIClient(configuration: config, transport: transport).send(
            .get, path: "models")
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer old", "Bearer fresh"])
        let invalidated = await provider.invalidate(ifToken: "old")
        XCTAssertTrue(invalidated)
        let fresh = try await provider.accessToken()
        XCTAssertEqual(fresh, "fresh")
    }

    func testKubernetesTokenRotation() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let acquire = CloudSubjectTokens.kubernetes(fileURL: url)
        try Data(" first\n".utf8).write(to: url)
        let first = try await acquire()
        XCTAssertEqual(first, "first")
        try Data("second".utf8).write(to: url)
        let second = try await acquire()
        XCTAssertEqual(second, "second")
        try Data().write(to: url)
        do {
            _ = try await acquire()
            XCTFail("Empty projected token accepted")
        } catch {}
    }

    func testAzureMultipartRoutingUsesModelFieldAndDeploymentMapping() async throws {
        let transport = RecordingTransport(send: [.response(jsonResponse())])
        let client = try AzureOpenAI.client(
            endpoint: URL(string: "https://azure.test")!, apiVersion: "version", apiKey: "fixture",
            deployment: { "deployment-" + $0 }, transport: transport)
        _ = try await client.uploadResponse(
            path: "audio/transcriptions", fields: ["model": "whisper"],
            files: [MultipartFile(fieldName: "file", filename: "a.wav", data: Data([0, 255, 42]))])
        let requests = await transport.requests
        XCTAssertEqual(requests[0].url?.path, "/openai/deployments/deployment-whisper/audio/transcriptions")
        XCTAssertTrue(requests[0].value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data") == true)
    }

    func testAzureRoutingAndCredentialIsolation() async throws {
        let transport = RecordingTransport(send: [.response(jsonResponse())])
        let client = try AzureOpenAI.client(
            endpoint: URL(string: "https://azure.test")!, apiVersion: "2024-10-21",
            apiKey: "azure-key", deployment: { _ in "my deployment" }, transport: transport)
        let _: TestDocument = try await client.send(.post, path: "chat/completions", body: ["model": "model"])
        let requests = await transport.requests
        XCTAssertEqual(
            requests[0].url?.absoluteString,
            "https://azure.test/openai/deployments/my%20deployment/chat/completions?api-version=2024-10-21")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "api-key"), "azure-key")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "OpenAI-Organization"))
    }

    func testAzureEscapedPrefixAndNonInferenceRoutes() async throws {
        let transport = RecordingTransport(send: [.response(jsonResponse()), .response(jsonResponse())])
        let client = try AzureOpenAI.client(
            endpoint: URL(string: "https://azure.test/chat/completions/base%20prefix")!, apiVersion: "version",
            apiKey: "key", deployment: { _ in "deployment/name" }, transport: transport)
        let _: TestDocument = try await client.send(.post, path: "embeddings", body: ["model": "model"])
        let _: TestDocument = try await client.send(.get, path: "models")
        let requests = await transport.requests
        XCTAssertEqual(
            requests[0].url?.absoluteString,
            "https://azure.test/chat/completions/base%20prefix/openai/deployments/deployment%2Fname/embeddings?api-version=version"
        )
        XCTAssertEqual(
            requests[1].url?.absoluteString,
            "https://azure.test/chat/completions/base%20prefix/openai/models?api-version=version")
    }

    func testDetailedResponseAccumulation() throws {
        var accumulator = ResponseAccumulator()
        for json in [
            #"{"type":"response.created","response":{"id":"r","output":[],"vendor":{"field":true}}}"#,
            #"{"type":"response.custom_tool_call_input.delta","output_index":2,"item_id":"c","delta":"hello"}"#,
            #"{"type":"response.custom_tool_call_input.done","output_index":2,"item_id":"c","input":"authoritative"}"#,
            #"{"type":"response.output_text.delta","output_index":4,"content_index":0,"item_id":"m","delta":"text","logprobs":[{"token":"text"}]}"#,
            #"{"type":"response.output_text.annotation.added","output_index":4,"content_index":0,"annotation_index":3,"annotation":{"type":"url_citation","url":"https://example.test"}}"#,
        ] { try accumulator.add(JSONDecoder().decode(ResponseEvent.self, from: Data(json.utf8))) }
        let snapshot = accumulator.snapshot
        XCTAssertEqual(snapshot.rawValue["vendor"], ["field": true])
        XCTAssertEqual(snapshot.output.first?.rawValue["input"], "authoritative")
        XCTAssertEqual(snapshot.output.last?.content.first?.rawValue["logprobs"]?.arrayValue?.count, 1)
        XCTAssertEqual(snapshot.output.last?.content.first?.annotations?.count, 1)
        accumulator.reset()
        XCTAssertEqual(snapshot.outputText, "text")
        XCTAssertTrue(accumulator.snapshot.output.isEmpty)
    }
}

private actor MiddlewareLog {
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
}
private struct TraceMiddleware: ClientMiddleware {
    let id: String
    let log: MiddlewareLog
    func send(_ request: URLRequest, next: any OpenAITransport) async throws -> HTTPResponse {
        await log.append(id + "-in")
        let response = try await next.send(request)
        await log.append(id + "-out")
        return response
    }
}
