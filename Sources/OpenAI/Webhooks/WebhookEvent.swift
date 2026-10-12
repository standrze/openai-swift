import Foundation

/// A verified webhook's JSON envelope. Event names and data remain open for future API families.
/// Decoding this type directly does not verify authenticity; use `WebhookVerifier.unwrap` at HTTP boundaries.
public struct WebhookEvent: Codable, Sendable, Equatable {
    public let id: String
    public let type: String
    public let data: JSONValue
    public let createdAt: Int64?
    public let object: String?
    public let rawValue: JSONValue

    public init(from decoder: any Decoder) throws {
        rawValue = try JSONValue(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        data = try container.decode(JSONValue.self, forKey: .data)
        createdAt = try container.decodeIfPresent(Int64.self, forKey: .createdAt)
        object = try container.decodeIfPresent(String.self, forKey: .object)
    }

    public func encode(to encoder: any Encoder) throws {
        try rawValue.encode(to: encoder)
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, data, object
        case createdAt = "created_at"
    }
}
