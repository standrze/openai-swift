import Foundation

/// One SSE chat completion event. A final usage event can contain no choices.
public struct ChatCompletionChunk: Codable, Sendable, Equatable {
    public var id: String
    public var choices: [ChatCompletionChunkChoice]
    public var created: Int?
    public var model: String?
    public var object: String?
    public var usage: CompletionUsage?
    public var systemFingerprint: String?
    public var serviceTier: String?

    public init(
        id: String,
        choices: [ChatCompletionChunkChoice],
        created: Int? = nil,
        model: String? = nil,
        object: String? = nil,
        usage: CompletionUsage? = nil,
        systemFingerprint: String? = nil,
        serviceTier: String? = nil
    ) {
        self.id = id
        self.choices = choices
        self.created = created
        self.model = model
        self.object = object
        self.usage = usage
        self.systemFingerprint = systemFingerprint
        self.serviceTier = serviceTier
    }

    private enum CodingKeys: String, CodingKey {
        case id, choices, created, model, object, usage
        case systemFingerprint = "system_fingerprint"
        case serviceTier = "service_tier"
    }
}

/// One indexed choice delta. Termination reasons are strings to support provider extensions.
public struct ChatCompletionChunkChoice: Codable, Sendable, Equatable {
    public var index: Int
    public var delta: ChatCompletionDelta
    public var finishReason: String?
    public var logprobs: ChatLogprobs?

    public init(
        index: Int,
        delta: ChatCompletionDelta = .init(),
        finishReason: String? = nil,
        logprobs: ChatLogprobs? = nil
    ) {
        self.index = index
        self.delta = delta
        self.finishReason = finishReason
        self.logprobs = logprobs
    }

    private enum CodingKeys: String, CodingKey {
        case index, delta, logprobs
        case finishReason = "finish_reason"
    }
}

/// Incremental assistant output. String fragments must be appended in arrival order.
public struct ChatCompletionDelta: Codable, Sendable, Equatable {
    public var role: String?
    public var content: String?
    public var refusal: String?
    public var reasoningContent: String?
    public var toolCalls: [ChatToolCallDelta]?
    public var functionCall: ChatFunctionCallDelta?
    public var audio: JSONValue?
    public var annotations: [JSONValue]?
    /// Ollama's incremental reasoning output; append fragments in arrival order.
    public var reasoning: String?

    public init(
        role: String? = nil,
        content: String? = nil,
        refusal: String? = nil,
        reasoningContent: String? = nil,
        toolCalls: [ChatToolCallDelta]? = nil,
        functionCall: ChatFunctionCallDelta? = nil,
        audio: JSONValue? = nil,
        annotations: [JSONValue]? = nil,
        reasoning: String? = nil
    ) {
        self.role = role
        self.content = content
        self.refusal = refusal
        self.reasoningContent = reasoningContent
        self.toolCalls = toolCalls
        self.functionCall = functionCall
        self.audio = audio
        self.annotations = annotations
        self.reasoning = reasoning
    }

    private enum CodingKeys: String, CodingKey {
        case role, content, refusal, audio, annotations, reasoning
        case reasoningContent = "reasoning_content"
        case toolCalls = "tool_calls"
        case functionCall = "function_call"
    }
}

/// A tool-call fragment associated with an explicit index, independent of choice index.
public struct ChatToolCallDelta: Codable, Sendable, Equatable {
    public var index: Int
    public var id: String?
    public var type: String?
    public var function: ChatFunctionCallDelta?

    public init(index: Int, id: String? = nil, type: String? = nil, function: ChatFunctionCallDelta? = nil) {
        self.index = index
        self.id = id
        self.type = type
        self.function = function
    }
}

/// Partial function name and JSON argument text; neither needs to be complete in an event.
public struct ChatFunctionCallDelta: Codable, Sendable, Equatable {
    public var name: String?
    public var arguments: String?

    public init(name: String? = nil, arguments: String? = nil) {
        self.name = name
        self.arguments = arguments
    }
}
