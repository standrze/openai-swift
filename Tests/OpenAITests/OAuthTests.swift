import Foundation
import XCTest

@testable import OpenAI

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

final class OAuthTests: XCTestCase {
    func testRFC6749ClientCredentialsBasicRequest() async throws {
        let transport = OAuthFixtureTransport([.response(tokenResponse("token"))])
        let configuration = OAuthConfiguration(
            tokenURL: URL(string: "https://identity.example/token?tenant=one")!,
            grant: .clientCredentials(clientID: "s6BhdRkqt3", clientSecret: "gX1fBat3bV"),
            timeout: 19
        )
        let provider = try OAuthTokenProvider(configuration: configuration, transport: transport)
        let token = try await provider.accessToken()
        XCTAssertEqual(token, "token")
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://identity.example/token?tenant=one")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 19)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic czZCaGRSa3F0MzpnWDFmQmF0M2JW")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8), "grant_type=client_credentials")
    }

    func testBasicCredentialsAreFormEncodedBeforeBase64() async throws {
        let transport = OAuthFixtureTransport([.response(tokenResponse("token"))])
        let provider = try OAuthTokenProvider(
            configuration: configuration(
                grant: .clientCredentials(clientID: "client:a+b π", clientSecret: "p@ss:word&=+")),
            transport: transport
        )
        _ = try await provider.accessToken()
        let requests = await transport.requests
        let authorization = try XCTUnwrap(requests.first?.value(forHTTPHeaderField: "Authorization"))
        let encoded = try XCTUnwrap(Data(base64Encoded: String(authorization.dropFirst(6))))
        XCTAssertEqual(String(data: encoded, encoding: .utf8), "client%3Aa%2Bb+%CF%80:p%40ss%3Aword%26%3D%2B")
    }

