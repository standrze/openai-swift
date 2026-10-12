import Foundation
import XCTest

@testable import OpenAI

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

final class OAuthRecoveryTests: XCTestCase, @unchecked Sendable {
    func testRejectedGenerationCannotBeReissuedOrEvictNewerToken() async throws {
        let transport = RecordingTransport(send: [token("old"), token("old"), token("fresh")])
        let provider = try OAuthTokenProvider(configuration: configuration(), transport: transport)
        let old = try await provider.accessToken()
        _ = await provider.invalidate(ifToken: old)
        do {
            _ = try await provider.accessToken()
            XCTFail("Rejected token reissued")
        } catch {}
        let fresh = try await provider.accessToken()
        XCTAssertEqual(fresh, "fresh")
        _ = await provider.invalidate(ifToken: old)
        let preserved = try await provider.accessToken()
        XCTAssertEqual(preserved, "fresh")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
    }

    func testProactiveRefreshFailureUsesOnlyUnexpiredTokenDuringCooldown() async throws {
        let clock = RecoveryClock()
        var config = configuration()
        config.refreshFailureCooldown = 30
        let transport = RecordingTransport(send: [token("old"), .response(jsonResponse(status: 503)), token("fresh")])
        let provider = try OAuthTokenProvider(configuration: config, transport: transport, now: clock.now)
        _ = try await provider.accessToken()
        clock.advance(950)
        let fallback = try await provider.accessToken()
        XCTAssertEqual(fallback, "old")
        clock.advance(20)
        let stillFallback = try await provider.accessToken()
        XCTAssertEqual(stillFallback, "old")
        let duringCooldown = await transport.requests
        XCTAssertEqual(duringCooldown.count, 2)
        clock.advance(11)
        let renewed = try await provider.accessToken()
        XCTAssertEqual(renewed, "fresh")
    }

    func testExpiredOrRejectedTokenCannotServeAsRefreshFallback() async throws {
        for reject in [false, true] {
            let clock = RecoveryClock()
            var config = configuration()
            config.refreshFailureCooldown = 30
            let transport = RecordingTransport(send: [token("old"), .response(jsonResponse(status: 503))])
            let provider = try OAuthTokenProvider(configuration: config, transport: transport, now: clock.now)
            _ = try await provider.accessToken()
            if reject { _ = await provider.invalidate(ifToken: "old") } else { clock.advance(1_001) }
            do {
                _ = try await provider.accessToken()
                XCTFail("Invalid cached token used as fallback")
            } catch {}
        }
    }

    func testExplicitAuthorizationIsPreservedOnRetry() async throws {
        var config = testConfiguration(maxRetries: 1)
        config.accessTokenProvider = {
            XCTFail("Explicit auth must bypass the provider")
            return "wrong"
        }
        let transport = RecordingTransport(send: [.response(jsonResponse(status: 503)), .response(jsonResponse())])
        let _: TestDocument = try await OpenAIClient(configuration: config, transport: transport).send(
            .get, path: "models",
            options: RequestOptions(headers: ["Authorization": "Custom explicit"]))
        let requests = await transport.requests
        XCTAssertEqual(
            requests.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Custom explicit", "Custom explicit"])
    }

    func testSignerSeesMiddlewareTransformedBytes() async throws {
        var config = testConfiguration()
        config.middleware = [BodyRewrite()]
        config.prepareAttempt = { request, _ in
            var request = request
            request.setValue(
                String(decoding: request.httpBody ?? Data(), as: UTF8.self), forHTTPHeaderField: "Signed-Body")
            return request
        }
        let transport = RecordingTransport(send: [.response(jsonResponse())])
        let _: TestDocument = try await OpenAIClient(configuration: config, transport: transport).send(
            .post, path: "responses", body: ["original": true])
        let requests = await transport.requests
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Signed-Body"), "transformed")
    }

    private func configuration() -> OAuthConfiguration {
        OAuthConfiguration(
            tokenURL: URL(string: "https://issuer.test/token")!,
            grant: .clientCredentials(clientID: "id", clientSecret: "secret"), refreshLeeway: 100)
    }
    private func token(_ value: String) -> RecordingTransport.SendOutcome {
        .response(jsonResponse("{\"access_token\":\"\(value)\",\"token_type\":\"Bearer\",\"expires_in\":1000}"))
    }
}
private final class RecoveryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_700_000_000)
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: Double) { lock.withLock { value.addTimeInterval(seconds) } }
}
private struct BodyRewrite: ClientMiddleware {
    func send(_ request: URLRequest, next: any OpenAITransport) async throws -> HTTPResponse {
        var request = request
        request.httpBody = Data("transformed".utf8)
        return try await next.send(request)
    }
}
