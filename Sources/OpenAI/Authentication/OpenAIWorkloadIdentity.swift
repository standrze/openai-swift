import Foundation

/// Subject-token types supported by OpenAI workload identity, matching openai-go's jwt/id values.
public enum OpenAIWorkloadIdentitySubjectTokenType: String, Codable, Sendable {
    case jwt
    case id

    var tokenTypeURI: String {
        switch self {
        case .jwt: return "urn:ietf:params:oauth:token-type:jwt"
        case .id: return "urn:ietf:params:oauth:token-type:id_token"
        }
    }
}

extension OAuthConfiguration {
    /// Configures OpenAI's JSON workload identity exchange at auth.openai.com/oauth/token.
    /// Register the identity provider and service account with OpenAI before requesting a token.
    /// Subject-token acquisition remains in the supplied closure; no cloud SDK is required.
    public static func openAIWorkloadIdentity(
        identityProviderID: String,
        serviceAccountID: String,
        subjectTokenProvider: @escaping @Sendable () async throws -> String,
        subjectTokenType: OpenAIWorkloadIdentitySubjectTokenType = .jwt,
        clientID: String? = nil,
        refreshLeeway: TimeInterval = 1_200
    ) -> OAuthConfiguration {
        OAuthConfiguration(
            tokenURL: URL(string: "https://auth.openai.com/oauth/token")!,
            grant: .openAIWorkloadIdentity(
                identityProviderID: identityProviderID,
                serviceAccountID: serviceAccountID,
                subjectTokenProvider: subjectTokenProvider,
                subjectTokenType: subjectTokenType,
                clientID: clientID
            ),
            refreshLeeway: refreshLeeway
        )
    }
}
