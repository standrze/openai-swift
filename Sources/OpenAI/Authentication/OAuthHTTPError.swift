import Foundation

/// A token issuer failure. Arbitrary issuer descriptions, response bytes, and headers are discarded.
public struct OAuthHTTPError: Error, Sendable, LocalizedError {
    public let statusCode: Int
    public let code: String?
    let retryableOAuthError: Bool

    init(response: HTTPResponse, redactCode: Bool = false) {
        statusCode = response.statusCode
        let value = try? JSONDecoder().decode(JSONValue.self, from: Data(response.data.prefix(4096)))
        let candidate = value?["error"]?.stringValue
        retryableOAuthError = candidate == "temporarily_unavailable" || candidate == "server_error"
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        code =
            redactCode
            ? nil
            : candidate.flatMap { value in
                value.count <= 128 && value.unicodeScalars.allSatisfy(safe.contains) ? value : nil
            }
    }

    public var errorDescription: String? {
        "OAuth token exchange failed with HTTP status \(statusCode)" + (code.map { " (\($0))" } ?? "")
    }
}