    func testFormAuthenticationEscapesValuesAndDoesNotAlsoUseBasic() async throws {
        let transport = OAuthFixtureTransport([.response(tokenResponse("token"))])
        var settings = configuration(
            grant: .clientCredentials(
                clientID: "id&=+", clientSecret: "secret π", scope: "read write"
            ))
        settings.clientAuthentication = .form
        let provider = try OAuthTokenProvider(configuration: settings, transport: transport)
        _ = try await provider.accessToken()
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(
            try form(request),
            [
                "grant_type": "client_credentials", "client_id": "id&=+", "client_secret": "secret π",
                "scope": "read write",
            ])
        XCTAssertTrue(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8)?.contains("%CF%80") == true)
    }

    func testRFC8693ExchangeFieldsAndPublicClientIdentifier() async throws {
        let transport = OAuthFixtureTransport([.response(tokenResponse("exchanged"))])
        let provider = try OAuthTokenProvider(
            configuration: configuration(
                grant: .tokenExchange(
                    subjectTokenProvider: { "subject=+/π" },
                    audience: "urn:example:api",
                    resource: "https://resource.example/v1",
                    scope: "models.read responses.write",
                    clientID: "public-client"
                )),
            transport: transport
        )
        let token = try await provider.accessToken()
        XCTAssertEqual(token, "exchanged")
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(
            try form(request),
            [
                "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
                "subject_token": "subject=+/π",
                "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
                "requested_token_type": "urn:ietf:params:oauth:token-type:access_token",
                "audience": "urn:example:api",
                "resource": "https://resource.example/v1",
                "scope": "models.read responses.write",
                "client_id": "public-client",
            ])
    }

    func testOpenAIWorkloadIdentityFactoryMatchesPinnedJSONRequest() async throws {
        let transport = OAuthFixtureTransport([.response(tokenResponse("openai_access"))])
        let settings = OAuthConfiguration.openAIWorkloadIdentity(
            identityProviderID: "idp_123",
            serviceAccountID: "svc_acct_456",
            subjectTokenProvider: { "subject.+/π" },
            clientID: "client_789"
        )
        XCTAssertEqual(settings.tokenURL.absoluteString, "https://auth.openai.com/oauth/token")
        XCTAssertEqual(settings.refreshLeeway, 1_200)
        let provider = try OAuthTokenProvider(configuration: settings, transport: transport)
        let accessToken = try await provider.accessToken()
        XCTAssertEqual(accessToken, "openai_access")
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url, settings.tokenURL)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(request.httpBody))
        XCTAssertEqual(
            body,
            [
                "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
                "client_id": "client_789",
                "subject_token": "subject.+/π",
                "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
                "identity_provider_id": "idp_123",
                "service_account_id": "svc_acct_456",
            ])
    }

    func testOpenAIIDSubjectTokensOmitAbsentAndEmptyClientIdentifiers() async throws {
        XCTAssertNil(OpenAIWorkloadIdentitySubjectTokenType(rawValue: "unsupported"))
        XCTAssertEqual(OpenAIWorkloadIdentitySubjectTokenType.jwt.rawValue, "jwt")
        XCTAssertEqual(OpenAIWorkloadIdentitySubjectTokenType.id.rawValue, "id")
        for clientID in [nil, ""] as [String?] {
            let transport = OAuthFixtureTransport([.response(tokenResponse("openai_access"))])
            let settings = OAuthConfiguration(
                tokenURL: URL(string: "http://localhost:8090/token")!,
                grant: .openAIWorkloadIdentity(
                    identityProviderID: "idp_123", serviceAccountID: "svc_acct_456",
                    subjectTokenProvider: { "id-token" }, subjectTokenType: .id, clientID: clientID
                )
            )
            let provider = try OAuthTokenProvider(configuration: settings, transport: transport)
            _ = try await provider.accessToken()
            let requests = await transport.requests
            let request = try XCTUnwrap(requests.first)
            XCTAssertEqual(request.url?.absoluteString, "http://localhost:8090/token")
            let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(request.httpBody))
            XCTAssertEqual(body["subject_token_type"], "urn:ietf:params:oauth:token-type:id_token")
            XCTAssertNil(body["client_id"])
            XCTAssertNil(body["scope"])
            XCTAssertNil(body["audience"])
            XCTAssertNil(body["requested_token_type"])
        }
    }

    func testOpenAIWorkloadIdentityRejectsInvalidRequiredIdentifiers() {
        for invalid in ["", " ", "idp_123\n", "svc\u{0000}acct"] {
            for pair in [(invalid, "svc_acct_456"), ("idp_123", invalid)] {
                let settings = OAuthConfiguration.openAIWorkloadIdentity(
                    identityProviderID: pair.0, serviceAccountID: pair.1, subjectTokenProvider: { "subject" })
                XCTAssertThrowsError(try OAuthTokenProvider(configuration: settings))
            }
        }
        let settings = OAuthConfiguration.openAIWorkloadIdentity(
            identityProviderID: "idp_123", serviceAccountID: "svc_acct_456",
            subjectTokenProvider: { "subject" }, clientID: "bad\nclient")
        XCTAssertThrowsError(try OAuthTokenProvider(configuration: settings))
    }

    func testOpenAIWorkloadIdentityDefaultsMissingExpiryToOneHour() async throws {
        let clock = OAuthFixtureClock()
        let body = Data(#"{"access_token":"default_expiry","token_type":"Bearer"}"#.utf8)
        let transport = OAuthFixtureTransport([
            .response(HTTPResponse(data: body, statusCode: 200)), .response(tokenResponse("refreshed")),
        ])
        let settings = OAuthConfiguration.openAIWorkloadIdentity(
            identityProviderID: "idp_123", serviceAccountID: "svc_acct_456", subjectTokenProvider: { "subject" })
        let provider = try OAuthTokenProvider(configuration: settings, transport: transport, now: { clock.now() })
        let first = try await provider.accessToken()
        clock.advance(2_399)
        let cached = try await provider.accessToken()
        clock.advance(1)
        let refreshed = try await provider.accessToken()
        XCTAssertEqual([first, cached, refreshed], ["default_expiry", "default_expiry", "refreshed"])
        let count = await transport.requests.count
        XCTAssertEqual(count, 2)
    }

    func testOpenAIWorkloadIdentityHonorsResponseExpiryAndRejectsInvalidExpiry() async throws {
        let settings = OAuthConfiguration.openAIWorkloadIdentity(
            identityProviderID: "idp_123", serviceAccountID: "svc_acct_456", subjectTokenProvider: { "subject" })
        let clock = OAuthFixtureClock()
        let transport = OAuthFixtureTransport([
            .response(tokenResponse("short", expires: 60)), .response(tokenResponse("fresh")),
        ])
        let provider = try OAuthTokenProvider(configuration: settings, transport: transport, now: { clock.now() })
        let first = try await provider.accessToken()
        clock.advance(29)
        let cached = try await provider.accessToken()
        clock.advance(1)
        let fresh = try await provider.accessToken()
        XCTAssertEqual([first, cached, fresh], ["short", "short", "fresh"])
        for expires in ["0", "-1", "1e999", #""60""#] {
            let body = Data("{\"access_token\":\"invalid\",\"token_type\":\"Bearer\",\"expires_in\":\(expires)}".utf8)
            let invalid = try OAuthTokenProvider(
                configuration: settings,
                transport: OAuthFixtureTransport([.response(HTTPResponse(data: body, statusCode: 200))])
            )
            do {
                _ = try await invalid.accessToken()
                XCTFail("Invalid OpenAI workload identity expiry must fail")
            } catch {
                XCTAssertTrue(error is OAuthTokenError)
            }
        }
    }

    func testOpenAIWorkloadIdentityEmptySubjectFailsBeforeSending() async throws {
        let transport = OAuthFixtureTransport([])
        let settings = OAuthConfiguration.openAIWorkloadIdentity(
            identityProviderID: "idp_123", serviceAccountID: "svc_acct_456", subjectTokenProvider: { "" })
        let provider = try OAuthTokenProvider(configuration: settings, transport: transport)
        do {
            _ = try await provider.accessToken()
            XCTFail("Empty OpenAI workload identity subject must fail")
        } catch {
            XCTAssertEqual(error as? OAuthTokenError, .emptySubjectToken)
        }
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
    }

    func testCachedExpiryAndEarlyRefreshUseInjectedClock() async throws {
        let clock = OAuthFixtureClock()
        let transport = OAuthFixtureTransport([
            .response(tokenResponse("one", expires: 100)), .response(tokenResponse("two")),
        ])
        let provider = try OAuthTokenProvider(
            configuration: configuration(), transport: transport, now: { clock.now() })
        let first = try await provider.accessToken()
        clock.advance(69)
        let cached = try await provider.accessToken()
        clock.advance(1)
        let refreshed = try await provider.accessToken()
        XCTAssertEqual([first, cached, refreshed], ["one", "one", "two"])
        let count = await transport.requests.count
        XCTAssertEqual(count, 2)
    }

    func testShortTokensAndMaximumCacheLifetime() async throws {
        let clock = OAuthFixtureClock()
        let transport = OAuthFixtureTransport([
            .response(tokenResponse("short", expires: 10)), .response(tokenResponse("long", expires: 3600)),
            .response(tokenResponse("fresh")),
        ])
        var settings = configuration()
        settings.maxTokenLifetime = 60
        let provider = try OAuthTokenProvider(configuration: settings, transport: transport, now: { clock.now() })
        let first = try await provider.accessToken()
        clock.advance(4)
        let cached = try await provider.accessToken()
        clock.advance(1)
        let long = try await provider.accessToken()
        clock.advance(30)
        let fresh = try await provider.accessToken()
        XCTAssertEqual([first, cached, long, fresh], ["short", "short", "long", "fresh"])
    }

    func testConcurrentCallersShareOneExchange() async throws {
        let gate = OAuthFixtureGate()
        let transport = OAuthFixtureTransport([.response(tokenResponse("shared"))], gate: gate)
        let provider = try OAuthTokenProvider(configuration: configuration(), transport: transport)
        let tasks = (0..<12).map { _ in Task { try await provider.accessToken() } }
        await transport.waitForRequests(1)
        await gate.release()
        for task in tasks {
            let token = try await task.value
            XCTAssertEqual(token, "shared")
        }
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }

    func testCancelledWaiterStopsWithoutCancellingOtherWaiters() async throws {
        let gate = OAuthFixtureGate()
        let transport = OAuthFixtureTransport([.response(tokenResponse("shared"))], gate: gate)
        let provider = try OAuthTokenProvider(configuration: configuration(), transport: transport)
        let cancelled = Task { try await provider.accessToken() }
        await transport.waitForRequests(1)
        let other = Task { try await provider.accessToken() }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled caller must not return a token")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        // The cancelled caller returns while the HTTP response is still gated.
        await gate.release()
        let token = try await other.value
        XCTAssertEqual(token, "shared")
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }

    func testInvalidationPreventsStaleRefreshFromRepopulatingCache() async throws {
        let gate = OAuthFixtureGate()
        let transport = OAuthFixtureTransport(
            [
                .response(tokenResponse("stale")), .response(tokenResponse("fresh")),
            ], gate: gate)
        let provider = try OAuthTokenProvider(configuration: configuration(), transport: transport)
        let original = Task { try await provider.accessToken() }
        await transport.waitForRequests(1)
        await provider.invalidate()
        do {
            _ = try await original.value
            XCTFail("Invalidated waiter must fail")
        } catch {
            XCTAssertEqual(error as? OAuthTokenError, .invalidated)
        }
        let replacement = Task { try await provider.accessToken() }
        await transport.waitForRequests(2)
        await gate.release()
        let fresh = try await replacement.value
        let cached = try await provider.accessToken()
        XCTAssertEqual([fresh, cached], ["fresh", "fresh"])
    }

    func testHTTPErrorRedactsIssuerBodyAndFailureIsNotCached() async throws {
        let body = Data(#"{"error":"invalid_client","error_description":"Client authentication failed"}"#.utf8)
        let transport = OAuthFixtureTransport([
            .response(HTTPResponse(data: body, statusCode: 400)), .response(tokenResponse("recovered")),
        ])
        let provider = try OAuthTokenProvider(configuration: configuration(), transport: transport)
        do {
            _ = try await provider.accessToken()
            XCTFail("Expected token endpoint failure")
        } catch let error as OAuthHTTPError {
            XCTAssertEqual(error.statusCode, 400)
            XCTAssertEqual(error.code, "invalid_client")
            XCTAssertFalse(error.localizedDescription.contains("Client authentication failed"))
        }
        let recovered = try await provider.accessToken()
        XCTAssertEqual(recovered, "recovered")
    }

    func testInvalidTokenTypesExpiryAndMissingFieldsFail() async throws {
        let invalid = [
            #"{"access_token":"a","token_type":"MAC","expires_in":60}"#,
            #"{"access_token":"a","token_type":"Bearer","expires_in":0}"#,
            #"{"access_token":"a","token_type":"Bearer","expires_in":-1}"#,
            #"{"access_token":"a","token_type":"Bearer","expires_in":"60"}"#,
            #"{"access_token":"a","token_type":"Bearer"}"#,
            #"{"access_token":"","token_type":"Bearer","expires_in":60}"#,
            #"{"access_token":"a\nb","token_type":"Bearer","expires_in":60}"#,
            #"{"access_token":"a","token_type":"Bearer","expires_in":1e999}"#,
        ]
        for fixture in invalid {
            let transport = OAuthFixtureTransport([.response(HTTPResponse(data: Data(fixture.utf8), statusCode: 200))])
            let provider = try OAuthTokenProvider(configuration: configuration(), transport: transport)
            do {
                _ = try await provider.accessToken()
                XCTFail("Invalid token response must fail")
            } catch {
                XCTAssertTrue(error is OAuthTokenError)
            }
        }
    }

    func testBearerTypeIsCaseInsensitiveAndExchangeRequiresIssuedType() async throws {
        let lower = HTTPResponse(
            data: Data(#"{"access_token":"a","token_type":"bearer","expires_in":60}"#.utf8), statusCode: 200)
        let transport = OAuthFixtureTransport([.response(lower)])
        let provider = try OAuthTokenProvider(configuration: configuration(), transport: transport)
        let token = try await provider.accessToken()
        XCTAssertEqual(token, "a")
        let exchange = try OAuthTokenProvider(
            configuration: configuration(grant: .tokenExchange(subjectTokenProvider: { "jwt" })),
            transport: OAuthFixtureTransport([.response(lower)])
        )
        do {
            _ = try await exchange.accessToken()
            XCTFail("RFC 8693 issued_token_type is required")
        } catch {
            XCTAssertTrue(error is OAuthTokenError)
        }
    }

    func testRetryBudgetAndNetworkErrors() async throws {
        var settings = configuration()
        settings.maxRetries = 2
        settings.initialRetryDelay = 0
        settings.maxRetryDelay = 0
        let transport = OAuthFixtureTransport([
            .networkError(.timedOut),
            .response(HTTPResponse(data: Data("{}".utf8), statusCode: 429, headers: ["Retry-After": "0"])),
            .response(tokenResponse("retried")),
        ])
        let provider = try OAuthTokenProvider(configuration: settings, transport: transport)
        let token = try await provider.accessToken()
        XCTAssertEqual(token, "retried")
        let count = await transport.requests.count
        XCTAssertEqual(count, 3)
    }

    func testSubjectProviderIsCalledAgainOnlyWhenExchangeRefreshes() async throws {
        let clock = OAuthFixtureClock()
        let subjects = OAuthFixtureCounter()
        let transport = OAuthFixtureTransport([
            .response(tokenResponse("one", expires: 60)), .response(tokenResponse("two", expires: 60)),
        ])
        let provider = try OAuthTokenProvider(
            configuration: configuration(grant: .tokenExchange(subjectTokenProvider: { await subjects.next() })),
            transport: transport,
            now: { clock.now() }
        )
        _ = try await provider.accessToken()
        _ = try await provider.accessToken()
        clock.advance(31)
        _ = try await provider.accessToken()
        let requests = await transport.requests
        XCTAssertEqual(try requests.map { try form($0)["subject_token"] }, ["subject_1", "subject_2"])
    }

    func testEmptySubjectTokenFailsBeforeSendingCredentials() async throws {
        let transport = OAuthFixtureTransport([])
        let provider = try OAuthTokenProvider(
            configuration: configuration(grant: .tokenExchange(subjectTokenProvider: { "" })),
            transport: transport
        )
        do {
            _ = try await provider.accessToken()
            XCTFail("Empty subject token must fail")
        } catch {
            XCTAssertEqual(error as? OAuthTokenError, .emptySubjectToken)
        }
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
    }

    func testInvalidConfigurationRejectsUnsafeURLsAndPolicies() {
        for address in [
            "http://identity.example/token", "ftp://localhost/token", "https://user:secret@identity.example/token",
            "https://identity.example/token#fragment",
        ] {
            var settings = configuration()
            settings.tokenURL = URL(string: address)!
            XCTAssertThrowsError(try OAuthTokenProvider(configuration: settings))
        }
        for address in ["http://localhost/token", "http://127.0.0.1/token", "http://[::1]/token"] {
            var settings = configuration()
            settings.tokenURL = URL(string: address)!
            XCTAssertNoThrow(try OAuthTokenProvider(configuration: settings))
        }
        for value in [-1.0, .infinity, .nan] {
            var settings = configuration()
            settings.refreshLeeway = value
            XCTAssertThrowsError(try OAuthTokenProvider(configuration: settings))
        }
        XCTAssertThrowsError(
            try OAuthTokenProvider(
                configuration: configuration(
                    grant: .tokenExchange(subjectTokenProvider: { "token" }, clientSecret: "secret")
                )))
    }

    func testAccessTokenProviderConnectsToClientConfiguration() async throws {
        let tokens = OAuthFixtureTransport([.response(tokenResponse("oauth_access"))])
        let provider = try OAuthTokenProvider(configuration: configuration(), transport: tokens)
        let api = OAuthFixtureTransport([.response(HTTPResponse(data: Data("{}".utf8), statusCode: 200))])
        let settings = ClientConfiguration(
            apiKey: nil,
            baseURL: URL(string: "https://api.example/v1")!,
            accessTokenProvider: { try await provider.accessToken() }
        )
        let client = OpenAIClient(configuration: settings, transport: api)
        let _: JSONValue = try await client.send(.get, path: "models")
        let requests = await api.requests
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer oauth_access")
    }

    private func configuration(grant: OAuthGrant? = nil) -> OAuthConfiguration {
        OAuthConfiguration(
            tokenURL: URL(string: "https://identity.example/token")!,
            grant: grant ?? .clientCredentials(clientID: "client", clientSecret: "secret")
        )
    }

    private func tokenResponse(_ token: String, expires: Double = 3600) -> HTTPResponse {
        let payload: JSONValue = [
            "access_token": .string(token), "token_type": "Bearer", "expires_in": .number(expires),
            "issued_token_type": "urn:ietf:params:oauth:token-type:access_token",
        ]
        return HTTPResponse(data: try! JSONEncoder().encode(payload), statusCode: 200)
    }

    private func form(_ request: URLRequest) throws -> [String: String] {
        let body = try XCTUnwrap(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8))
        return try Dictionary(
            uniqueKeysWithValues: body.split(separator: "&").map { pair in
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = try XCTUnwrap(
                    String(parts[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding)
                let value = try XCTUnwrap(
                    String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding)
                return (key, value)
            })
    }
}

private enum OAuthFixtureResult: Sendable {
    case response(HTTPResponse)
    case networkError(URLError.Code)
}

private actor OAuthFixtureTransport: OpenAITransport {
    private var results: [OAuthFixtureResult]
    private let gate: OAuthFixtureGate?
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var requests: [URLRequest] = []

    init(_ results: [OAuthFixtureResult], gate: OAuthFixtureGate? = nil) {
        self.results = results
        self.gate = gate
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        let ready = requestWaiters.filter { $0.0 <= requests.count }
        requestWaiters.removeAll { $0.0 <= requests.count }
        for (_, waiter) in ready { waiter.resume() }
        guard !results.isEmpty else { throw OAuthTokenError.invalidResponse("Fixture responses exhausted") }
        let result = results.removeFirst()
        if let gate { await gate.wait() }
        switch result {
        case .response(let response): return response
        case .networkError(let code): throw URLError(code)
        }
    }

    func stream(_ request: URLRequest) async throws -> HTTPStreamResponse { throw URLError(.unsupportedURL) }

    func waitForRequests(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { requestWaiters.append((count, $0)) }
    }
}

private actor OAuthFixtureGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private final class OAuthFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date(timeIntervalSince1970: 1_700_000_000)

    func now() -> Date { lock.withLock { time } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time.addTimeInterval(seconds) } }
}

private actor OAuthFixtureCounter {
    private var value = 0
    func next() -> String {
        value += 1
        return "subject_\(value)"
    }
}
