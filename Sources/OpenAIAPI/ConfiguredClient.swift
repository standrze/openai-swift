import Foundation
import HTTPTypes
import OpenAI
import OpenAPIRuntime
import OpenAPIURLSession

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

extension Client {
    /// Creates the generated full-schema client with OpenAI authentication and provider isolation.
    /// This uses Apple's streaming transport. Add OpenAPIRuntime middleware for generated operations;
    /// OpenAIClient's URLRequest middleware belongs to that client's separate transport stack.
    public init(
        openAIConfiguration configuration: ClientConfiguration = .init(),
        transport: (any ClientTransport)? = nil,
        requestOptions: RequestOptions = .init(),
        middlewares: [any OpenAPIRuntime.ClientMiddleware] = []
    ) throws {
        var configuration = configuration
        if let baseURL = requestOptions.baseURL { configuration.baseURL = baseURL }
        if let delay = requestOptions.maxRetryDelay { configuration.maxRetryDelay = delay }
        if let retries = requestOptions.maxRetries { configuration.maxRetries = retries }
        for (key, value) in requestOptions.headers { configuration.headers[key] = value }
        if let timeout = requestOptions.timeout { configuration.timeout = timeout }
        guard configuration.middleware.isEmpty, configuration.prepareAttempt == nil, requestOptions.middleware.isEmpty
        else {
            throw OpenAIClientError.invalidConfiguration(
                "Generated clients use OpenAPIRuntime middleware; URLRequest middleware/signers require OpenAIClient")
        }
        guard configuration.timeout.isFinite, configuration.timeout >= 0 else {
            throw OpenAIClientError.invalidConfiguration("Invalid request timeout")
        }
        guard let scheme = configuration.baseURL.scheme?.lowercased(), ["https", "http"].contains(scheme),
            configuration.baseURL.host != nil, configuration.baseURL.user == nil,
            configuration.baseURL.password == nil, configuration.baseURL.query == nil,
            configuration.baseURL.fragment == nil, configuration.maxRetries >= 0,
            configuration.maxRetries <= 100, configuration.maxRetryDelay.isFinite,
            configuration.maxRetryDelay >= 0, configuration.maxRetryDelay <= 86_400,
            configuration.initialRetryDelay.isFinite, configuration.initialRetryDelay >= 0,
            configuration.maxEventBytes > 0
        else {
            throw OpenAIClientError.invalidConfiguration("Invalid generated client configuration")
        }
        let nativeConfiguration = URLSessionConfiguration.ephemeral
        nativeConfiguration.timeoutIntervalForRequest =
            configuration.timeout == 0 ? RequestDeadline.unlimitedInterval : configuration.timeout
        nativeConfiguration.timeoutIntervalForResource = RequestDeadline.unlimitedInterval
        let nativeSession = URLSession(
            configuration: nativeConfiguration, delegate: GeneratedSessionDelegate(), delegateQueue: nil)
        let resolvedTransport =
            transport ?? OpenAPIURLSession.URLSessionTransport(configuration: .init(session: nativeSession))
        let compatibleTransport: any ClientTransport =
            configuration.modelRetrievalFallback
            ? ModelRetrievalClientTransport(transport: resolvedTransport, maxBytes: configuration.maxEventBytes)
            : resolvedTransport
        self.init(
            serverURL: configuration.baseURL,
            transport: OriginRestrictedClientTransport(transport: compatibleTransport, origin: configuration.baseURL),
            middlewares: [
                AuthenticationMiddleware(
                    configuration: configuration, canRecoverBody: middlewares.isEmpty, options: requestOptions),
                RequestOptionsMiddleware(requestOptions),
            ] + middlewares)
    }
}

