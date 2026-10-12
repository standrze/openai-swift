import Foundation
import XCTest

@testable import OpenAI

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

final class AuthenticationScopeTests: XCTestCase, @unchecked Sendable {
    private let token =
        #"{"access_token":"token","token_type":"Bearer","issued_token_type":"urn:ietf:params:oauth:token-type:access_token","expires_in":60}"#

    func testIssuerAndAPIShareOneRetryBudget() async throws {
        let issuer = RecordingTransport(stream: [
            .response(streamResponse(text: "", status: 503)),
            .response(streamResponse(text: token)),
        ])
        let provider = try makeProvider(issuer, retries: 2)
        var configuration = testConfiguration(maxRetries: 1)
        configuration.authenticate(using: provider)
        configuration.sharesAuthenticationRetryBudget = true
        let api = RecordingTransport(send: [.response(jsonResponse(status: 503)), .response(jsonResponse())])
        do {
            let _: TestDocument = try await OpenAIClient(configuration: configuration, transport: api).send(
                .get, path: "models")
            XCTFail("Issuer already consumed the one available retry")
        } catch let error as APIError { XCTAssertEqual(error.statusCode, 503) }
        let issuerCount = await issuer.requests.count
        let apiCount = await api.requests.count
        XCTAssertEqual(issuerCount, 2)
        XCTAssertEqual(apiCount, 1)
    }

    func testUnauthorizedRecoveryAfterOrdinaryRetry() async throws {
        let issuer = RecordingTransport(stream: [
            .response(streamResponse(text: token)),
            .response(streamResponse(text: token.replacingOccurrences(of: "\"token\"", with: "\"fresh\""))),
        ])
        let provider = try makeProvider(issuer)
        var configuration = testConfiguration(maxRetries: 2)
        configuration.authenticate(using: provider)
        configuration.sharesAuthenticationRetryBudget = true
        let api = RecordingTransport(send: [
            .response(jsonResponse(status: 503)), .response(jsonResponse(status: 401)), .response(jsonResponse()),
        ])
        let _: TestDocument = try await OpenAIClient(configuration: configuration, transport: api).send(
            .get, path: "models")
        let requests = await api.requests
        XCTAssertEqual(
            requests.map { $0.value(forHTTPHeaderField: "Authorization") },
            ["Bearer token", "Bearer token", "Bearer fresh"])
    }

    func testZeroRetryUnauthorizedStillInvalidatesCache() async throws {
        let issuer = RecordingTransport(stream: [
            .response(streamResponse(text: token)),
            .response(streamResponse(text: token.replacingOccurrences(of: "\"token\"", with: "\"fresh\""))),
        ])
        let provider = try makeProvider(issuer)
        var configuration = testConfiguration()
        configuration.authenticate(using: provider)
        configuration.sharesAuthenticationRetryBudget = true
        let api = RecordingTransport(send: [.response(jsonResponse(status: 401)), .response(jsonResponse())])
        let client = OpenAIClient(configuration: configuration, transport: api)
        do {
            let _: TestDocument = try await client.send(.get, path: "models")
            XCTFail("Expected unauthorized")
        } catch let error as APIError { XCTAssertEqual(error.statusCode, 401) }
        let _: TestDocument = try await client.send(.get, path: "models")
        let requests = await api.requests
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
    }

    func testX509ExchangeUsesCallerDeadlineInsteadOfDefault() async throws {
        let provider = try makeProvider(SlowIssuer(body: token), timeout: 0.01)
        let value = try await RequestDeadline.run(until: Date().addingTimeInterval(1)) {
            try await provider.accessToken()
        }
        XCTAssertEqual(value, "token")
        let defaultProvider = try makeProvider(SlowIssuer(body: token), timeout: 0.01)
        do {
            _ = try await defaultProvider.accessToken()
            XCTFail("Expected default whole-exchange deadline")
        } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
    }

    func testOversizedIssuerErrorRetainsOnlyStatus() async throws {
        let provider = try makeProvider(
            RecordingTransport(stream: [
                .response(streamResponse(text: String(repeating: "secret", count: 300_000), status: 503))
            ]))
        do {
            _ = try await provider.accessToken()
            XCTFail("Expected issuer failure")
        } catch let error as OAuthHTTPError {
            XCTAssertEqual(error.statusCode, 503)
            XCTAssertNil(error.code)
            XCTAssertFalse(error.localizedDescription.contains("secret"))
        }
    }

