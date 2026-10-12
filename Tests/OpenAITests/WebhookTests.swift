import Foundation
import XCTest

@testable import OpenAI

#if canImport(CryptoKit)
    import CryptoKit
#endif

final class WebhookTests: XCTestCase {
    // Official upstream fixture: https://github.com/openai/openai-go/blob/main/webhooks/webhook_test.go
    private let secret = "whsec_RdvaYFYUXuIFuEbvZHwMfYFhUf7aMYjYcmM24+Aj40c="
    private let payload = Data(
        #"{"id": "evt_685c059ae3a481909bdc86819b066fb6", "object": "event", "created_at": 1750861210, "type": "response.completed", "data": {"id": "resp_123"}}"#
            .utf8)
    private let timestamp: TimeInterval = 1_750_861_210
    private let signature = "v1,gUAg4R2hWouRZqRQG4uJypNS8YK885G838+EHb4nKBY="

    private var headers: [String: String] {
        [
            "webhook-signature": signature,
            "webhook-timestamp": "1750861210",
            "webhook-id": "wh_685c059ae39c8190af8c71ed1022a24d",
        ]
    }

    func testOfficialOpenAIGoFixtureVerifiesAndUnwraps() throws {
        let verifier = try WebhookVerifier(secret: secret)
        let now = Date(timeIntervalSince1970: timestamp)
        XCTAssertNoThrow(try verifier.verify(payload: payload, headers: headers, now: now))
        let event = try verifier.unwrap(payload: payload, headers: headers, now: now)
        XCTAssertEqual(event.id, "evt_685c059ae3a481909bdc86819b066fb6")
        XCTAssertEqual(event.type, "response.completed")
        XCTAssertEqual(event.createdAt, 1_750_861_210)
        XCTAssertEqual(event.object, "event")
        XCTAssertEqual(event.data["id"], "resp_123")
        XCTAssertEqual(try JSONValue.encode(event), event.rawValue)
    }

    func testClientWebhookSecretAndExplicitOverride() throws {
        var configuration = ClientConfiguration.ollama()
        configuration.webhookSecret = secret
        let service = OpenAIClient(configuration: configuration).webhooks
        let now = Date(timeIntervalSince1970: timestamp)
        XCTAssertEqual(try service.unwrap(payload: payload, headers: headers, now: now).type, "response.completed")
        XCTAssertThrowsError(try service.verifySignature(payload: payload, headers: headers, secret: "wrong", now: now))
    }

    func testPayloadIDTimestampAndSecretTamperingFail() throws {
        let verifier = try WebhookVerifier(secret: secret)
        let now = Date(timeIntervalSince1970: timestamp)
        XCTAssertThrowsError(try verifier.verify(payload: payload + Data(" ".utf8), headers: headers, now: now)) {
            XCTAssertEqual($0 as? WebhookVerificationError, .invalidSignature)
        }
        var changed = headers
        changed["webhook-id"] = "another_id"
        XCTAssertThrowsError(try verifier.verify(payload: payload, headers: changed, now: now))
        changed = headers
        changed["webhook-timestamp"] = "1750861211"
        XCTAssertThrowsError(try verifier.verify(payload: payload, headers: changed, now: now)) {
            XCTAssertEqual($0 as? WebhookVerificationError, .invalidSignature)
        }
        let wrong = try WebhookVerifier(secret: "wrong_secret")
        XCTAssertThrowsError(try wrong.verify(payload: payload, headers: headers, now: now))
    }

