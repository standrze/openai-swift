import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A static native TLS capability restricted to OpenAI's global mTLS issuer and API origins.
/// Closing rejects new operations while requests already admitted may finish. Certificate rotation creates a new capability.
public final class X509WorkloadIdentity: OpenAITransport, @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private let transport: URLSessionTransport
    private let identity: TLSClientIdentity
    private let provider: OAuthTokenProvider

    public init(
        identity: TLSClientIdentity, identityProviderID: String, serviceAccountID: String,
        refreshBuffer: TimeInterval = 300, tokenExchangeTimeout: TimeInterval = 30
    ) throws {
        self.identity = identity
        transport = URLSessionTransport(redirectPolicy: .rejectAll, disableProxy: true, clientIdentity: identity)
        var configuration = OAuthConfiguration(
            tokenURL: URL(string: "https://mtls.auth.openai.com/oauth/token")!,
            grant: .x509(identityProviderID: identityProviderID, serviceAccountID: serviceAccountID),
            timeout: tokenExchangeTimeout, maxRetries: 2, initialRetryDelay: 0.025, maxRetryDelay: 8,
            refreshLeeway: refreshBuffer, maxTokenLifetime: 3_600)
        configuration.refreshFailureCooldown = 5
        provider = try OAuthTokenProvider(
            configuration: configuration,
            transport: URLSessionTransport(
                redirectPolicy: .rejectAll, disableProxy: true, resourceTimeout: RequestDeadline.unlimitedInterval,
                clientIdentity: identity,
                maxResponseBytes: 1024 * 1024))
    }

    public func client(organization: String? = nil, project: String? = nil, maxRetries: Int = 2) throws -> OpenAIClient
    {
        try admit()
        var configuration = ClientConfiguration(
            apiKey: nil, baseURL: URL(string: "https://mtls.api.openai.com/v1")!,
            organization: organization, project: project, maxRetries: maxRetries, adminAPIKey: nil, webhookSecret: nil)
        configuration.authenticate(using: provider)
        configuration.sharesAuthenticationRetryBudget = true
        configuration.accessTokenProvider = { [self] in
            try admit()
            return try await provider.accessToken()
        }
        configuration.webSocketTransport = X509WebSocketTransport(capability: self, identity: identity)
        return OpenAIClient(configuration: configuration, transport: self)
    }

    public func close() { lock.withLock { closed = true } }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        try await validate(request)
        return try await transport.send(request)
    }
    public func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
        try await validate(request)
        return try await transport.stream(request)
    }

    fileprivate func validate(_ request: URLRequest) async throws {
        try admit(request)
        guard let authorization = request.value(forHTTPHeaderField: "Authorization"),
            authorization.hasPrefix("Bearer "), await provider.hasIssued(String(authorization.dropFirst(7)))
        else {
            throw OpenAIClientError.invalidConfiguration("X.509 requests require this identity's issued bearer token")
        }
    }

    fileprivate func admit(_ request: URLRequest? = nil) throws {
        let check = {
            guard !self.lock.withLock({ self.closed }) else {
                throw OpenAIClientError.invalidConfiguration("X.509 capability is closed")
            }
        }
        if let scope = AuthenticationRetryScope.current { try scope.admit(self, check: check) } else { try check() }
        guard let request else { return }
        guard let url = request.url, url.scheme == "https", url.host == "mtls.api.openai.com",
            url.port == nil || url.port == 443, url.user == nil, url.password == nil,
            url.path.hasPrefix("/v1/")
        else {
            throw OpenAIClientError.invalidConfiguration("X.509 API requests are restricted to mtls.api.openai.com/v1")
        }
    }
}

private struct X509WebSocketTransport: OpenAIWebSocketTransport {
    let capability: X509WorkloadIdentity
    let identity: TLSClientIdentity
    func connect(_ request: URLRequest, options: WebSocketOptions) async throws -> any OpenAIWebSocketConnection {
        var checked = request
        guard let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme == "wss"
        else {
            throw OpenAIClientError.invalidConfiguration("X.509 WebSockets require wss")
        }
        components.scheme = "https"
        checked.url = components.url
        try await capability.validate(checked)
        return try await URLSessionWebSocketTransport(clientIdentity: identity, rejectRedirects: true).connect(
            request, options: options)
    }
}
