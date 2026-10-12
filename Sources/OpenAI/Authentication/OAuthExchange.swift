import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// Kept separate from actor cache ownership so HTTP attempts have no shared mutable state.
enum OAuthExchange {
    private static let accessTokenType = "urn:ietf:params:oauth:token-type:access_token"

    static func fetch(
        configuration: OAuthConfiguration,
        transport: any OpenAITransport,
        now: @escaping @Sendable () -> Date,
        acceptToken: @escaping @Sendable (String) async -> Bool = { _ in true }
    ) async throws -> CachedOAuthToken {
        if case .x509 = configuration.grant {
            let deadline = RequestDeadline.current ?? Date().addingTimeInterval(configuration.timeout)
            return try await RequestDeadline.run(until: deadline) {
                try await attempts(
                    configuration: configuration, transport: transport, now: now, acceptToken: acceptToken)
            }
        }
        return try await attempts(
            configuration: configuration, transport: transport, now: now, acceptToken: acceptToken)
    }

    private static func attempts(
        configuration: OAuthConfiguration, transport: any OpenAITransport, now: @Sendable () -> Date,
        acceptToken: @Sendable (String) async -> Bool
    ) async throws -> CachedOAuthToken {
        for attempt in 0...configuration.maxRetries {
            try Task.checkCancellation()
            let request = try await makeRequest(configuration)
            let requestedAt = now()
            guard requestedAt.timeIntervalSince1970.isFinite else {
                throw OAuthTokenError.invalidResponse("Invalid clock value")
            }
            do {
                let response = try await send(request, configuration: configuration, transport: transport)
                try Task.checkCancellation()
                let x509: Bool
                if case .x509 = configuration.grant { x509 = true } else { x509 = false }
                let failure = OAuthHTTPError(response: response, redactCode: x509)
                if (200..<300).contains(response.statusCode), !failure.retryableOAuthError {
                    let token = try parse(
                        response, configuration: configuration, requestedAt: requestedAt, receivedAt: now())
                    if await acceptToken(token.value) { return token }
                    guard attempt < configuration.maxRetries,
                        AuthenticationRetryScope.current?.retryIssuer() ?? true
                    else {
                        throw OAuthTokenError.invalidResponse("Issuer returned a rejected bearer generation")
                    }
                    continue
                }
                guard attempt < configuration.maxRetries,
                    retryable(response.statusCode) || failure.retryableOAuthError,
                    AuthenticationRetryScope.current?.retryIssuer() ?? true
                else {
                    throw failure
                }
                try await delay(attempt: attempt, headers: response.headers, configuration: configuration, now: now())
            } catch {
                guard attempt < configuration.maxRetries, !Task.isCancelled,
                    let network = error as? URLError,
                    [
                        .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                        .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable,
                    ].contains(network.code), AuthenticationRetryScope.current?.retryIssuer() ?? true
                else { throw error }
                try await delay(attempt: attempt, headers: [:], configuration: configuration, now: now())
            }
        }
        throw OAuthTokenError.invalidResponse("Exchange attempts exhausted")
    }

    private static func send(
        _ original: URLRequest, configuration: OAuthConfiguration, transport: any OpenAITransport
    ) async throws -> HTTPResponse {
        guard case .x509 = configuration.grant else { return try await transport.send(original) }
        var request = original
        if let deadline = RequestDeadline.current {
            request.timeoutInterval = max(0.001, deadline.timeIntervalSinceNow)
        }
        let response = try await transport.stream(request)
        defer { response.cancel() }
        let success = (200..<300).contains(response.statusCode)
        let limit = success ? 1024 * 1024 : 4096
        var data = Data()
        for try await chunk in response.body {
            if chunk.count > limit - data.count {
                if success { throw OAuthTokenError.invalidResponse("X.509 token response exceeds size limit") }
                data.append(chunk.prefix(limit - data.count))
                break
            }
            data.append(chunk)
        }
        return HTTPResponse(data: data, statusCode: response.statusCode, headers: response.headers)
    }

