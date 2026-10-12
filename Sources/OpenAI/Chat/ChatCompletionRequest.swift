import Foundation

/// Parameters for Chat Completions. Model names and provider-specific values remain open strings.
public struct ChatCompletionRequest: Codable, Sendable, Equatable {
    public var model: String
    public var messages: [ChatMessage]
    public var temperature: Double?
    public var topP: Double?
    public var maxTokens: Int?
    public var maxCompletionTokens: Int?
    public var n: Int?
    public var stop: CompletionStop?
    public var frequencyPenalty: Double?
    public var presencePenalty: Double?
    public var logitBias: [String: Double]?
    public var logprobs: Bool?
    public var topLogprobs: Int?
    public var tools: [ChatTool]?
    public var toolChoice: ChatToolChoice?
    public var parallelToolCalls: Bool?
    public var responseFormat: ChatResponseFormat?
    public var seed: Int?
    public var user: String?
    public var streamOptions: ChatStreamOptions?
    public var reasoningEffort: String?
    public var verbosity: String?
    public var serviceTier: String?
    public var store: Bool?
    public var metadata: [String: String]?
    public var modalities: [String]?
    public var audio: ChatAudioConfiguration?
    public var prediction: ChatPrediction?
    public var webSearchOptions: JSONValue?
    public var promptCacheKey: String?
    public var promptCacheRetention: String?
    public var safetyIdentifier: String?
    public var functions: [ChatFunctionDefinition]?
    public var functionCall: JSONValue?

    /// Creates a request. Remaining optional parameters can be assigned before sending.
    public init(
        model: String,
        messages: [ChatMessage],
        temperature: Double? = nil,
        topP: Double? = nil,
        maxTokens: Int? = nil,
        maxCompletionTokens: Int? = nil,
        n: Int? = nil,
        stop: CompletionStop? = nil,
        tools: [ChatTool]? = nil,
        toolChoice: ChatToolChoice? = nil,
        responseFormat: ChatResponseFormat? = nil,
        streamOptions: ChatStreamOptions? = nil,
        reasoningEffort: String? = nil
    ) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.maxCompletionTokens = maxCompletionTokens
        self.n = n
        self.stop = stop
        self.tools = tools
        self.toolChoice = toolChoice
        self.responseFormat = responseFormat
        self.streamOptions = streamOptions
        self.reasoningEffort = reasoningEffort
    }

    private enum CodingKeys: String, CodingKey {
        case model, messages, temperature, n, stop, logprobs, tools, seed, user, verbosity, store, metadata
        case modalities, audio, prediction, functions
        case topP = "top_p"
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
        case frequencyPenalty = "frequency_penalty"
        case presencePenalty = "presence_penalty"
        case logitBias = "logit_bias"
        case topLogprobs = "top_logprobs"
        case toolChoice = "tool_choice"
        case parallelToolCalls = "parallel_tool_calls"
        case responseFormat = "response_format"
        case streamOptions = "stream_options"
        case reasoningEffort = "reasoning_effort"
        case serviceTier = "service_tier"
        case webSearchOptions = "web_search_options"
        case promptCacheKey = "prompt_cache_key"
        case promptCacheRetention = "prompt_cache_retention"
        case safetyIdentifier = "safety_identifier"
        case functionCall = "function_call"
    }
}

/// One stop sequence or several stop sequences, encoded using the API's string-or-array union.
public enum CompletionStop: Codable, Sendable, Equatable, ExpressibleByStringLiteral, ExpressibleByArrayLiteral {
    case string(String)
    case strings([String])

    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: String...) { self = .strings(elements) }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .string(string)
        } else {
            self = .strings(try container.decode([String].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .strings(let values): try container.encode(values)
        }
    }
}

/// Streaming usage settings. Providers may omit usage even when requested.
public struct ChatStreamOptions: Codable, Sendable, Equatable {
    public var includeUsage: Bool?
    public var includeObfuscation: Bool?

    public init(includeUsage: Bool? = nil, includeObfuscation: Bool? = nil) {
        self.includeUsage = includeUsage
        self.includeObfuscation = includeObfuscation
    }

