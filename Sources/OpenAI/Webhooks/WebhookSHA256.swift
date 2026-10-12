import Crypto
import Foundation

// Compatibility shim for existing standard-vector tests. Cryptography is owned by Swift Crypto.
enum WebhookSHA256 {
    static func hash(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    static func hmac(key: Data, message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }
    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        // Authenticate the comparison through the maintained constant-time HMAC verification primitive.
        let key = SymmetricKey(data: Data("OpenAI constant time comparison".utf8))
        let code = HMAC<SHA256>.authenticationCode(for: lhs, using: key)
        return HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: rhs, using: key)
    }
}