    private static func makeRequest(_ configuration: OAuthConfiguration) async throws -> URLRequest {
        var fields: [(String, String)]
        var clientID: String?
        var clientSecret: String?
        switch configuration.grant {
        case .x509(let identityProviderID, let serviceAccountID):
            var request = URLRequest(url: configuration.tokenURL, timeoutInterval: configuration.timeout)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode([
                "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
                "subject_token_type": "urn:openai:params:oauth:token-type:x509",
                "identity_provider_id": identityProviderID, "service_account_id": serviceAccountID,
            ])
            return request
        case .openAIWorkloadIdentity(let identityProviderID, let serviceAccountID, let provider, let type, let id):
            let subject = try await provider()
            try Task.checkCancellation()
            guard !subject.isEmpty else { throw OAuthTokenError.emptySubjectToken }
            let body = OpenAIWorkloadIdentityRequest(
                grantType: "urn:ietf:params:oauth:grant-type:token-exchange",
                clientID: id.flatMap { $0.isEmpty ? nil : $0 },
                subjectToken: subject,
                subjectTokenType: type.tokenTypeURI,
                identityProviderID: identityProviderID,
                serviceAccountID: serviceAccountID
            )
            var request = URLRequest(url: configuration.tokenURL, timeoutInterval: configuration.timeout)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
            return request
        case .clientCredentials(let id, let secret, let scope):
            fields = [("grant_type", "client_credentials")]
            if let scope { fields.append(("scope", scope)) }
            clientID = id
            clientSecret = secret
        case .tokenExchange(let provider, let type, let audience, let resource, let scope, let id, let secret):
            let subject = try await provider()
            try Task.checkCancellation()
            guard !subject.isEmpty else { throw OAuthTokenError.emptySubjectToken }
            fields = [
                ("grant_type", "urn:ietf:params:oauth:grant-type:token-exchange"),
                ("subject_token", subject),
                ("subject_token_type", type),
                ("requested_token_type", accessTokenType),
            ]
            if let audience { fields.append(("audience", audience)) }
            if let resource { fields.append(("resource", resource)) }
            if let scope { fields.append(("scope", scope)) }
            clientID = id
            clientSecret = secret
        }
        var request = URLRequest(url: configuration.tokenURL, timeoutInterval: configuration.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        if let clientID, let clientSecret {
            switch configuration.clientAuthentication {
            case .basic:
                let credentials = formEncode(clientID) + ":" + formEncode(clientSecret)
                request.setValue(
                    "Basic " + Data(credentials.utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
            case .form:
                fields.append(("client_id", clientID))
                fields.append(("client_secret", clientSecret))
            }
        } else if let clientID {
            fields.append(("client_id", clientID))
        }
        request.httpBody = Data(fields.map { formEncode($0.0) + "=" + formEncode($0.1) }.joined(separator: "&").utf8)
        return request
    }

    private static func parse(
        _ response: HTTPResponse,
        configuration: OAuthConfiguration,
        requestedAt: Date,
        receivedAt: Date
    ) throws -> CachedOAuthToken {
        if case .x509 = configuration.grant, response.data.count > 1024 * 1024 {
            throw OAuthTokenError.invalidResponse("X.509 token response exceeds size limit")
        }
        if case .x509 = configuration.grant {
            do {
                let document = try JSONDocument(data: response.data, rejectDuplicateKeys: true)
                let lifetime = document.field(at: [.key("expires_in")]).rawString ?? ""
                guard !lifetime.isEmpty, lifetime.utf8.allSatisfy({ (48...57).contains($0) }),
                    let seconds = Int64(lifetime), (1...3_600).contains(seconds)
                else { throw OAuthTokenError.invalidResponse("Invalid X.509 token lifetime") }
            } catch {
                throw OAuthTokenError.invalidResponse("Invalid X.509 token JSON or lifetime")
            }
        }
        let token: OAuthTokenResponse
        do {
            token = try JSONDecoder().decode(OAuthTokenResponse.self, from: response.data)
        } catch {
            throw OAuthTokenError.invalidResponse("Expected access_token, token_type, and numeric expires_in")
        }
        guard token.error == nil else {
            throw OAuthTokenError.invalidResponse("Token endpoint returned an OAuth error")
        }
        guard !token.accessToken.isEmpty,
            !token.accessToken.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0)
                    || CharacterSet.controlCharacters.contains($0)
            })
        else { throw OAuthTokenError.invalidResponse("Access token is empty or contains header whitespace") }
        guard token.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame else {
            throw OAuthTokenError.invalidResponse("Only Bearer access tokens are supported")
        }
        let expiresIn: Double
        if let seconds = token.expiresIn {
            expiresIn = seconds
        } else if case .openAIWorkloadIdentity = configuration.grant {
            // The Go model defaults an omitted expires_in to one hour for this endpoint.
            expiresIn = 3_600
        } else {
            throw OAuthTokenError.invalidResponse("Expected numeric expires_in")
        }
        guard expiresIn.isFinite, expiresIn > 0 else {
            throw OAuthTokenError.invalidResponse("expires_in must be positive and finite")
        }
        if case .x509 = configuration.grant {
            let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~+/".utf8)
            let unpadded = token.accessToken.dropLast(
                token.accessToken.reversed().prefix(while: { $0 == "=" }).count)
            guard !unpadded.isEmpty, unpadded.utf8.allSatisfy(allowed.contains) else {
                throw OAuthTokenError.invalidResponse("Invalid X.509 bearer token")
            }
            guard token.issuedTokenType == accessTokenType, expiresIn <= 3_600 else {
                throw OAuthTokenError.invalidResponse(
                    "X.509 requires an access token with a lifetime of at most one hour")
            }
        }
        if case .tokenExchange = configuration.grant {
            guard let type = token.issuedTokenType, URL(string: type)?.scheme != nil else {
                throw OAuthTokenError.invalidResponse("Token exchange requires an absolute issued_token_type URI")
            }
        }
        guard receivedAt.timeIntervalSince1970.isFinite, receivedAt >= requestedAt else {
            throw OAuthTokenError.invalidResponse("Invalid clock progression")
        }
        let lifetime = min(expiresIn, configuration.maxTokenLifetime)
        let expiresAt = requestedAt.addingTimeInterval(lifetime)
        let remaining = expiresAt.timeIntervalSince(receivedAt)
        guard expiresAt.timeIntervalSince1970.isFinite, remaining > 0 else {
            throw OAuthTokenError.invalidResponse("Token expired before exchange completed")
        }
        let leeway = min(configuration.refreshLeeway, remaining / 2)
        return CachedOAuthToken(
            value: token.accessToken,
            receivedAt: receivedAt,
            expiresAt: expiresAt,
            refreshAfter: expiresAt.addingTimeInterval(-leeway)
        )
    }

