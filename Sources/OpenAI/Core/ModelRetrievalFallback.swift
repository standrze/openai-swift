import Foundation

/// Shared policy for Ollama's escaped-slash model route workaround.
package struct ModelRetrievalFallback: Sendable {
    package let id: String
    package let listingPath: String

    package init?(method: String, path: String, modelsPath: String) {
        guard method == "GET", var components = URLComponents(string: path) else { return nil }
        let prefix = modelsPath + "/"
        guard components.percentEncodedPath.hasPrefix(prefix) else { return nil }
        let segment = String(components.percentEncodedPath.dropFirst(prefix.count))
        guard !segment.contains("/"), let id = segment.removingPercentEncoding, id.contains("/") else { return nil }
        self.id = id
        components.percentEncodedPath = modelsPath
        listingPath = components.string!
    }

    package func modelData(in listing: Data) throws -> Data? {
        guard let value = try? OpenAIJSON.decode(JSONValue.self, from: listing),
            let model = value["data"]?.arrayValue?.first(where: { $0["id"]?.stringValue == id })
        else { return nil }
        return try model.encodedData()
    }

    package static func modelHeaders(_ headers: [String: String], byteCount: Int) -> [String: String] {
        // Listing validators, ranges, and representation headers do not describe the selected model body.
        let removed: Set<String> = [
            "content-type", "content-length", "content-encoding", "transfer-encoding", "content-range",
            "etag", "last-modified", "link", "digest", "content-digest", "repr-digest", "content-md5",
        ]
        var result = headers.filter { !removed.contains($0.key.lowercased()) }
        result["Content-Type"] = "application/json"
        result["Content-Length"] = String(byteCount)
        return result
    }
}
