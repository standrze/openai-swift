import Foundation
import OpenAI
import Smithy
import SmithyHTTPAPI
import SmithyIdentity
import XCTest

@testable import OpenAIBedrock

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

final class BedrockTests: XCTestCase, @unchecked Sendable {
    func testNamedProfileRegionUsesOfficialSharedConfigurationParser() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config")
        let credentials = directory.appendingPathComponent("credentials")
        try Data("[default]\nregion = us-east-1\n[profile fixture]\nregion = us-west-2\n".utf8).write(to: config)
        try Data().write(to: credentials)
        let region = try await BedrockClient.profileRegion(
            "fixture", configFilePath: config.path, credentialsFilePath: credentials.path)
        XCTAssertEqual(region, "us-west-2")
    }

    func testOfficialSignerIncludesBodyAndSessionToken() async throws {
        let signer = BedrockSigner(region: "us-west-2", resolver: StaticCredentials())
        var request = URLRequest(
            url: URL(string: "https://bedrock-mantle.us-west-2.api.aws/openai/v1/responses?tag=two%20words")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"model":"gpt-oss-20b","input":"Hello"}"#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try await signer.sign(request, now: date)
        XCTAssertTrue(
            first.value(forHTTPHeaderField: "Authorization")?.contains("/us-west-2/bedrock-mantle/aws4_request") == true
        )
        XCTAssertEqual(first.value(forHTTPHeaderField: "X-Amz-Security-Token"), "session")
        request.httpBody = Data(#"{"model":"gpt-oss-20b","input":"Changed"}"#.utf8)
        let second = try await signer.sign(request, now: date)
        XCTAssertNotEqual(
            first.value(forHTTPHeaderField: "Authorization"), second.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(first.url, request.url)
    }

    func testBedrockBearerClientDoesNotInheritOpenAISettings() async throws {
        let client = try await BedrockClient.make(region: "us-west-2", bearerToken: "bedrock")
        XCTAssertEqual(client.configuration.apiKey, "bedrock")
        XCTAssertEqual(
            client.configuration.baseURL.absoluteString, "https://bedrock-mantle.us-west-2.api.aws/openai/v1")
        XCTAssertNil(client.configuration.organization)
        XCTAssertNil(client.configuration.project)
        XCTAssertNil(client.configuration.prepareAttempt)
    }

    func testSigningPreservesEscapedPathAndQueryBytes() throws {
        let url = URL(
            string: "https://example.test/openai/v1/files/a%252Fb%2Fc%20d?literal=%252B&plus=%2B&space=two%20words")!
        let endpoint = try BedrockSigner.signingEndpoint(url, headers: Headers())
        XCTAssertEqual(endpoint.path, "/openai/v1/files/a%252Fb%2Fc%20d")
        XCTAssertEqual(endpoint.url?.absoluteString, url.absoluteString)
    }

    func testConflictingCredentialModesAndInvalidEndpointFail() async throws {
        do {
            _ = try await BedrockClient.make(
                region: "us-west-2", credentials: StaticCredentials(), bearerToken: "token")
            XCTFail("Mixed auth accepted")
        } catch {}
        do {
            _ = try await BedrockClient.make(
                region: "us-west-2", baseURL: URL(string: "http://example.test")!, bearerToken: "token")
            XCTFail("HTTP accepted")
        } catch {}
    }
}

private struct StaticCredentials: AWSCredentialIdentityResolver {
    func getIdentity(identityProperties: Attributes?) async throws -> AWSCredentialIdentity {
        AWSCredentialIdentity(accessKey: "AKIDEXAMPLE", secret: "fixture-secret", sessionToken: "session")
    }
}
