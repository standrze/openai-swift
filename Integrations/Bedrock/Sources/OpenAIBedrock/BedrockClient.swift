import AWSClientRuntime
@_spi(FileBasedConfig) import AWSSDKCommon
import AWSSDKHTTPAuth
import AWSSDKIdentity
import ClientRuntime
import Foundation
import OpenAI
import Smithy
import SmithyHTTPAPI
import SmithyHTTPAuth
import SmithyHTTPAuthAPI
import SmithyIdentity

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Bedrock's OpenAI-compatible endpoint, isolated from ambient OPENAI_* settings.
public enum BedrockClient {
    /// Uses AWS's complete default credential chain, or an explicit profile/resolver, with per-attempt SigV4 signing.
    /// Named-profile regions use the pinned AWS SDK configuration parser alongside its credential resolver.
    static func profileRegion(_ name: String, configFilePath: String? = nil, credentialsFilePath: String? = nil)
        async throws -> String?
    {
        let shared = try await CRTFileBasedConfiguration.makeAsync(
            configFilePath: configFilePath, credentialsFilePath: credentialsFilePath)
        return shared.section(for: name)?.string(for: .region)
    }

    public static func make(
        region: String? = nil, profile: String? = nil, baseURL: URL? = nil,
        credentials: (any AWSCredentialIdentityResolver)? = nil,
        bearerToken: String? = nil, bearerTokenProvider: (@Sendable () async throws -> String)? = nil,
        maxRetries: Int = 2
    ) async throws -> OpenAIClient {
        ClientRuntime.initialize()
        let environment = ProcessInfo.processInfo.environment
        let explicitRegion = region ?? environment["AWS_REGION"] ?? environment["AWS_DEFAULT_REGION"]
        let resolvedRegion: String?
        if let explicitRegion {
            resolvedRegion = explicitRegion
        } else if let profile {
            resolvedRegion = try await profileRegion(profile)
        } else {
            resolvedRegion = try await AWSClientConfigDefaultsProvider.region()
        }
        guard let resolvedRegion, !resolvedRegion.isEmpty,
            resolvedRegion.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 })
        else {
            throw OpenAIClientError.invalidConfiguration("A valid AWS region is required")
        }
        let token = bearerToken ?? environment["AWS_BEARER_TOKEN_BEDROCK"]
        guard !(token != nil && bearerTokenProvider != nil),
            !((token != nil || bearerTokenProvider != nil) && (credentials != nil || profile != nil))
        else {
            throw OpenAIClientError.invalidConfiguration(
                "Bedrock bearer and AWS credential modes are mutually exclusive")
        }
        let environmentAddress: URL?
        if baseURL == nil, let value = environment["AWS_BEDROCK_BASE_URL"] {
            guard let parsed = URL(string: value) else {
                throw OpenAIClientError.invalidConfiguration("Invalid AWS_BEDROCK_BASE_URL")
            }
            environmentAddress = parsed
        } else {
            environmentAddress = nil
        }
        let address =
            baseURL ?? environmentAddress
            ?? URL(string: "https://bedrock-mantle.\(resolvedRegion).api.aws/openai/v1")!
        guard address.scheme == "https", address.host != nil, address.user == nil, address.password == nil,
            address.query == nil, address.fragment == nil
        else {
            throw OpenAIClientError.invalidConfiguration(
                "Bedrock requires an HTTPS base URL without credentials or query")
        }
        var configuration = ClientConfiguration(
            apiKey: token, baseURL: address, organization: nil, project: nil,
            maxRetries: maxRetries, accessTokenProvider: bearerTokenProvider, adminAPIKey: nil, webhookSecret: nil)
        if token == nil, bearerTokenProvider == nil {
            let resolver: any AWSCredentialIdentityResolver =
                credentials
                ?? profile.map { ProfileAWSCredentialIdentityResolver(profileName: $0) }
                ?? DefaultAWSCredentialIdentityResolverChain()
            let signer = BedrockSigner(region: resolvedRegion, resolver: resolver)
            configuration.prepareAttempt = { request, _ in try await signer.sign(request) }
        }
        return OpenAIClient(
            configuration: configuration, transport: OpenAI.URLSessionTransport(redirectPolicy: .rejectAll))
    }
}

struct BedrockSigner: Sendable {
    let region: String
    let resolver: any AWSCredentialIdentityResolver
    func sign(_ request: URLRequest, now: Date = Date()) async throws -> URLRequest {
        ClientRuntime.initialize()
        guard let url = request.url, let method = HTTPMethodType(rawValue: request.httpMethod ?? "GET"),
            request.httpBodyStream == nil
        else {
            throw OpenAIClientError.invalidConfiguration("Bedrock signing requires a replayable request")
        }
        var headers = request.allHTTPHeaderFields ?? [:]
        for key in headers.keys
        where ["authorization", "x-amz-date", "x-amz-security-token"].contains(key.lowercased()) {
            headers.removeValue(forKey: key)
        }
        let unsigned = SmithyHTTPAPI.HTTPRequest(
            method: method, endpoint: try Self.signingEndpoint(url, headers: Headers(headers)),
            body: .data(request.httpBody))
        let credentials = try await resolver.getIdentity(identityProperties: Attributes())
        let signing = AWSSigningConfig(
            credentials: credentials, signedBodyValue: .empty,
            flags: SigningFlags(useDoubleURIEncode: true, shouldNormalizeURIPath: true, omitSessionToken: false),
            date: now, service: "bedrock-mantle", region: region, signatureType: .requestHeaders,
            signingAlgorithm: .sigv4)
        guard
            let signed = await AWSSigV4Signer().sigV4SignedRequest(
                requestBuilder: unsigned.toBuilder(), signingConfig: signing)
        else {
            throw OpenAIClientError.invalidConfiguration("AWS SDK could not sign the Bedrock request")
        }
        // Preserve URLRequest timeout and original escaped URL; only AWS-generated headers change.
        var result = request
        result.allHTTPHeaderFields = [:]
        for header in signed.headers.headers {
            for value in header.value { result.addValue(value, forHTTPHeaderField: header.name) }
        }
        return result
    }

    // Preserve encoded separators and percent signs; URL.path would decode part of the wire path.
    static func signingEndpoint(_ url: URL, headers: Headers) throws -> Endpoint {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            parts.scheme == "https", let host = parts.host,
            parts.port.map({ (1...65_535).contains($0) }) ?? true,
            parts.user == nil, parts.password == nil, parts.fragment == nil
        else { throw OpenAIClientError.invalidConfiguration("Invalid Bedrock signing URL") }
        let uri = URIBuilder().withScheme(.https).withHost(host).withPort(parts.port)
            .withPath(parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath)
            .withQueryItems((parts.percentEncodedQueryItems ?? []).map { URIQueryItem(name: $0.name, value: $0.value) })
            .build()
        return Endpoint(uri: uri, headers: headers)
    }
}
