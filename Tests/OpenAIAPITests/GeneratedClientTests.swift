import Foundation
import HTTPTypes
import OpenAI
import OpenAIAPI
import OpenAPIRuntime
import XCTest

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

final class GeneratedClientTests: XCTestCase, @unchecked Sendable {
    func testGeneratedMiddlewareCannotChangeOriginOrAuthority() async throws {
        for authority in [false, true] {
            let transport = GeneratedTransport()
            let client = try Client(
                openAIConfiguration: .ollama(), transport: transport,
                middlewares: [ChangedOriginMiddleware(authority: authority)])
            do {
                _ = try await client.listModels(.init())
                XCTFail("Changed origin must be rejected")
            } catch let error as OpenAPIRuntime.ClientError {
                guard case OpenAIClientError.invalidConfiguration = error.underlyingError else { throw error }
            }
            let requests = await transport.requests
            XCTAssertTrue(requests.isEmpty)
        }
    }

    func testFacadeAdapterPreservesEscapedPrefixAndResponseLifecycle() async throws {
        let transport = AdapterFixture()
        let client = try Client(
            openAIConfiguration: .ollama(baseURL: URL(string: "https://example.test/proxy%20name/v1")!),
            transport: FacadeTransportAdapter(transport), requestOptions: .init(query: ["literal": "a+b"]))
        let result = try await client.listModels(.init())
        XCTAssertEqual(try result.ok.body.json.data.first?.id, "adapter-model")
        let requests = await transport.requests
        XCTAssertEqual(requests.first?.url?.absoluteString, "https://example.test/proxy%20name/v1/models?literal=a%2Bb")
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertGreaterThan(transport.cancellations.value, 0)
    }

    func testGeneratedAdminCredentialSelection() async throws {
        let transport = GeneratedTransport()
        var configuration = ClientConfiguration.ollama()
        configuration.apiKey = "ordinary"
        configuration.adminAPIKey = "admin"
        let client = try Client(openAIConfiguration: configuration, transport: transport)
        _ = try await client.listUsers(.init())
        let requests = await transport.requests
        XCTAssertEqual(requests.first?.headerFields[.authorization], "Bearer admin")
    }

    func testGeneratedRequestMutationsReplaceHeadersQueryAndBody() async throws {
        let transport = GeneratedTransport()
        var configuration = ClientConfiguration.ollama()
        configuration.headers["X-Delete"] = "default"
        configuration.accessTokenProvider = {
            XCTFail("Deleted auth must bypass acquisition")
            return "wrong"
        }
        var options = RequestOptions(query: ["remove": "value"])
        options.headerMutations = [
            .delete("Authorization"), .delete("X-Delete"), .set("X-Values", "one"), .add("X-Values", "two"),
        ]
        options.queryMutations = [.delete("remove"), .add("repeat", "one"), .add("repeat", "two")]
        options.bodyOverride = RequestBodyOverride(contentType: "application/custom", data: Data([0, 255]))
        let client = try Client(openAIConfiguration: configuration, transport: transport, requestOptions: options)
        _ = try await client.listModels(.init())
        let requests = await transport.requests
        let bodies = await transport.bodies
        XCTAssertNil(requests[0].headerFields[.authorization])
        XCTAssertNil(requests[0].headerFields[HTTPField.Name("X-Delete")!])
        XCTAssertEqual(requests[0].path, "/models?repeat=one&repeat=two")
        XCTAssertEqual(requests[0].headerFields[.contentType], "application/custom")
        XCTAssertEqual(bodies[0], Data([0, 255]))
    }

    func testGeneratedAttemptDeadlineIncludesResponseBody() async throws {
        var configuration = ClientConfiguration.ollama()
        configuration.timeout = 0.03
        configuration.maxRetries = 0
        let client = try Client(openAIConfiguration: configuration, transport: SlowGeneratedBody())
        do {
            _ = try await client.listModels(.init())
            XCTFail("Expected body timeout")
        } catch let error as OpenAPIRuntime.ClientError {
            XCTAssertEqual((error.underlyingError as? URLError)?.code, .timedOut)
        }
    }

    func testModelsTypedDecodeAndProviderIsolation() async throws {
        let transport = GeneratedTransport()
        let client = try Client(openAIConfiguration: .ollama(), transport: transport)
        let result = try await client.listModels(.init())
        let models = try result.ok.body.json
        XCTAssertEqual(models.data.first?.id, "model-1")
        let requests = await transport.requests
        XCTAssertNil(requests.first?.headerFields[.authorization])
        XCTAssertNil(requests.first?.headerFields[HTTPField.Name("OpenAI-Organization")!])
    }