    func testAdminCredentialSelectionAndExplicitOverride() async throws {
        var configuration = testConfiguration()
        configuration.adminAPIKey = "admin"
        let transport = RecordingTransport(send: Array(repeating: .response(jsonResponse()), count: 4))
        let client = OpenAIClient(configuration: configuration, transport: transport)
        for path in ["models", "organization/users", "projects/p/groups/g/roles"] {
            let _: TestDocument = try await client.send(.get, path: path)
        }
        let _: TestDocument = try await client.send(
            .get, path: "organization/users", options: .init(headers: ["Authorization": "Bearer override"]))
        let requests = await transport.requests
        XCTAssertEqual(
            requests.map { $0.value(forHTTPHeaderField: "Authorization") },
            ["Bearer test-key", "Bearer admin", "Bearer admin", "Bearer override"])
        XCTAssertNil(ClientConfiguration.ollama().adminAPIKey)
        XCTAssertNil(ClientConfiguration.ollama().webhookSecret)
    }

    func testSharedRefreshFollowersKeepTheirOwnRetryBudgets() async throws {
        let issuer = GatedIssuer(body: token)
        let provider = try makeProvider(issuer)
        let leader = Task {
            try await AuthenticationRetryScope.$current.withValue(AuthenticationRetryScope(maximum: 0, maximumDelay: 0))
            {
                try await provider.accessToken()
            }
        }
        while await issuer.attempts == 0 { await Task.yield() }
        let retrying = Task {
            try await AuthenticationRetryScope.$current.withValue(AuthenticationRetryScope(maximum: 1, maximumDelay: 0))
            {
                try await provider.accessToken()
            }
        }
        let exhausted = Task {
            try await AuthenticationRetryScope.$current.withValue(AuthenticationRetryScope(maximum: 0, maximumDelay: 0))
            {
                try await provider.accessToken()
            }
        }
        while await provider.pendingWaiterCount < 3 { await Task.yield() }
        await issuer.release()
        do {
            _ = try await leader.value
            XCTFail("Leader has no retry budget")
        } catch let error as OAuthHTTPError { XCTAssertEqual(error.statusCode, 503) }
        do {
            _ = try await exhausted.value
            XCTFail("Follower has no retry budget")
        } catch let error as OAuthHTTPError { XCTAssertEqual(error.statusCode, 503) }
        let recovered = try await retrying.value
        XCTAssertEqual(recovered, "token")
        let attempts = await issuer.attempts
        XCTAssertEqual(attempts, 2)
    }

    func testTransientOAuthErrorIsRetriedWithoutExposingIssuerContent() async throws {
        let issuer = RecordingTransport(stream: [
            .response(
                streamResponse(text: #"{"error":"temporarily_unavailable","error_description":"secret"}"#, status: 400)),
            .response(streamResponse(text: token)),
        ])
        let provider = try makeProvider(issuer, retries: 2)
        let value = try await provider.accessToken()
        XCTAssertEqual(value, "token")
        let attempts = await issuer.requests.count
        XCTAssertEqual(attempts, 2)
    }

    private func makeProvider(_ transport: any OpenAITransport, retries: Int = 0, timeout: TimeInterval = 30) throws
        -> OAuthTokenProvider
    {
        try OAuthTokenProvider(
            configuration: .init(
                tokenURL: URL(string: "https://mtls.auth.openai.com/oauth/token")!,
                grant: .x509(identityProviderID: "fixture-idp", serviceAccountID: "fixture-account"),
                timeout: timeout, maxRetries: retries, initialRetryDelay: 0, maxRetryDelay: 0), transport: transport)
    }
}

private struct SlowIssuer: OpenAITransport {
    let body: String
    func send(_ request: URLRequest) async throws -> HTTPResponse { throw URLError(.unsupportedURL) }
    func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
        try await Task.sleep(for: .milliseconds(50))
        return streamResponse(text: body)
    }
}

private actor GatedIssuer: OpenAITransport {
    let body: String
    var attempts = 0
    var gate: CheckedContinuation<Void, Never>?
    init(body: String) { self.body = body }
    func release() {
        gate?.resume()
        gate = nil
    }
    func send(_ request: URLRequest) async throws -> HTTPResponse { throw URLError(.unsupportedURL) }
    func stream(_ request: URLRequest) async throws -> HTTPStreamResponse {
        attempts += 1
        if attempts == 1 {
            await withCheckedContinuation { gate = $0 }
            return streamResponse(text: "", status: 503)
        }
        return streamResponse(text: body)
    }
}
