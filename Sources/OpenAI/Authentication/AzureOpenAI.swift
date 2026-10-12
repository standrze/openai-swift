import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Azure endpoint and deployment routing, with API-key or application-owned Entra token acquisition.
public enum AzureOpenAI {
    public static func client(
        endpoint: URL, apiVersion: String, apiKey: String? = nil,
        tokenProvider: (@Sendable () async throws -> String)? = nil, deploymentName: String? = nil,
        deployment: @escaping @Sendable (String) -> String = { $0 },
        maxRetries: Int = 2, transport: any OpenAITransport = URLSessionTransport(redirectPolicy: .rejectAll)
    ) throws -> OpenAIClient {
        guard endpoint.scheme == "https", endpoint.host != nil, endpoint.user == nil, endpoint.password == nil,
            endpoint.query == nil, endpoint.fragment == nil, !apiVersion.isEmpty,
            (apiKey != nil) != (tokenProvider != nil), apiKey.map({ !$0.isEmpty }) ?? true
        else {
            throw OpenAIClientError.invalidConfiguration(
                "Azure requires HTTPS, api-version, and exactly one credential mode")
        }
        let baseURL = endpoint.appendingPathComponent("openai")
        let prefix = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!.percentEncodedPath
        var configuration = ClientConfiguration(
            apiKey: nil, baseURL: baseURL,
            organization: nil, project: nil, maxRetries: maxRetries, accessTokenProvider: tokenProvider,
            adminAPIKey: nil, webhookSecret: nil)
        if let apiKey { configuration.headers["api-key"] = apiKey }
        configuration.prepareAttempt = { request, _ in
            var request = request
            guard let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw OpenAIClientError.invalidResponse
            }
            var query = components.queryItems ?? []
            query.removeAll { $0.name == "api-version" }
            query.append(URLQueryItem(name: "api-version", value: apiVersion))
            components.queryItems = query
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            guard components.percentEncodedPath.hasPrefix(prefix + "/") else {
                throw OpenAIClientError.invalidConfiguration("Azure request is outside its API prefix")
            }
            let route = String(components.percentEncodedPath.dropFirst(prefix.count))
            let deploymentPaths = [
                "/chat/completions", "/completions", "/embeddings", "/audio/speech", "/audio/transcriptions",
                "/audio/translations", "/images/generations", "/images/edits",
            ]
            let model: String?
            if request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json") == true,
                let body = request.httpBody
            {
                model = try JSONDecoder().decode(JSONValue.self, from: body)["model"]?.stringValue
            } else if let body = request.httpBody,
                let contentType = request.value(forHTTPHeaderField: "Content-Type"),
                contentType.lowercased().hasPrefix("multipart/form-data")
            {
                model = try MultipartBody.routingField("model", data: body, contentType: contentType)
            } else {
                model = nil
            }
            if deploymentPaths.contains(route) {
                guard let model = deploymentName ?? model, !model.isEmpty else {
                    throw OpenAIClientError.invalidConfiguration("Azure deployment routing requires a nonempty model")
                }
                let name = deploymentName ?? deployment(model)
                guard !name.isEmpty else { throw OpenAIClientError.invalidConfiguration("Azure deployment is empty") }
                components.percentEncodedPath = prefix + "/deployments/" + OpenAIClient.pathComponent(name) + route
            }
            request.url = components.url
            return request
        }
        return OpenAIClient(configuration: configuration, transport: transport)
    }
}
