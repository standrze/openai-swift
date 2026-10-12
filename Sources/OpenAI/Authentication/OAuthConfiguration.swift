import Foundation

/// Standard OAuth grants and OpenAI's explicit workload identity exchange.
/// Cloud-specific identity acquisition belongs to the supplied subject-token provider.
public enum OAuthGrant: Sendable {
    case x509(identityProviderID: String, serviceAccountID: String)
    case clientCredentials(clientID: String, clientSecret: String, scope: String? = nil)
    case tokenExchange(
        subjectTokenProvider: @Sendable () async throws -> String,
        subjectTokenType: String = "urn:ietf:params:oauth:token-type:jwt",
        audience: String? = nil,
        resource: String? = nil,
        scope: String? = nil,
        clientID: String? = nil,
        clientSecret: String? = nil
    )
    /// OpenAI's JSON exchange with registered identity-provider and service-account identifiers.
    /// Use `OAuthConfiguration.openAIWorkloadIdentity` to select OpenAI's token endpoint.
    case openAIWorkloadIdentity(
        identityProviderID: String,
        serviceAccountID: String,
        subjectTokenProvider: @Sendable () async throws -> String,
        subjectTokenType: OpenAIWorkloadIdentitySubjectTokenType = .jwt,
        clientID: String? = nil
    )
}

/// How a confidential OAuth client authenticates to the token endpoint.
public enum OAuthClientAuthentication: Sendable {
    /// RFC 6749 HTTP Basic with separately form-encoded client identifier and secret.
    case basic
    /// Sends client_id/client_secret as form fields for servers configured for client_secret_post.
    case form
}

/// Token endpoint, grant, and cache policy, copied when constructing an `OAuthTokenProvider`.
public struct OAuthConfiguration: Sendable {
    /// Optional cooldown using an unexpired, unrejected cached token after a transient proactive refresh failure.
    public var refreshFailureCooldown: TimeInterval = 0
    public var tokenURL: URL
    public var grant: OAuthGrant
    public var clientAuthentication: OAuthClientAuthentication
    public var timeout: TimeInterval
    public var maxRetries: Int
    public var initialRetryDelay: TimeInterval
    public var maxRetryDelay: TimeInterval
    /// Refresh this many seconds early, capped at half the token's remaining lifetime.
    public var refreshLeeway: TimeInterval
    /// Caps cache residence in seconds; does not extend or modify the server's token expiration.
    public var maxTokenLifetime: TimeInterval

    public init(
        tokenURL: URL,
        grant: OAuthGrant,
        clientAuthentication: OAuthClientAuthentication = .basic,
        timeout: TimeInterval = 30,
        maxRetries: Int = 0,
        initialRetryDelay: TimeInterval = 0.5,
        maxRetryDelay: TimeInterval = 8,
        refreshLeeway: TimeInterval = 30,
        maxTokenLifetime: TimeInterval = 86_400
    ) {
        self.tokenURL = tokenURL
        self.grant = grant
        self.clientAuthentication = clientAuthentication
        self.timeout = timeout
        self.maxRetries = maxRetries
        self.initialRetryDelay = initialRetryDelay
        self.maxRetryDelay = maxRetryDelay
        self.refreshLeeway = refreshLeeway
        self.maxTokenLifetime = maxTokenLifetime
    }

    func validate() throws {
        guard let components = URLComponents(url: tokenURL, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased(), !host.isEmpty,
            components.user == nil, components.password == nil, components.fragment == nil,
            components.port.map({ (1...65_535).contains($0) }) ?? true
        else {
            throw OpenAIClientError.invalidConfiguration(
                "OAuth token URL must be absolute without credentials or fragment")
        }
        let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard scheme == "https" || (scheme == "http" && local) else {
            throw OpenAIClientError.invalidConfiguration("OAuth token URL requires HTTPS except for loopback fixtures")
        }
        guard refreshFailureCooldown.isFinite, (0...300).contains(refreshFailureCooldown),
            timeout.isFinite, timeout > 0, maxRetries >= 0, maxRetries <= 10,
            initialRetryDelay.isFinite, initialRetryDelay >= 0,
            maxRetryDelay.isFinite, maxRetryDelay >= 0, maxRetryDelay <= 60,
            refreshLeeway.isFinite, refreshLeeway >= 0,
            maxTokenLifetime.isFinite, maxTokenLifetime > 0
        else {
            throw OpenAIClientError.invalidConfiguration("Invalid OAuth timeout, retry, or cache policy")
        }
        switch grant {
        case .x509(let identityProviderID, let serviceAccountID):
            guard tokenURL.absoluteString == "https://mtls.auth.openai.com/oauth/token",
                !identityProviderID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !serviceAccountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw OpenAIClientError.invalidConfiguration(
                    "X.509 requires the global mTLS issuer and identity identifiers")
            }
        case .clientCredentials(let id, let secret, _):
            guard !id.isEmpty, !secret.isEmpty else {
                throw OpenAIClientError.invalidConfiguration("OAuth client credentials must not be empty")
            }
        case .tokenExchange(_, let type, _, let resource, _, let id, let secret):
            guard !type.isEmpty, URL(string: type)?.scheme != nil else {
                throw OpenAIClientError.invalidConfiguration("OAuth subject token type must be an absolute URI")
            }
            if let resource {
                guard let url = URL(string: resource), url.scheme != nil, url.fragment == nil else {
                    throw OpenAIClientError.invalidConfiguration(
                        "OAuth resource must be an absolute URI without a fragment")
                }
            }
            if secret != nil, id == nil {
                throw OpenAIClientError.invalidConfiguration("OAuth client secret requires a client identifier")
            }
            if id?.isEmpty == true || secret?.isEmpty == true {
                throw OpenAIClientError.invalidConfiguration("OAuth client credentials must not be empty when supplied")
            }
        case .openAIWorkloadIdentity(let identityProviderID, let serviceAccountID, _, _, let clientID):
            for identifier in [identityProviderID, serviceAccountID] {
                guard !identifier.isEmpty,
                    !identifier.unicodeScalars.contains(where: {
                        CharacterSet.whitespacesAndNewlines.contains($0)
                            || CharacterSet.controlCharacters.contains($0)
                    })
                else {
                    throw OpenAIClientError.invalidConfiguration(
                        "OpenAI workload identity requires identity-provider and service-account identifiers without whitespace"
                    )
                }
            }
            if let clientID,
                clientID.unicodeScalars.contains(where: {
                    CharacterSet.whitespacesAndNewlines.contains($0)
                        || CharacterSet.controlCharacters.contains($0)
                })
            {
                throw OpenAIClientError.invalidConfiguration("Invalid OpenAI workload identity client identifier")
            }
        }
    }
}
