import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Applies the opt-in model workaround below the public REST and resource APIs.
struct ModelRetrievalTransport: OpenAITransport {
    let transport: any OpenAITransport
    let modelsPath: String
    let maxBytes: Int

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let response = try await transport.send(request)
        guard response.statusCode == 404, let lookup = lookup(request),
            let url = URL(string: lookup.listingPath)
        else { return response }
        var listingRequest = request
        listingRequest.url = url
        let listing = try await transport.send(listingRequest)
        guard listing.statusCode == 200, listing.data.count <= maxBytes,
            let data = try lookup.modelData(in: listing.data)
        else { return response }
        return HTTPResponse(
            data: data, statusCode: 200,
            headers: ModelRetrievalFallback.modelHeaders(listing.headers, byteCount: data.count))
    }

    func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
        let response = try await transport.stream(request)
        guard response.statusCode == 404, let lookup = lookup(request),
            let url = URL(string: lookup.listingPath)
        else { return response }
        let original = try await collect(response)
        var listingRequest = request
        listingRequest.url = url
        let listing = try await collect(transport.stream(listingRequest))
        guard listing.statusCode == 200, let data = try lookup.modelData(in: listing.data) else {
            return buffered(original)
        }
        return buffered(
            HTTPResponse(
                data: data, statusCode: 200,
                headers: ModelRetrievalFallback.modelHeaders(listing.headers, byteCount: data.count)))
    }

    private func lookup(_ request: URLRequest) -> ModelRetrievalFallback? {
        guard request.httpBody == nil, request.httpBodyStream == nil, let url = request.url else { return nil }
        return ModelRetrievalFallback(
            method: request.httpMethod ?? "GET", path: url.absoluteString, modelsPath: modelsPath)
    }

    private func collect(_ response: HTTPStreamResponse) async throws -> HTTPResponse {
        try await withTaskCancellationHandler {
            defer { response.cancel() }
            var data = Data()
            for try await chunk in response.body {
                try Task.checkCancellation()
                guard chunk.count <= maxBytes - data.count else {
                    throw OpenAIClientError.invalidResponse
                }
                data.append(chunk)
            }
            return HTTPResponse(data: data, statusCode: response.statusCode, headers: response.headers)
        } onCancel: {
            response.cancel()
        }
    }

    private func buffered(_ response: HTTPResponse) -> HTTPStreamResponse {
        HTTPStreamResponse(
            statusCode: response.statusCode, headers: response.headers,
            body: AsyncThrowingStream { continuation in
                continuation.yield(response.data)
                continuation.finish()
            })
    }
}
