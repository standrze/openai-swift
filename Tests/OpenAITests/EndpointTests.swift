import Foundation
import XCTest

@testable import OpenAI

final class EndpointTests: XCTestCase {
    func testEveryPinnedOperationDispatchesItsDeclaredMethodAndEscapedPath() async throws {
        let referenceURL = try XCTUnwrap(
            Bundle.module.url(forResource: "EndpointReference", withExtension: "json", subdirectory: "Fixtures"))
        let reference = try JSONDecoder().decode(EndpointReference.self, from: Data(contentsOf: referenceURL))
        XCTAssertEqual(reference.revision, RESTEndpoint.upstreamRevision)
        XCTAssertEqual(RESTEndpoint.all.count, reference.operations.count)
        XCTAssertEqual(Set(RESTEndpoint.all.map(\.name)).count, 340)
        let catalog = Dictionary(uniqueKeysWithValues: RESTEndpoint.all.map { ($0.name, $0) })
        let transport = RecordingTransport(send: reference.operations.map { _ in .response(jsonResponse("{}")) })
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)
        for operation in reference.operations {
            let endpoint = try XCTUnwrap(catalog[operation.name])
            XCTAssertEqual(endpoint.pathTemplate, operation.path)
            XCTAssertEqual(endpoint.method.rawValue, operation.method)
            XCTAssertEqual(endpoint.upstreamSymbol, operation.upstreamSymbol)
            let referencePath = operation.path.split(separator: "?", maxSplits: 1)[0]
            let referenceParameters = referencePath.split(separator: "/").compactMap { segment -> String? in
                guard segment.hasPrefix("{"), segment.hasSuffix("}") else { return nil }
                return String(segment.dropFirst().dropLast())
            }
            XCTAssertEqual(endpoint.parameterNames, referenceParameters)
            let parameters = Dictionary(uniqueKeysWithValues: referenceParameters.map { ($0, "id/name ?#🌙") })
            _ = try await client.api.call(endpoint, parameters: parameters)
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, reference.operations.count)
        for (request, operation) in zip(requests, reference.operations) {
            let routeParts = operation.path.split(separator: "?", maxSplits: 1)
            var path = String(routeParts[0])
            for parameter in catalog[operation.name]!.parameterNames {
                path = path.replacingOccurrences(of: "{\(parameter)}", with: "id%2Fname%20%3F%23%F0%9F%8C%99")
            }
            XCTAssertEqual(request.httpMethod, operation.method)
            XCTAssertEqual(
                request.url?.absoluteString.split(separator: "?").first.map(String.init),
                "https://example.test/proxy/v1/" + path)
            if routeParts.count > 1 {
                let expected = URLComponents(string: "https://reference.invalid/?" + routeParts[1])?.queryItems
                XCTAssertEqual(
                    URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems,
                    expected)
            }
        }
    }

    func testPathBindingRejectsMissingEmptyAndUnexpectedIdentifiers() throws {
        let endpoint = RESTEndpoint.filesRetrieve
        XCTAssertThrowsError(try endpoint.path())
        XCTAssertThrowsError(try endpoint.path(parameters: ["file_id": ""]))
        XCTAssertThrowsError(try endpoint.path(parameters: ["file_id": "one", "other": "two"]))
        XCTAssertEqual(try endpoint.path(parameters: ["file_id": "one/two"]), "files/one%2Ftwo")
    }

    func testCatalogAddsBetaVersionsAndHonorsCaseInsensitiveOverrides() async throws {
        let transport = RecordingTransport(send: (0..<5).map { _ in .response(jsonResponse("{}")) })
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)
        _ = try await client.api.call(.betaAssistantsCreate, body: [:])
        _ = try await client.api.call(.betaAgentsCreate, body: [:])
        _ = try await client.api.call(.betaResponsesCreate, body: [:])
        _ = try await client.api.call(
            .betaAssistantsCreate, body: [:], options: .init(headers: ["openai-beta": "custom=v3"]))
        _ = try await client.api.call(
            .betaResponsesCreate, body: [:], options: .init(queryItems: [URLQueryItem(name: "beta", value: "false")]))
        let requests = await transport.requests
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "OpenAI-Beta"), "assistants=v2")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "OpenAI-Beta"), "agents=v1")
        XCTAssertEqual(
            URLComponents(url: requests[2].url!, resolvingAgainstBaseURL: false)?.queryItems,
            [URLQueryItem(name: "beta", value: "true")])
        XCTAssertEqual(requests[3].value(forHTTPHeaderField: "OpenAI-Beta"), "custom=v3")
        XCTAssertEqual(
            URLComponents(url: requests[4].url!, resolvingAgainstBaseURL: false)?.queryItems,
            [URLQueryItem(name: "beta", value: "false")])
    }

    func testRawRequestsPreserveOriginalBytesAndContentType() async throws {
        let transport = RecordingTransport(send: [.response(HTTPResponse(data: Data(), statusCode: 204))])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)
        let bytes = Data([0, 255, 1, 13, 10])
        let response = try await client.api.response(.realtimeCallsCreate, data: bytes, contentType: "application/sdp")
        XCTAssertEqual(response.statusCode, 204)
        let requests = await transport.requests
        XCTAssertEqual(requests.first?.httpBody, bytes)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Content-Type"), "application/sdp")
    }

    func testRepeatedQueryNamesAreRetainedAlongsideDictionaryQuery() async throws {
        let transport = RecordingTransport(send: [.response(jsonResponse("{}"))])
        let client = OpenAIClient(configuration: testConfiguration(), transport: transport)
        _ = try await client.api.call(
            .adminOrganizationUsageCompletions,
            options: .init(
                query: ["start_time": "100"],
                queryItems: [
                    URLQueryItem(name: "group_by", value: "project_id"),
                    URLQueryItem(name: "group_by", value: "model"),
                ]))
        let requests = await transport.requests
        let items = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.filter { $0.name == "group_by" }.map(\.value), ["project_id", "model"])
        XCTAssertEqual(items?.first?.name, "start_time")
    }

    func testDynamicTokenIsResolvedPerOperationAndExplicitAuthorizationWins() async throws {
        let issuer = TestTokenIssuer()
        var configuration = testConfiguration()
        configuration.accessTokenProvider = { await issuer.next() }
        let transport = RecordingTransport(send: (0..<3).map { _ in .response(jsonResponse("{}")) })
        let client = OpenAIClient(configuration: configuration, transport: transport)
        let _: JSONValue = try await client.send(.get, path: "models")
        let _: JSONValue = try await client.send(.get, path: "models")
        let _: JSONValue = try await client.send(
            .get, path: "models", options: .init(headers: ["authorization": "Bearer explicit"]))
        let requests = await transport.requests
        XCTAssertEqual(
            requests.map { $0.value(forHTTPHeaderField: "Authorization") },
            ["Bearer token-1", "Bearer token-2", "Bearer explicit"])
        let count = await issuer.count
        XCTAssertEqual(count, 2)
    }

    func testMultipartPartMIMETypesAreEncodedAndValidated() throws {
        let body = try MultipartBody(
            fields: [
                MultipartField(name: "sdp", value: "v=0\r\n", contentType: "application/sdp"),
                MultipartField(name: "session", value: "{}", contentType: "application/json"),
            ], files: [])
        let string = try XCTUnwrap(String(data: body.data, encoding: .utf8))
        XCTAssertTrue(string.contains("name=\"sdp\"\r\nContent-Type: application/sdp\r\n\r\nv=0\r\n"))
        XCTAssertTrue(string.contains("name=\"session\"\r\nContent-Type: application/json\r\n\r\n{}"))
        XCTAssertThrowsError(
            try MultipartBody(fields: [MultipartField(name: "sdp", value: "", contentType: "bad\r\nheader")], files: [])
        )
    }
}

private struct EndpointReference: Decodable {
    let revision: String
    let operations: [Operation]
    struct Operation: Decodable {
        let name: String
        let method: String
        let path: String
        let upstreamSymbol: String
    }
}

private actor TestTokenIssuer {
    private(set) var count = 0
    func next() -> String {
        count += 1
        return "token-\(count)"
    }
}
