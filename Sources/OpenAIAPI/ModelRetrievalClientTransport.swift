import Foundation
import HTTPTypes
import OpenAI
import OpenAPIRuntime

/// Adapts model lookup without modifying Apple's generated operations or schemas.
struct ModelRetrievalClientTransport: ClientTransport {
    let transport: any ClientTransport
    let maxBytes: Int

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPTypes.HTTPResponse, HTTPBody?) {
        let original = try await transport.send(request, body: body, baseURL: baseURL, operationID: operationID)
        guard original.0.status.code == 404, operationID == Operations.RetrieveModel.id, body == nil,
            let lookup = ModelRetrievalFallback(
                method: request.method.rawValue, path: request.path ?? "", modelsPath: "/models")
        else { return original }
        let originalData = try await collect(original.1)
        var listingRequest = request
        listingRequest.path = lookup.listingPath
        let listing = try await transport.send(
            listingRequest, body: nil, baseURL: baseURL, operationID: Operations.ListModels.id)
        let listingData = try await collect(listing.1)
        guard listing.0.status.code == 200, let data = try lookup.modelData(in: listingData) else {
            return (original.0, original.1 == nil ? nil : HTTPBody(originalData))
        }
        let headers = listing.0.headerFields.reduce(into: [String: String]()) { $0[$1.name.rawName] = $1.value }
        var fields = HTTPFields()
        for (name, value) in ModelRetrievalFallback.modelHeaders(headers, byteCount: data.count) {
            if let field = HTTPField.Name(name) { fields.append(HTTPField(name: field, value: value)) }
        }
        return (HTTPTypes.HTTPResponse(status: .ok, headerFields: fields), HTTPBody(data))
    }

    private func collect(_ body: HTTPBody?) async throws -> Data {
        guard let body else { return Data() }
        return try await Data(collecting: body, upTo: maxBytes)
    }
}