    // OAuth's Basic credentials use the same UTF-8 form encoding as its entity body.
    private static func formEncode(_ value: String) -> String {
        let hex = Array("0123456789ABCDEF".utf8)
        var encoded: [UInt8] = []
        for byte in value.utf8 {
            switch byte {
            case 65...90, 97...122, 48...57, 42, 45, 46, 95:
                encoded.append(byte)
            case 32:
                encoded.append(43)
            default:
                encoded.append(contentsOf: [37, hex[Int(byte >> 4)], hex[Int(byte & 15)]])
            }
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    private static func retryable(_ status: Int) -> Bool {
        [408, 409, 429].contains(status) || (500..<600).contains(status)
    }

    private static func delay(
        attempt: Int,
        headers: [String: String],
        configuration: OAuthConfiguration,
        now: Date
    ) async throws {
        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        var serverDelay = header("retry-after-ms").flatMap(Double.init).map { $0 / 1000 }
        if serverDelay == nil, let value = header("retry-after") {
            serverDelay = Double(value)
            if serverDelay == nil {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                serverDelay = formatter.date(from: value)?.timeIntervalSince(now)
            }
        }
        let backoff = configuration.initialRetryDelay * pow(2, Double(attempt))
        let seconds = min(
            min(
                AuthenticationRetryScope.current?.maximumDelay ?? configuration.maxRetryDelay,
                configuration.maxRetryDelay),
            serverDelay.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? backoff)
        try Task.checkCancellation()
        if seconds > 0 { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    }
}

private struct OAuthTokenResponse: Decodable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Double?
    let issuedTokenType: String?
    let error: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case error
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case issuedTokenType = "issued_token_type"
    }
}

private struct OpenAIWorkloadIdentityRequest: Encodable {
    let grantType: String
    let clientID: String?
    let subjectToken: String
    let subjectTokenType: String
    let identityProviderID: String
    let serviceAccountID: String

    private enum CodingKeys: String, CodingKey {
        case grantType = "grant_type"
        case clientID = "client_id"
        case subjectToken = "subject_token"
        case subjectTokenType = "subject_token_type"
        case identityProviderID = "identity_provider_id"
        case serviceAccountID = "service_account_id"
    }
}