    func testHeadersTokenProviderAndRetry() async throws {
        let transport = GeneratedTransport(statuses: [503, 200])
        var configuration = ClientConfiguration(
            apiKey: nil, baseURL: URL(string: "https://example.test/v1")!,
            organization: "org", project: "project", maxRetries: 1, initialRetryDelay: 0, maxRetryDelay: 0,
            accessTokenProvider: { "token" })
        configuration.headers["X-Extra"] = "extension"
        let client = try Client(openAIConfiguration: configuration, transport: transport)
        _ = try await client.listModels(.init())
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.headerFields[.authorization], "Bearer token")
        XCTAssertEqual(requests.first?.headerFields[HTTPField.Name("X-Extra")!], "extension")
    }

    func testNetworkFailureRetriesBeforeSuccessfulHeaders() async throws {
        let transport = GeneratedTransport(networkFailures: 1)
        var configuration = ClientConfiguration.ollama()
        configuration.initialRetryDelay = 0
        let client = try Client(openAIConfiguration: configuration, transport: transport)
        _ = try await client.listModels(.init())
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testQueryOverridesPreserveLiteralPlus() async throws {
        let transport = GeneratedTransport()
        let client = try Client(
            openAIConfiguration: .ollama(), transport: transport,
            requestOptions: RequestOptions(query: ["literal": "a+b c"]))
        _ = try await client.listModels(.init())
        let requests = await transport.requests
        XCTAssertEqual(requests[0].path, "/models?literal=a%2Bb%20c")
    }

    func testUnauthorizedOpeningRefreshesOnlyRejectedToken() async throws {
        let tokens = GeneratedTokenFixture()
        var configuration = ClientConfiguration.ollama()
        configuration.initialRetryDelay = 0
        configuration.accessTokenProvider = { await tokens.current() }
        configuration.refreshUnauthorized = { await tokens.reject($0) }
        let transport = GeneratedTransport(statuses: [401, 200])
        let client = try Client(openAIConfiguration: configuration, transport: transport)
        _ = try await client.listModels(.init())
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.headerFields[.authorization] }, ["Bearer old", "Bearer fresh"])
    }

    func testExplicitAuthorizationDoesNotUseOAuthRecovery() async throws {
        var configuration = ClientConfiguration.ollama()
        configuration.accessTokenProvider = {
            XCTFail("Explicit auth bypasses token acquisition")
            return "wrong"
        }
        configuration.refreshUnauthorized = { _ in
            XCTFail("Explicit auth bypasses recovery")
            return true
        }
        let transport = GeneratedTransport(statuses: [401, 200])
        let client = try Client(
            openAIConfiguration: configuration, transport: transport,
            requestOptions: RequestOptions(headers: ["Authorization": "Custom explicit"]))
        _ = try await client.listModels(.init())
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].headerFields[.authorization], "Custom explicit")
    }

    func testSingleIterationMultipartIsNotRetried() async throws {
        var configuration = ClientConfiguration.ollama()
        configuration.initialRetryDelay = 0
        let transport = GeneratedTransport(statuses: [503, 200], fileResponse: true)
        let client = try Client(openAIConfiguration: configuration, transport: transport)
        let file = HTTPBody(Array("bytes".utf8), length: .known(5), iterationBehavior: .single)
        let parts: [Components.Schemas.CreateFileRequest] = [
            .file(.init(payload: .init(body: file), filename: "single.txt")),
            .purpose(.init(payload: .init(body: HTTPBody("assistants")))),
        ]
        _ = try await client.createFile(.init(body: .multipartForm(MultipartBody(parts))))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testFileBodyIsBoundedAndReplayable() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = Data((0..<250_000).map { UInt8($0 % 251) })
        try source.write(to: url)
        let body = try HTTPBody(fileURL: url, chunkSize: 4096)
        var reconstructed = Data()
        for try await chunk in body {
            XCTAssertLessThanOrEqual(chunk.count, 4096)
            reconstructed.append(contentsOf: chunk)
        }
        XCTAssertEqual(reconstructed, source)
        let replay = try await Data(collecting: body, upTo: source.count)
        XCTAssertEqual(replay, source)
    }

    func testFileBodyRejectsTruncationAndInvalidChunkSize() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("original".utf8).write(to: url)
        let body = try HTTPBody(fileURL: url)
        try Data("x".utf8).write(to: url)
        do {
            _ = try await Data(collecting: body, upTo: 1024)
            XCTFail("Truncated file accepted")
        } catch {}
        XCTAssertThrowsError(try HTTPBody(fileURL: url, chunkSize: 0))
    }

    func testMultipartFileUploadRetainsFileBytes() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("streamed file content".utf8).write(to: url)
        let file = try HTTPBody(fileURL: url, chunkSize: 4)
        let transport = GeneratedTransport(fileResponse: true)
        let client = try Client(openAIConfiguration: .ollama(), transport: transport)
        let parts: [Components.Schemas.CreateFileRequest] = [
            .file(.init(payload: .init(body: file), filename: "sample.txt")),
            .purpose(.init(payload: .init(body: HTTPBody("assistants")))),
        ]
        let result = try await client.createFile(.init(body: .multipartForm(MultipartBody(parts))))
        XCTAssertEqual(try result.ok.body.json.id, "file-1")
        let bytes = await transport.bodies.first!
        let multipart = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(multipart.contains("streamed file content"))
        XCTAssertTrue(multipart.contains("sample.txt"))
        XCTAssertTrue(multipart.contains("assistants"))
    }
}