    private enum CodingKeys: String, CodingKey {
        case includeUsage = "include_usage"
        case includeObfuscation = "include_obfuscation"
    }
}

/// A callable function's name, description, and JSON Schema parameters.
public struct ChatFunctionDefinition: Codable, Sendable, Equatable {
    public var name: String
    public var description: String?
    public var parameters: JSONValue?
    public var strict: Bool?

    public init(name: String, description: String? = nil, parameters: JSONValue? = nil, strict: Bool? = nil) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.strict = strict
    }
}

/// A declared function tool or a future provider-specific tool definition.
public enum ChatTool: Codable, Sendable, Equatable {
    case function(ChatFunctionDefinition)
    case custom(JSONValue)

    private enum CodingKeys: String, CodingKey { case type, function }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decode(String.self, forKey: .type) == "function" {
            self = .function(try container.decode(ChatFunctionDefinition.self, forKey: .function))
        } else {
            self = .custom(try JSONValue(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .function(let function):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("function", forKey: .type)
            try container.encode(function, forKey: .function)
        case .custom(let value): try value.encode(to: encoder)
        }
    }
}

/// Selects automatic tool use, no tool use, required tool use, or a named function.
public enum ChatToolChoice: Codable, Sendable, Equatable, ExpressibleByStringLiteral {
    case mode(String)
    case function(String)
    case custom(JSONValue)

    public static let auto: Self = .mode("auto")
    public static let none: Self = .mode("none")
    /// Disables tool use without ambiguity with `Optional.none` at optional argument sites.
    public static let disabled: Self = .mode("none")
    public static let required: Self = .mode("required")

    public init(stringLiteral value: String) { self = .mode(value) }

    public init(from decoder: any Decoder) throws {
        let value = try JSONValue(from: decoder)
        if let string = value.stringValue {
            self = .mode(string)
        } else if value["type"]?.stringValue == "function", let name = value["function"]?["name"]?.stringValue {
            self = .function(name)
        } else {
            self = .custom(value)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .mode(let mode): try JSONValue.string(mode).encode(to: encoder)
        case .function(let name):
            try JSONValue.object(["type": "function", "function": .object(["name": .string(name)])]).encode(to: encoder)
        case .custom(let value): try value.encode(to: encoder)
        }
    }
}

/// Output text, JSON objects, or JSON constrained by a named schema.
public enum ChatResponseFormat: Codable, Sendable, Equatable {
    case text
    case jsonObject
    case jsonSchema(ChatJSONSchema)
    case custom(JSONValue)

    private enum CodingKeys: String, CodingKey {
        case type
        case jsonSchema = "json_schema"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "text": self = .text
        case "json_object": self = .jsonObject
        case "json_schema": self = .jsonSchema(try container.decode(ChatJSONSchema.self, forKey: .jsonSchema))
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
        case .text: try container.encode("text", forKey: .type)
        case .jsonObject: try container.encode("json_object", forKey: .type)
        case .jsonSchema(let schema):
            try container.encode("json_schema", forKey: .type)
            try container.encode(schema, forKey: .jsonSchema)
        case .custom: break
        }
    }
}

/// A structured-output schema. `strict` asks the server to enforce supported JSON Schema constraints.
public struct ChatJSONSchema: Codable, Sendable, Equatable {
    public var name: String
    public var description: String?
    public var schema: JSONValue
    public var strict: Bool?

    public init(name: String, description: String? = nil, schema: JSONValue, strict: Bool? = nil) {
        self.name = name
        self.description = description
        self.schema = schema
        self.strict = strict
    }
}

/// Requested audio format and voice. Strings permit compatible provider values.
public struct ChatAudioConfiguration: Codable, Sendable, Equatable {
    public var format: String
    public var voice: String

    public init(format: String, voice: String) {
        self.format = format
        self.voice = voice
    }
}

/// Predicted content supplied to reduce latency when much of the output is already known.
public struct ChatPrediction: Codable, Sendable, Equatable {
    public var type: String
    public var content: ChatContent

    public init(content: ChatContent, type: String = "content") {
        self.type = type
        self.content = content
    }
}