    func testHeadersAreCaseInsensitiveAndAmbiguousDuplicatesAreRejected() throws {
        let verifier = try WebhookVerifier(secret: secret)
        let now = Date(timeIntervalSince1970: timestamp)
        let mixed = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.uppercased(), $0.value) })
        XCTAssertNoThrow(try verifier.verify(payload: payload, headers: mixed, now: now))
        var duplicated = headers
        duplicated["Webhook-Id"] = headers["webhook-id"]
        XCTAssertThrowsError(try verifier.verify(payload: payload, headers: duplicated, now: now)) {
            XCTAssertEqual($0 as? WebhookVerificationError, .ambiguousHeader("webhook-id"))
        }
        for name in ["webhook-signature", "webhook-timestamp", "webhook-id"] {
            var incomplete = headers
            incomplete.removeValue(forKey: name)
            XCTAssertThrowsError(try verifier.verify(payload: payload, headers: incomplete, now: now)) {
                XCTAssertEqual($0 as? WebhookVerificationError, .missingHeader(name))
            }
        }
    }

    func testMultipleSignaturesAndUpstreamBareSignatureCompatibility() throws {
        let verifier = try WebhookVerifier(secret: secret)
        let now = Date(timeIntervalSince1970: timestamp)
        var multiple = headers
        multiple["webhook-signature"] = "v1,invalid\t v2,unknown  " + signature + " v1,other_invalid"
        XCTAssertNoThrow(try verifier.verify(payload: payload, headers: multiple, now: now))
        multiple["webhook-signature"] = String(signature.dropFirst(3))
        XCTAssertNoThrow(try verifier.verify(payload: payload, headers: multiple, now: now))
        for invalid in ["v2," + signature.dropFirst(3), "v1,AAAA", "v1,%%%", "v1,invalid v1,other"] {
            multiple["webhook-signature"] = invalid
            XCTAssertThrowsError(try verifier.verify(payload: payload, headers: multiple, now: now)) {
                XCTAssertEqual($0 as? WebhookVerificationError, .invalidSignature)
            }
        }
    }

    func testReplayWindowChecksBothDirectionsAndInclusiveBoundary() throws {
        let verifier = try WebhookVerifier(secret: secret)
        for offset in [-300.0, 0, 300] {
            XCTAssertNoThrow(
                try verifier.verify(
                    payload: payload, headers: headers, now: Date(timeIntervalSince1970: timestamp + offset)
                ))
        }
        XCTAssertThrowsError(
            try verifier.verify(
                payload: payload, headers: headers, now: Date(timeIntervalSince1970: timestamp + 301)
            )
        ) { XCTAssertEqual($0 as? WebhookVerificationError, .timestampTooOld) }
        XCTAssertThrowsError(
            try verifier.verify(
                payload: payload, headers: headers, now: Date(timeIntervalSince1970: timestamp - 301)
            )
        ) { XCTAssertEqual($0 as? WebhookVerificationError, .timestampTooNew) }
        let extended = try WebhookVerifier(secret: secret, tolerance: 600)
        XCTAssertNoThrow(
            try extended.verify(
                payload: payload, headers: headers, now: Date(timeIntervalSince1970: timestamp + 500)
            ))
        let exact = try WebhookVerifier(secret: secret, tolerance: 0)
        XCTAssertNoThrow(
            try exact.verify(payload: payload, headers: headers, now: Date(timeIntervalSince1970: timestamp)))
        XCTAssertThrowsError(
            try exact.verify(
                payload: payload, headers: headers, now: Date(timeIntervalSince1970: timestamp + 0.5)
            ))
    }

    func testInvalidTimestampFormatsAndExtremeIntegersFail() throws {
        let verifier = try WebhookVerifier(secret: secret)
        for value in ["NaN", "1.5", "-1", "+1750861210", "9223372036854775808", " 1750861210", "1750861210 "] {
            var invalid = headers
            invalid["webhook-timestamp"] = value
            XCTAssertThrowsError(
                try verifier.verify(
                    payload: payload, headers: invalid, now: Date(timeIntervalSince1970: timestamp)
                )
            ) { XCTAssertEqual($0 as? WebhookVerificationError, .invalidTimestamp) }
        }
    }

    func testInvalidSecretAndToleranceConfigurationFailsWithoutLeakingSecret() {
        for value in ["", "whsec_", "whsec_%%%", "whsec_Zg"] {
            XCTAssertThrowsError(try WebhookVerifier(secret: value)) {
                guard let error = $0 as? OpenAIClientError, case .invalidConfiguration = error else {
                    return XCTFail("Expected invalid configuration")
                }
            }
        }
        for value in [-1.0, Double.nan, .infinity] {
            XCTAssertThrowsError(try WebhookVerifier(secret: "valid", tolerance: value))
        }
    }

    func testRawAndBase64SecretsVerifyUnicodeAndUnknownEvents() throws {
        let rawSecret = "fixture-secret-π"
        let unicode = Data(
            #"{"id":"evt_future","type":"future.event","created_at":1750861210,"data":{"text":"café 🥐 東京"},"future_field":[1,true,null]}"#
                .utf8)
        let key = Data(rawSecret.utf8)
        let signedHeaders = fixtureHeaders(payload: unicode, key: key)
        for secret in [rawSecret, "whsec_" + key.base64EncodedString()] {
            let verifier = try WebhookVerifier(secret: secret)
            let event = try verifier.unwrap(
                payload: unicode, headers: signedHeaders, now: Date(timeIntervalSince1970: timestamp)
            )
            XCTAssertEqual(event.type, "future.event")
            XCTAssertEqual(event.data["text"], "café 🥐 東京")
            XCTAssertEqual(event.rawValue["future_field"], [1, true, .null])
        }
    }

    func testUnwrapVerifiesBeforeJSONParsingAndVerifyAcceptsBinaryPayloads() throws {
        let verifier = try WebhookVerifier(secret: "fixture")
        let binary = Data([0, 255, 128, 1])
        let signedHeaders = fixtureHeaders(payload: binary, key: Data("fixture".utf8))
        let now = Date(timeIntervalSince1970: timestamp)
        XCTAssertNoThrow(try verifier.verify(payload: binary, headers: signedHeaders, now: now))
        XCTAssertThrowsError(try verifier.unwrap(payload: binary, headers: signedHeaders, now: now)) {
            XCTAssertTrue($0 is DecodingError)
        }
        XCTAssertThrowsError(try verifier.unwrap(payload: binary, headers: headers, now: now)) {
            XCTAssertEqual($0 as? WebhookVerificationError, .invalidSignature)
        }
    }

    func testPortableSHA256AgainstNISTExamples() {
        // https://csrc.nist.gov/CSRC/media/Projects/Cryptographic-Standards-and-Guidelines/documents/examples/SHA256.pdf
        let vectors = [
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            (
                "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
                "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
            ),
        ]
        for (message, expected) in vectors {
            XCTAssertEqual(hex(WebhookSHA256.hash(Data(message.utf8))), expected)
        }
    }

    func testPortableHMACAgainstAllRFC4231SHA256Cases() {
        // https://www.rfc-editor.org/rfc/rfc4231.txt sections 4.2-4.8.
        let vectors: [(Data, Data, String)] = [
            (
                Data(repeating: 0x0b, count: 20), Data("Hi There".utf8),
                "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
            ),
            (
                Data("Jefe".utf8), Data("what do ya want for nothing?".utf8),
                "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
            ),
            (
                Data(repeating: 0xaa, count: 20), Data(repeating: 0xdd, count: 50),
                "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe"
            ),
            (
                Data((1...25).map(UInt8.init)), Data(repeating: 0xcd, count: 50),
                "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b"
            ),
            (
                Data(repeating: 0x0c, count: 20), Data("Test With Truncation".utf8),
                "a3b6167473100ee06e0c796c2955552b"
            ),
            (
                Data(repeating: 0xaa, count: 131), Data("Test Using Larger Than Block-Size Key - Hash Key First".utf8),
                "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"
            ),
            (
                Data(repeating: 0xaa, count: 131),
                Data(
                    ("This is a test using a larger than block-size key and a larger than block-size data. "
                        + "The key needs to be hashed before being used by the HMAC algorithm.").utf8),
                "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2"
            ),
        ]
        for (key, message, expected) in vectors {
            let result = hex(WebhookSHA256.hmac(key: key, message: message))
            XCTAssertEqual(String(result.prefix(expected.count)), expected)
        }
    }

    func testPortableComparisonChecksEveryByteAndLengths() {
        let expected = Data(repeating: 0x42, count: 32)
        XCTAssertTrue(WebhookSHA256.constantTimeEqual(expected, expected))
        for index in 0..<32 {
            var changed = expected
            changed[index] ^= 1
            XCTAssertFalse(WebhookSHA256.constantTimeEqual(expected, changed))
        }
        XCTAssertFalse(WebhookSHA256.constantTimeEqual(expected, expected.dropLast()))
    }

    #if canImport(CryptoKit)
        func testPortablePrimitivesMatchCryptoKitAcrossPaddingAndKeyBoundaries() {
            for count in [0, 1, 55, 56, 63, 64, 65, 127, 128, 129, 1024] {
                let message = Data((0..<count).map { UInt8(truncatingIfNeeded: $0) })
                XCTAssertEqual(WebhookSHA256.hash(message), Data(SHA256.hash(data: message)))
                for keyCount in [0, 1, 32, 63, 64, 65, 131] {
                    let key = Data(repeating: 0xa5, count: keyCount)
                    let native = Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
                    XCTAssertEqual(WebhookSHA256.hmac(key: key, message: message), native)
                }
            }
        }
    #endif

    private func fixtureHeaders(payload: Data, key: Data) -> [String: String] {
        let id = "fixture_webhook"
        var signed = Data((id + ".1750861210.").utf8)
        signed.append(payload)
        return [
            "webhook-id": id,
            "webhook-timestamp": "1750861210",
            "webhook-signature": "v1," + WebhookSHA256.hmac(key: key, message: signed).base64EncodedString(),
        ]
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
