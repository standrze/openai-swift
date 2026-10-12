import Foundation
import XCTest

@testable import OpenAI

final class X509TokenParsingTests: XCTestCase, @unchecked Sendable {
    func testStrictLifetimeDuplicateAndBearerValidation() async throws {
        let original =
            #"{"access_token":"valid.token+/==","token_type":"Bearer","issued_token_type":"urn:ietf:params:oauth:token-type:access_token","expires_in":60}"#
        let malformed = [
            original.replacingOccurrences(of: "60", with: "1.5"),
            original.replacingOccurrences(of: "60", with: "1e2"),
            original.replacingOccurrences(of: "60", with: "3601"),
            original.replacingOccurrences(of: "60", with: "0"),
            original.replacingOccurrences(of: "60", with: #""60""#),
            original.replacingOccurrences(of: "valid.token+/==", with: "token=middle"),
            original.replacingOccurrences(of: "valid.token+/==", with: "unicode-é"),
            original.replacingOccurrences(of: #""expires_in":60"#, with: #""expires_in":60,"expires_in":120"#),
            original + " true",
        ]
        for body in malformed {
            let provider = try makeProvider(body)
            do {
                _ = try await provider.accessToken()
                XCTFail("Invalid X.509 response accepted")
            } catch is OAuthTokenError {}
        }
        let valid = try makeProvider(original)
        let token = try await valid.accessToken()
        XCTAssertEqual(token, "valid.token+/==")
    }

    func testX509IssuerErrorDiscardsAllResponseContent() async throws {
        let provider = try makeProvider(
            #"{"error":"secret_token_123","error_description":"private issuer details"}"#, status: 401)
        do {
            _ = try await provider.accessToken()
            XCTFail("Expected issuer failure")
        } catch let error as OAuthHTTPError {
            XCTAssertEqual(error.statusCode, 401)
            XCTAssertNil(error.code)
            XCTAssertFalse(error.localizedDescription.contains("secret"))
            XCTAssertFalse(error.localizedDescription.contains("private"))
        }
    }

    private func makeProvider(_ body: String, status: Int = 200) throws -> OAuthTokenProvider {
        try OAuthTokenProvider(
            configuration: OAuthConfiguration(
                tokenURL: URL(string: "https://mtls.auth.openai.com/oauth/token")!,
                grant: .x509(identityProviderID: "idp-fixture", serviceAccountID: "service-fixture")),
            transport: RecordingTransport(stream: [.response(streamResponse(text: body, status: status))]))
    }
}