private struct AuthenticationMiddleware: OpenAPIRuntime.ClientMiddleware {
    let configuration: ClientConfiguration
    let canRecoverBody: Bool
    let options: RequestOptions
    func intercept(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
        next: @Sendable (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPTypes.HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPTypes.HTTPResponse, HTTPBody?) {
        return try await AuthenticationRetryScope.withScope(configuration: configuration, options: options) {
            var request = request
            if let key = configuration.credential(forAPIPath: request.path ?? "/"), !key.isEmpty {
                try HeaderMutation.validate(name: "Authorization", value: "Bearer " + key)
                request.headerFields[.authorization] = "Bearer \(key)"
            }
            for (name, value) in [
                ("OpenAI-Organization", configuration.organization), ("OpenAI-Project", configuration.project),
            ] {
                if let value, let field = HTTPField.Name(name) {
                    try HeaderMutation.validate(name: name, value: value)
                    request.headerFields[field] = value
                }
            }
            for (name, value) in configuration.headers {
                try HeaderMutation.validate(name: name, value: value)
                guard let field = HTTPField.Name(name) else {
                    throw OpenAIClientError.invalidConfiguration("Invalid HTTP header")
                }
                request.headerFields[field] = value
            }
            let explicitAuthorization =
                options.overridesAuthorization
                || configuration.headers.keys.contains { $0.lowercased() == "authorization" }
            guard
                !configuration.sharesAuthenticationRetryBudget
                    || (!explicitAuthorization && configuration.apiKey == nil && configuration.adminAPIKey == nil)
            else {
                throw OpenAIClientError.invalidConfiguration(
                    "X.509 authentication cannot be combined with Authorization overrides")
            }
            // Multipart's outer sequence can be repeatable while an individual file part is single-use.
            // Its public HTTPBody does not expose nested replayability, so uploads are never retried here.
            let multipart = request.headerFields[.contentType]?.lowercased().hasPrefix("multipart/") == true
            let retries = body?.iterationBehavior == .single || multipart ? 0 : configuration.maxRetries
            var recoveredUnauthorized = false
            for attempt in 0...retries {
                guard AuthenticationRetryScope.current?.beginAttempt() ?? true else {
                    throw OpenAIClientError.invalidConfiguration("Authentication retry budget exhausted")
                }
                try Task.checkCancellation()
                let path = URLComponents(string: request.path ?? "/")?.path ?? "/"
                configuration.diagnostics?(.request(method: request.method.rawValue, path: path, attempt: attempt))
                var result: (HTTPTypes.HTTPResponse, HTTPBody?)
                do {
                    let end = try RequestDeadline.end(timeout: configuration.timeout, deadline: options.deadline)
                    let original = request
                    let (authenticated, received) = try await withoutActuallyEscaping(next) { next in
                        try await RequestDeadline.run(until: end) {
                            var request = original
                            if !explicitAuthorization, let provider = configuration.accessTokenProvider {
                                let token = try await provider()
                                try HeaderMutation.validate(name: "Authorization", value: "Bearer " + token)
                                guard !token.isEmpty else {
                                    throw OpenAIClientError.invalidConfiguration("Invalid bearer token")
                                }
                                request.headerFields[.authorization] = "Bearer \(token)"
                            }
                            return (request, try await next(request, body, baseURL))
                        }
                    }
                    request = authenticated
                    result = (received.0, responseBody(received.1, until: end))
                } catch {
                    let underlying = (error as? OpenAPIRuntime.ClientError)?.underlyingError ?? error
                    guard attempt < retries, AuthenticationRetryScope.current?.canRetry ?? true,
                        HTTPRetryPolicy.shouldRetry(error: underlying)
                    else { throw error }
                    try await RequestDeadline.run(until: options.deadline) {
                        try await HTTPRetryPolicy.wait(attempt: attempt, headers: [:], configuration: configuration)
                    }
                    continue
                }
                configuration.diagnostics?(.response(status: result.0.status.code, attempt: attempt))
                if let observer = configuration.responseObserver {
                    var data = Data()
                    if result.0.headerFields[.contentType]?.hasPrefix("application/json") == true,
                        let received = result.1
                    {
                        data = try await Data(collecting: received, upTo: configuration.maxEventBytes)
                        result.1 = HTTPBody(data)
                    }
                    let headers = result.0.headerFields.reduce(into: [String: String]()) {
                        $0[$1.name.rawName] = $1.value
                    }
                    observer(OpenAI.HTTPResponse(data: data, statusCode: result.0.status.code, headers: headers))
                }
                let status = result.0.status.code
                let headers = result.0.headerFields.reduce(into: [String: String]()) { $0[$1.name.rawName] = $1.value }
                var recovered = false
                if status == 401, !explicitAuthorization,
                    let authorization = request.headerFields[.authorization], authorization.hasPrefix("Bearer "),
                    let refresh = configuration.refreshUnauthorized
                {
                    let invalidated = await refresh(String(authorization.dropFirst(7)))
                    recovered =
                        invalidated && !recoveredUnauthorized && attempt < retries
                        && (body == nil || canRecoverBody)
                        && (AuthenticationRetryScope.current?.reserveUnauthorizedReplay() ?? true)
                    recoveredUnauthorized = recoveredUnauthorized || recovered
                }
                let retryDecision = try HTTPRetryPolicy.decision(
                    attempt: attempt, headers: headers, configuration: configuration)
                guard attempt < retries, AuthenticationRetryScope.current?.canRetry ?? true,
                    recovered
                        || (HTTPRetryPolicy.shouldRetry(status: status, headers: headers) && retryDecision.shouldRetry)
                else {
                    return result
                }
                if let failedBody = result.1 {
                    // Consume a bounded failure response so the native connection can be released before retry.
                    _ = try await Data(collecting: failedBody, upTo: configuration.maxEventBytes)
                }
                if !recovered, retryDecision.delay > 0 {
                    try await RequestDeadline.run(until: options.deadline) {
                        try await Task.sleep(for: .seconds(retryDecision.delay))
                    }
                }
            }
            throw OpenAIClientError.invalidResponse
        }
    }
}

private final class GeneratedSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        func origin(_ url: URL?) -> String? {
            guard let url, let scheme = url.scheme, let host = url.host else { return nil }
            return "\(scheme.lowercased())://\(host.lowercased()):\(url.port ?? (scheme == "https" ? 443 : 80))"
        }
        completionHandler(origin(task.originalRequest?.url) == origin(request.url) ? request : nil)
    }
}