private actor GeneratedTransport: ClientTransport {
    var requests: [HTTPRequest] = []
    var bodies: [Data] = []
    var statuses: [Int]
    let fileResponse: Bool
    var networkFailures: Int
    init(statuses: [Int] = [200], fileResponse: Bool = false, networkFailures: Int = 0) {
        self.statuses = statuses
        self.fileResponse = fileResponse
        self.networkFailures = networkFailures
    }
    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (
        HTTPTypes.HTTPResponse, HTTPBody?
    ) {
        requests.append(request)
        if networkFailures > 0 {
            networkFailures -= 1
            throw URLError(.networkConnectionLost)
        }
        if let body { bodies.append(try await Data(collecting: body, upTo: 1024 * 1024)) }
        let status = statuses.count > 1 ? statuses.removeFirst() : statuses[0]
        let json =
            fileResponse
            ? #"{"id":"file-1","object":"file","bytes":21,"created_at":1,"filename":"sample.txt","purpose":"assistants","status":"processed"}"#
            : #"{"object":"list","data":[{"id":"model-1","object":"model","created":1,"owned_by":"local"}]}"#
        return (
            HTTPTypes.HTTPResponse(status: .init(code: status), headerFields: [.contentType: "application/json"]),
            HTTPBody(json)
        )
    }
}

private struct ChangedOriginMiddleware: OpenAPIRuntime.ClientMiddleware {
    let authority: Bool
    func intercept(
        _ original: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPTypes.HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPTypes.HTTPResponse, HTTPBody?) {
        var request = original
        if authority { request.authority = "other.test" }
        return try await next(request, body, authority ? baseURL : URL(string: "https://other.test/v1")!)
    }
}

private actor GeneratedTokenFixture {
    private var token = "old"
    func current() -> String { token }
    func reject(_ rejected: String) -> Bool {
        guard rejected == token else { return false }
        token = "fresh"
        return true
    }
}

private struct SlowGeneratedBody: ClientTransport {
    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (
        HTTPTypes.HTTPResponse, HTTPBody?
    ) {
        let pair = AsyncThrowingStream<ArraySlice<UInt8>, any Error>.makeStream()
        let task = Task {
            do {
                try await Task.sleep(for: .seconds(10))
                pair.continuation.finish()
            } catch { pair.continuation.finish(throwing: error) }
        }
        pair.continuation.onTermination = { @Sendable _ in task.cancel() }
        return (
            HTTPTypes.HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]),
            HTTPBody(pair.stream, length: .unknown, iterationBehavior: .single)
        )
    }
}

private final class AdapterCancellations: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func record() { lock.withLock { count += 1 } }
}

private actor AdapterFixture: OpenAITransport {
    var requests: [URLRequest] = []
    nonisolated let cancellations = AdapterCancellations()
    func send(_ request: URLRequest) async throws -> OpenAI.HTTPResponse { throw URLError(.unsupportedURL) }
    func stream(_ request: URLRequest) async throws -> OpenAI.HTTPStreamResponse {
        requests.append(request)
        let stream = AsyncThrowingStream<Data, any Error> { continuation in
            continuation.yield(
                Data(
                    #"{"object":"list","data":[{"id":"adapter-model","object":"model","created":1,"owned_by":"local"}]}"#
                        .utf8))
            continuation.finish()
        }
        return OpenAI.HTTPStreamResponse(
            statusCode: 200, headers: ["Content-Type": "application/json"], body: stream,
            cancel: { self.cancellations.record() })
    }
}
