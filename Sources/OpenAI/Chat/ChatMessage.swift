import Foundation

/// A conversation message. Role strings remain open for compatible provider extensions.
public struct ChatMessage: Codable, Sendable, Equatable {
    public var role: String
    public var content: ChatContent?
    public var name: String?
    public var toolCallID: String?
    public var toolCalls: [ChatToolCall]?
    public var functionCall: ChatFunctionCall?
    public var refusal: String?
    public var reasoningContent: String?
    public var audio: JSONValue?
    public var annotations: [JSONValue]?
    /// Ollama's reasoning output, kept separate from providers' reasoning_content extension.
    public var reasoning: String?

    /// Creates a message, including provider-specific roles when needed.
    public init(
        role: String,
        content: ChatContent? = nil,
        name: String? = nil,
        toolCallID: String? = nil,
        toolCalls: [ChatToolCall]? = nil,
        functionCall: ChatFunctionCall? = nil,
        refusal: String? = nil,
        reasoningContent: String? = nil,
        audio: JSONValue? = nil,
        annotations: [JSONValue]? = nil,
        reasoning: String? = nil
    ) {
        self.role = role
        self.content = content
        self.name = name
        self.toolCallID = toolCallID
        self.toolCalls = toolCalls
        self.functionCall = functionCall
        self.refusal = refusal
        self.reasoningContent = reasoningContent
        self.audio = audio
        self.annotations = annotations
        self.reasoning = reasoning
    }

    /// Creates a system instruction.
    public static func system(_ content: ChatContent, name: String? = nil) -> Self {
        Self(role: "system", content: content, name: name)
    }

    /// Creates a system instruction from a string value.
    public static func system(_ text: String, name: String? = nil) -> Self {
        system(.text(text), name: name)
    }

    /// Creates a developer instruction.
    public static func developer(_ content: ChatContent, name: String? = nil) -> Self {
        Self(role: "developer", content: content, name: name)
    }

    /// Creates a developer instruction from a string value.
    public static func developer(_ text: String, name: String? = nil) -> Self {
        developer(.text(text), name: name)
    }

    /// Creates user input, including multimodal content.
    public static func user(_ content: ChatContent, name: String? = nil) -> Self {
        Self(role: "user", content: content, name: name)
    }

    /// Creates user input from a string value.
    public static func user(_ text: String, name: String? = nil) -> Self {
        user(.text(text), name: name)
    }

    /// Creates an assistant message, optionally requesting tool calls.
    public static func assistant(_ content: ChatContent? = nil, toolCalls: [ChatToolCall]? = nil) -> Self {
        Self(role: "assistant", content: content, toolCalls: toolCalls)
    }

    /// Creates assistant output from a string value.
    public static func assistant(_ text: String, toolCalls: [ChatToolCall]? = nil) -> Self {
        assistant(.text(text), toolCalls: toolCalls)
    }

    /// Creates a tool result linked to the corresponding assistant tool-call identifier.
    public static func tool(_ content: ChatContent, toolCallID: String) -> Self {
        Self(role: "tool", content: content, toolCallID: toolCallID)
    }

    /// Creates a tool result from a string value.
    public static func tool(_ text: String, toolCallID: String) -> Self {
        tool(.text(text), toolCallID: toolCallID)
    }

    /// Text content, or the joined text parts of a multimodal message.
    public var text: String? { content?.text }

    private enum CodingKeys: String, CodingKey {
        case role, content, name, refusal, audio, annotations, reasoning
        case toolCallID = "tool_call_id"
        case toolCalls = "tool_calls"
        case functionCall = "function_call"
        case reasoningContent = "reasoning_content"
    }
}

/// Message content encoded either as a string or an array of typed parts.
public enum ChatContent: Codable, Sendable, Equatable, ExpressibleByStringLiteral, ExpressibleByArrayLiteral {
    case text(String)
    case parts([ChatContentPart])

    public init(stringLiteral value: String) { self = .text(value) }
    public init(arrayLiteral elements: ChatContentPart...) { self = .parts(elements) }

