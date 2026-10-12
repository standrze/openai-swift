import Foundation

/// A Responses stream event. Unknown event kinds and fields remain available in `rawValue`.
public struct ResponseEvent: Codable, Sendable {
    public let type: String
    public let sequenceNumber: Int?
    public let outputIndex: Int?
    public let contentIndex: Int?
    public let itemID: String?
    public let delta: JSONValue?
    public let response: Response?
    public let item: ResponseOutputItem?
    public let part: ResponseContentPart?
    public let error: JSONValue?
    public let text: String?
    public let arguments: String?
    public let code: String?
    public let message: String?
    public let param: String?
    public let rawValue: JSONValue
    public let rawJSON: RawJSONValue

    /// The text fragment on text delta events; other delta variants return nil.
    public var textDelta: String? {
        type == "response.output_text.delta" ? delta?.stringValue : nil
    }

    public init(from decoder: any Decoder) throws {
        rawJSON = try RawJSONValue(from: decoder)
        rawValue = try JSONValue(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        sequenceNumber = try? container.decodeIfPresent(Int.self, forKey: .sequenceNumber)
        outputIndex = try? container.decodeIfPresent(Int.self, forKey: .outputIndex)
        contentIndex = try? container.decodeIfPresent(Int.self, forKey: .contentIndex)
        itemID = try? container.decodeIfPresent(String.self, forKey: .itemID)
        delta = try container.decodeIfPresent(JSONValue.self, forKey: .delta)
        response = try? container.decodeIfPresent(Response.self, forKey: .response)
        item = try? container.decodeIfPresent(ResponseOutputItem.self, forKey: .item)
        part = try? container.decodeIfPresent(ResponseContentPart.self, forKey: .part)
        error = try container.decodeIfPresent(JSONValue.self, forKey: .error)
        text = try? container.decodeIfPresent(String.self, forKey: .text)
        arguments = try? container.decodeIfPresent(String.self, forKey: .arguments)
        code = try? container.decodeIfPresent(String.self, forKey: .code)
        message = try? container.decodeIfPresent(String.self, forKey: .message)
        param = try? container.decodeIfPresent(String.self, forKey: .param)
    }

    public func encode(to encoder: any Encoder) throws {
        try rawValue.encode(to: encoder)
    }

    enum CodingKeys: String, CodingKey {
        case type, delta, response, item, part, error, text, arguments, code, message, param
        case sequenceNumber = "sequence_number"
        case outputIndex = "output_index"
        case contentIndex = "content_index"
        case itemID = "item_id"
    }
}
