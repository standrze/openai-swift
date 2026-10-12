import Foundation

/// A model response. `rawValue` preserves provider extensions and future response fields.
public struct Response: Codable, Sendable {
    public let id: String
    public let object: String?
    public let createdAt: Double?
    public let model: String?
    public let status: String?
    public let output: [ResponseOutputItem]
    public let usage: ResponseUsage?
    public let error: JSONValue?
    public let incompleteDetails: JSONValue?
    public let rawValue: JSONValue

    /// All output text parts, concatenated in their original order.
    public var outputText: String {
        output.flatMap(\.content).compactMap { $0.type == "output_text" ? $0.text : nil }.joined()
    }

    /// Function calls that can be answered with `ResponseInput.functionResult`.
    public var functionCalls: [ResponseFunctionCall] {
        output.compactMap(\.functionCall)
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try JSONValue(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        object = try container.decodeIfPresent(String.self, forKey: .object)
        createdAt = try container.decodeIfPresent(Double.self, forKey: .createdAt)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        output = try container.decodeIfPresent([ResponseOutputItem].self, forKey: .output) ?? []
        usage = try container.decodeIfPresent(ResponseUsage.self, forKey: .usage)
        error = try container.decodeIfPresent(JSONValue.self, forKey: .error)
        incompleteDetails = try container.decodeIfPresent(JSONValue.self, forKey: .incompleteDetails)
    }

    public func encode(to encoder: any Encoder) throws {
        try rawValue.encode(to: encoder)
    }

    enum CodingKeys: String, CodingKey {
        case id, object, model, status, output, usage, error
        case createdAt = "created_at"
        case incompleteDetails = "incomplete_details"
    }
}

/// Token accounting for a response. Detail objects retain provider-specific counters.
public struct ResponseUsage: Codable, Sendable, Equatable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let totalTokens: Int?
    public let inputTokensDetails: JSONValue?
    public let outputTokensDetails: JSONValue?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case totalTokens = "total_tokens"
        case inputTokensDetails = "input_tokens_details"
        case outputTokensDetails = "output_tokens_details"
    }
}

/// A response output item, including messages, function calls, and future tool variants.
/// Use `type` to distinguish variants and `rawValue` to inspect unsupported ones.
public struct ResponseOutputItem: Codable, Sendable {
    public let type: String
    public let id: String?
    public let role: String?
    public let status: String?
    public let content: [ResponseContentPart]
    public let callID: String?
    public let name: String?
    public let arguments: String?
    public let rawValue: JSONValue

    /// A typed view when this item is a complete function call.
    public var functionCall: ResponseFunctionCall? {
        guard type == "function_call", let callID, let name, let arguments else { return nil }
        return ResponseFunctionCall(id: id, callID: callID, name: name, arguments: arguments)
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try JSONValue(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        role = try? container.decodeIfPresent(String.self, forKey: .role)
        status = try? container.decodeIfPresent(String.self, forKey: .status)
        content = (try? container.decodeIfPresent([ResponseContentPart].self, forKey: .content)) ?? []
        callID = try? container.decodeIfPresent(String.self, forKey: .callID)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        arguments = try? container.decodeIfPresent(String.self, forKey: .arguments)
    }

    public func encode(to encoder: any Encoder) throws {
        try rawValue.encode(to: encoder)
    }

    enum CodingKeys: String, CodingKey {
        case type, id, role, status, content, name, arguments
        case callID = "call_id"
    }
}

/// A text, refusal, or provider-defined response content part.
public struct ResponseContentPart: Codable, Sendable {
    public let type: String
    public let text: String?
    public let refusal: String?
    public let annotations: [JSONValue]?
    public let rawValue: JSONValue

    public init(from decoder: any Decoder) throws {
        rawValue = try JSONValue(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        text = try? container.decodeIfPresent(String.self, forKey: .text)
        refusal = try? container.decodeIfPresent(String.self, forKey: .refusal)
        annotations = try? container.decodeIfPresent([JSONValue].self, forKey: .annotations)
    }

    public func encode(to encoder: any Encoder) throws {
        try rawValue.encode(to: encoder)
    }

    enum CodingKeys: String, CodingKey { case type, text, refusal, annotations }
}

/// A function requested by the model. `arguments` contains the original JSON string.
public struct ResponseFunctionCall: Codable, Sendable, Equatable {
    public let id: String?
    public let callID: String
    public let name: String
    public let arguments: String

    public init(id: String? = nil, callID: String, name: String, arguments: String) {
        self.id = id
        self.callID = callID
        self.name = name
        self.arguments = arguments
    }

    enum CodingKeys: String, CodingKey {
        case id, name, arguments
        case callID = "call_id"
    }
}