    /// Returns textual content without image, audio, file, or refusal parts.
    public var text: String? {
        switch self {
        case .text(let text): return text
        case .parts(let parts):
            let texts = parts.compactMap { part -> String? in
                if case .text(let text) = part { return text }
                return nil
            }
            return texts.isEmpty ? nil : texts.joined()
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else {
            self = .parts(try container.decode([ChatContentPart].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text): try container.encode(text)
        case .parts(let parts): try container.encode(parts)
        }
    }
}

/// A multimodal content part. Unknown part types round-trip as JSON.
public enum ChatContentPart: Codable, Sendable, Equatable {
    case text(String)
    case imageURL(ChatImageURL)
    case inputAudio(ChatInputAudio)
    case file(ChatFile)
    case refusal(String)
    case custom(JSONValue)

    private enum CodingKeys: String, CodingKey {
        case type, text, file, refusal
        case imageURL = "image_url"
        case inputAudio = "input_audio"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "text": self = .text(try container.decode(String.self, forKey: .text))
        case "image_url": self = .imageURL(try container.decode(ChatImageURL.self, forKey: .imageURL))
        case "input_audio": self = .inputAudio(try container.decode(ChatInputAudio.self, forKey: .inputAudio))
        case "file": self = .file(try container.decode(ChatFile.self, forKey: .file))
        case "refusal": self = .refusal(try container.decode(String.self, forKey: .refusal))
        default: self = .custom(try JSONValue(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        if case .custom(let value) = self {
            try value.encode(to: encoder)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .imageURL(let image):
            try container.encode("image_url", forKey: .type)
            try container.encode(image, forKey: .imageURL)
        case .inputAudio(let audio):
            try container.encode("input_audio", forKey: .type)
            try container.encode(audio, forKey: .inputAudio)
        case .file(let file):
            try container.encode("file", forKey: .type)
            try container.encode(file, forKey: .file)
        case .refusal(let text):
            try container.encode("refusal", forKey: .type)
            try container.encode(text, forKey: .refusal)
        case .custom: break
        }
    }
}

/// An image URL or a data URL. Detail accepts provider-supported strings such as `auto`, `low`, and `high`.
public struct ChatImageURL: Codable, Sendable, Equatable {
    public var url: String
    public var detail: String?

    public init(url: String, detail: String? = nil) {
        self.url = url
        self.detail = detail
    }
}

/// Base64 audio input with a provider-supported format such as `wav` or `mp3`.
public struct ChatInputAudio: Codable, Sendable, Equatable {
    public var data: String
    public var format: String

    public init(data: String, format: String) {
        self.data = data
        self.format = format
    }
}

/// A file content part using either an uploaded file identifier or base64 file data.
public struct ChatFile: Codable, Sendable, Equatable {
    public var fileID: String?
    public var fileData: String?
    public var filename: String?

    public init(fileID: String? = nil, fileData: String? = nil, filename: String? = nil) {
        self.fileID = fileID
        self.fileData = fileData
        self.filename = filename
    }

    private enum CodingKeys: String, CodingKey {
        case filename
        case fileID = "file_id"
        case fileData = "file_data"
    }
}

/// A function invocation. Arguments are JSON text and may be incomplete while streaming.
public struct ChatFunctionCall: Codable, Sendable, Equatable {
    public var name: String
    public var arguments: String

    public init(name: String, arguments: String) {
        self.name = name
        self.arguments = arguments
    }

    /// Decodes completed function arguments into an application-specific model.
    public func decodeArguments<Value: Decodable>(as type: Value.Type = Value.self) throws -> Value {
        try JSONDecoder().decode(type, from: Data(arguments.utf8))
    }
}

/// A tool call returned by a model or replayed in an assistant message.
public struct ChatToolCall: Codable, Sendable, Equatable {
    public var id: String
    public var type: String
    public var function: ChatFunctionCall
    public var custom: ChatCustomCall?

    public init(id: String, type: String = "function", function: ChatFunctionCall) {
        self.id = id
        self.type = type
        self.function = function
    }

    public init(id: String, custom: ChatCustomCall) {
        self.id = id
        type = "custom"
        function = ChatFunctionCall(name: "", arguments: "")
        self.custom = custom
    }

    private enum CodingKeys: String, CodingKey { case id, type, function, custom }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        function =
            try container.decodeIfPresent(ChatFunctionCall.self, forKey: .function)
            ?? ChatFunctionCall(name: "", arguments: "")
        custom = try container.decodeIfPresent(ChatCustomCall.self, forKey: .custom)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        if type == "custom" {
            try container.encodeIfPresent(custom, forKey: .custom)
        } else {
            try container.encode(function, forKey: .function)
        }
    }
}

public struct ChatCustomCall: Codable, Sendable, Equatable {
    public var name: String
    public var input: String
    public init(name: String, input: String) {
        self.name = name
        self.input = input
    }
}
