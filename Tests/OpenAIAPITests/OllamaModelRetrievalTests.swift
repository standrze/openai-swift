import Foundation
import HTTPTypes
import OpenAI
import OpenAPIRuntime
import XCTest

@testable import OpenAIAPI

final class OllamaModelRetrievalTests: XCTestCase, @unchecked Sendable {
    func testGeneratedRetrievalUsesExactAdvertisedModelAndPreservesOptions() async throws {
        let transport = ModelLookupFixture(listing: modelListing)
        let client = try Client(
            openAIConfiguration: .ollama(baseURL: URL(string: "https://example.test/proxy%20name/v1")!),
            transport: transport, requestOptions: .init(headers: ["X-Trace": "generated"], query: ["literal": "a+b"]))
        let output = try await client.retrieveModel(.init(path: .init(model: "org/model:latest")))
        let model = try output.ok.body.json
        XCTAssertEqual(model.id, "org/model:latest")
        XCTAssertEqual(model.ownedBy, "org")
        XCTAssertEqual(model.jsonMetadata.extraFields["vendor"]?.rawString, #""retained""#)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[0].path?.contains("org%2Fmodel") == true)
        XCTAssertEqual(requests[1].path, "/models?literal=a%2Bb")
        XCTAssertTrue(requests.allSatisfy { $0.headerFields[HTTPField.Name("X-Trace")!] == "generated" })
        XCTAssertTrue(requests.allSatisfy { $0.headerFields[.authorization] == nil })
        let operations = await transport.operations
        XCTAssertEqual(operations, [Operations.RetrieveModel.id, Operations.ListModels.id])
    }

    func testGeneratedFallbackCanBeDisabledAndMissingIDsKeepOriginalBody() async throws {
        for (enabled, listing) in [(false, modelListing), (true, #"{"data":[]}"#), (true, "malformed")] {
            let transport = ModelLookupFixture(listing: listing)
            var configuration = ClientConfiguration.ollama()
            configuration.modelRetrievalFallback = enabled
            let client = try Client(openAIConfiguration: configuration, transport: transport)
            let output = try await client.retrieveModel(.init(path: .init(model: "org/model:latest")))
            XCTAssertEqual(try output.notFound.body.json.error.message, "original")
            let requests = await transport.requests
            XCTAssertEqual(requests.count, enabled ? 2 : 1)
        }
    }

    func testGeneratedFallbackScopeAndFailedListingPreserveResponse() async throws {
        for (status, method, path, operation, listingStatus, expectedRequests) in [
            (403, HTTPRequest.Method.get, "/models/org%2Fmodel", "retrieveModel", 200, 1),
            (404, .delete, "/models/org%2Fmodel", "deleteModel", 200, 1),
            (404, .get, "/models/model", "retrieveModel", 200, 1),
            (404, .get, "/models/org%2Fmodel", "otherOperation", 200, 1),
            (404, .get, "/models/org%2Fmodel", "retrieveModel", 503, 2),
        ] {
            let fixture = ModelLookupFixture(status: status, listing: modelListing, listingStatus: listingStatus)
            let transport = ModelRetrievalClientTransport(transport: fixture, maxBytes: 4096)
            let response = try await transport.send(
                HTTPRequest(method: method, scheme: nil, authority: nil, path: path), body: nil,
                baseURL: URL(string: "http://localhost:11434/v1")!, operationID: operation)
            XCTAssertEqual(response.0.status.code, status)
            let data = try await Data(collecting: response.1!, upTo: 4096)
            XCTAssertEqual(data, Data(originalError.utf8))
            let requests = await fixture.requests
            XCTAssertEqual(requests.count, expectedRequests)
        }
    }
}

private let originalError = #"{"error":{"message":"original","type":"not_found","param":null,"code":null}}"#
private let modelListing =
    #"{"data":[{"id":"other/model:latest","object":"model","created":1,"owned_by":"other"},{"id":"org/model:latest","object":"model","created":2,"owned_by":"org","vendor":"retained"}]}"#

private actor ModelLookupFixture: ClientTransport {
    let status: Int
    let listing: String
    let listingStatus: Int
    private(set) var requests: [HTTPRequest] = []
    private(set) var operations: [String] = []

    init(status: Int = 404, listing: String, listingStatus: Int = 200) {
        self.status = status
        self.listing = listing
        self.listingStatus = listingStatus
    }

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPTypes.HTTPResponse, HTTPBody?) {
        requests.append(request)
        operations.append(operationID)
        let isListing = requests.count > 1
        return (
            HTTPTypes.HTTPResponse(
                status: .init(code: isListing ? listingStatus : status),
                headerFields: [.contentType: "application/json"]),
            HTTPBody(isListing ? listing : originalError)
        )
    }
}
