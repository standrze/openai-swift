import Foundation

/// An unknown union variant, retaining its complete original JSON for inspection or raw requests.
/// Foundation's encoder supports finite machine numbers; use `data` for lossless forwarding of larger numbers.
public struct RawJSONValue: Codable, Sendable, Hashable, JSONDefaultValue {
    public let data: Data
    public static let null = try! Self(data: Data("null".utf8))
    public static var jsonDefaultValue: Self { .null }
    public var rawJSON: String { String(decoding: data, as: UTF8.self) }
    public var document: JSONDocument { get throws { try JSONDocument(data: data) } }

    public init(data: Data) throws {
        _ = try JSONDocument(data: data)
        self.data = data
    }

    public init(from decoder: any Decoder) throws {
        if let document = OpenAIJSON.source,
            let raw = document.field(
                at: decoder.codingPath.map { key in
                    key.intValue.map(JSONPathComponent.index) ?? .key(key.stringValue)
                }
            ).rawData
        {
            data = raw
        } else {
            data = try JSONEncoder().encode(JSONValue(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        try JSONDecoder().decode(JSONValue.self, from: data).encode(to: encoder)
    }
}
