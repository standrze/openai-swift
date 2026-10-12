import Foundation

/// A Responses API input: plain text or structured message, image, and tool items.
public enum ResponseInput: Codable, Sendable, Equatable, ExpressibleByStringLiteral {
    case text(String)
    case items([JSONValue])

    public init(stringLiteral value: String) {
        self = .text(value)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else {
            self = .items(try container.decode([JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text): try container.encode(text)
        case .items(let items): try container.encode(items)
        }
    }

    /// Creates a text message for a role such as `user`, `system`, or `developer`.
    public static func message(_ text: String, role: String = "user") -> JSONValue {
        .object(["role": .string(role), "content": .string(text)])
    }

    /// Returns a function result associated with the model's `call_id`.
    public static func functionResult(callID: String, output: String) -> JSONValue {
        .object([
            "type": .string("function_call_output"),
            "call_id": .string(callID),
            "output": .string(output),
        ])
    }

    /// Creates an input image part for a structured message's content array.
    public static func image(url: String, detail: String = "auto") -> JSONValue {
        .object(["type": .string("input_image"), "image_url": .string(url), "detail": .string(detail)])
    }

    /// Creates a function tool definition. The schema is passed through unchanged.
    public static func functionTool(
        name: String,
        description: String? = nil,
        parameters: JSONValue,
        strict: Bool? = nil
    ) -> JSONValue {
        var tool: [String: JSONValue] = [
            "type": .string("function"), "name": .string(name), "parameters": parameters,
        ]
        if let description { tool["description"] = .string(description) }
        if let strict { tool["strict"] = .bool(strict) }
        return .object(tool)
    }
}

/// Common Responses parameters. Use request options' `extraBody` for provider extensions.
public struct ResponseRequest: Codable, Sendable {
    public var model: String
    public var input: ResponseInput
    public var instructions: String?
    public var maxOutputTokens: Int?
    public var previousResponseID: String?
    public var temperature: Double?
    public var topP: Double?
    public var parallelToolCalls: Bool?
    public var tools: [JSONValue]?
    public var toolChoice: JSONValue?
    public var text: JSONValue?
    public var reasoning: JSONValue?
    public var metadata: [String: String]?
    public var store: Bool?
    public var background: Bool?
    public var truncation: String?
    public var include: [String]?
    public var user: String?
    public var serviceTier: String?

    public init(model: String, input: ResponseInput, instructions: String? = nil) {
        self.model = model
        self.input = input
        self.instructions = instructions
    }

    enum CodingKeys: String, CodingKey {
        case model, input, instructions, temperature, tools, text, reasoning, metadata, store
        case background, truncation, include, user
        case maxOutputTokens = "max_output_tokens"
        case previousResponseID = "previous_response_id"
        case topP = "top_p"
        case parallelToolCalls = "parallel_tool_calls"
        case toolChoice = "tool_choice"
        case serviceTier = "service_tier"
    }
}
