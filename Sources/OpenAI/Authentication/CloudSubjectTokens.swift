import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Built-in subject-token acquisition for OpenAI workload identity. Metadata never uses the API transport.
public enum CloudSubjectTokens {
    /// Reads the projected token on every refresh so Kubernetes rotation is observed.
    public static func kubernetes(
        fileURL: URL = URL(fileURLWithPath: "/var/run/secrets/kubernetes.io/serviceaccount/token")
    ) -> @Sendable () async throws -> String {
        {
            try Task.checkCancellation()
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 1024 * 1024 + 1) ?? Data()
            guard data.count <= 1024 * 1024, let value = String(data: data, encoding: .utf8) else {
                throw OAuthTokenError.invalidResponse("Invalid projected token file")
            }
            return try validate(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    public static func azureManagedIdentity(
        resource: String = "https://management.azure.com/", clientID: String? = nil,
        objectID: String? = nil, resourceID: String? = nil, apiVersion: String = "2018-02-01"
    ) -> @Sendable () async throws -> String {
        {
            var query = [
                URLQueryItem(name: "resource", value: resource), URLQueryItem(name: "api-version", value: apiVersion),
            ]
            for (name, value) in [("client_id", clientID), ("object_id", objectID), ("msi_res_id", resourceID)] {
                if let value { query.append(URLQueryItem(name: name, value: value)) }
            }
            let response = try await metadata(
                path: "/metadata/identity/oauth2/token", query: query, headers: ["Metadata": "true"])
            let token = try JSONDecoder().decode(JSONValue.self, from: response.data)["access_token"]?.stringValue ?? ""
            return try validate(token)
        }
    }

    public static func googleCloudIdentity(audience: String = "https://api.openai.com/v1")
        -> @Sendable () async throws -> String
    {
        {
            let response = try await metadata(
                path: "/computeMetadata/v1/instance/service-accounts/default/identity",
                query: [URLQueryItem(name: "audience", value: audience)], headers: ["Metadata-Flavor": "Google"])
            guard response.header("Metadata-Flavor") == "Google" else {
                throw OAuthTokenError.invalidResponse("GCP metadata response is missing Metadata-Flavor: Google")
            }
            return try validate(
                String(decoding: response.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func validate(_ token: String) throws -> String {
        try Task.checkCancellation()
        guard !token.isEmpty, !token.contains("\r"), !token.contains("\n") else {
            throw OAuthTokenError.emptySubjectToken
        }
        return token
    }

    private static func metadata(path: String, query: [URLQueryItem], headers: [String: String]) async throws
        -> HTTPResponse
    {
        var components = URLComponents(string: "http://169.254.169.254")!
        components.path = path
        components.queryItems = query
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: components.url!, timeoutInterval: 5)
        request.allHTTPHeaderFields = headers
        let transport = URLSessionTransport(redirectPolicy: .rejectAll, disableProxy: true, resourceTimeout: 5)
        let response = try await transport.stream(request)
        return try await withTaskCancellationHandler {
            defer { response.cancel() }
            var data = Data()
            for try await chunk in response.body {
                guard chunk.count <= 1024 * 1024 - data.count else {
                    throw OAuthTokenError.invalidResponse("Metadata response exceeds size limit")
                }
                data.append(chunk)
            }
            guard response.statusCode == 200 else {
                throw OAuthTokenError.invalidResponse("Metadata request failed with HTTP \(response.statusCode)")
            }
            return HTTPResponse(data: data, statusCode: response.statusCode, headers: response.headers)
        } onCancel: {
            response.cancel()
        }
    }
}
