import Crypto
import Foundation

/// Verifies OpenAI Standard Webhooks using the original HTTP body bytes.
/// Timestamp validation limits replay age; applications should also deduplicate webhook IDs.
public struct WebhookVerifier: Sendable {
    public let tolerance: TimeInterval
    private let key: Data

    /// Creates a verifier with a webhook secret and a symmetric clock tolerance in seconds.
    /// `whsec_` secrets contain base64 key bytes; other nonempty secrets are interpreted as raw UTF-8.
    /// Throws `OpenAIClientError.invalidConfiguration` for invalid secrets or nonfinite/negative tolerance.
    public init(secret: String, tolerance: TimeInterval = 300) throws {
        guard tolerance.isFinite, tolerance >= 0 else {
            throw OpenAIClientError.invalidConfiguration("Webhook tolerance must be finite and nonnegative")
        }
        guard !secret.isEmpty else {
            throw OpenAIClientError.invalidConfiguration("Webhook secret must not be empty")
        }
        if secret.hasPrefix("whsec_") {
            guard let decoded = Data(base64Encoded: String(secret.dropFirst(6))), !decoded.isEmpty else {
                throw OpenAIClientError.invalidConfiguration("Webhook secret contains invalid base64 key data")
            }
            key = decoded
        } else {
            key = Data(secret.utf8)
        }
        self.tolerance = tolerance
    }

    /// Verifies signature and timestamp without parsing or reserializing the body.
    /// Header lookup is case insensitive. Multiple signatures permit secret rotation.
    public func verify(payload: Data, headers: [String: String], now: Date = Date()) throws {
        let signatureHeader = try header("webhook-signature", in: headers)
        let timestampHeader = try header("webhook-timestamp", in: headers)
        let id = try header("webhook-id", in: headers)
        guard !timestampHeader.isEmpty,
            timestampHeader.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
            let timestamp = Int64(timestampHeader)
        else {
            throw WebhookVerificationError.invalidTimestamp
        }
        let currentTime = now.timeIntervalSince1970
        guard currentTime.isFinite else {
            throw OpenAIClientError.invalidConfiguration("Webhook verification time must be finite")
        }
        let age = currentTime - TimeInterval(timestamp)
        if age > tolerance { throw WebhookVerificationError.timestampTooOld }
        if age < -tolerance { throw WebhookVerificationError.timestampTooNew }

        var signed = Data((id + "." + timestampHeader + ".").utf8)
        signed.append(payload)
        for part in signatureHeader.split(whereSeparator: { $0.isWhitespace }) {
            // The Go SDK also accepts bare base64 signatures for compatibility.
            let encoded = part.hasPrefix("v1,") ? part.dropFirst(3) : part[...]
            guard let signature = Data(base64Encoded: String(encoded)), signature.count == 32 else { continue }
            if isValid(signature: signature, message: signed) { return }
        }
        throw WebhookVerificationError.invalidSignature
    }

    /// Verifies the original body before decoding its event, preserving unknown fields and event types.
    public func unwrap(payload: Data, headers: [String: String], now: Date = Date()) throws -> WebhookEvent {
        try verify(payload: payload, headers: headers, now: now)
        return try JSONDecoder().decode(WebhookEvent.self, from: payload)
    }

    private func header(_ name: String, in headers: [String: String]) throws -> String {
        let values = headers.filter { $0.key.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
        guard let value = values.first, !value.isEmpty else {
            throw WebhookVerificationError.missingHeader(name)
        }
        guard values.count == 1 else { throw WebhookVerificationError.ambiguousHeader(name) }
        return value
    }

    private func isValid(signature: Data, message: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(
            signature, authenticating: message, using: SymmetricKey(data: key))
    }
}

/// Signature or replay-window failures. Error messages never contain secret material or payload bytes.
public enum WebhookVerificationError: Error, Sendable, Equatable, LocalizedError {
    case missingHeader(String)
    case ambiguousHeader(String)
    case invalidTimestamp
    case timestampTooOld
    case timestampTooNew
    case invalidSignature

    public var errorDescription: String? {
        switch self {
        case .missingHeader(let name): return "Missing required \(name) header"
        case .ambiguousHeader(let name): return "Multiple differently cased \(name) headers are ambiguous"
        case .invalidTimestamp: return "Invalid webhook timestamp"
        case .timestampTooOld: return "Webhook timestamp is too old"
        case .timestampTooNew: return "Webhook timestamp is too new"
        case .invalidSignature: return "Webhook signature verification failed"
        }
    }
}
