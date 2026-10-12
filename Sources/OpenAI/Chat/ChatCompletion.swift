import Foundation

/// A completed Chat Completions response. Optional metadata tolerates compatible providers.
public struct ChatCompletion: Codable, Sendable, Equatable {
    public var id: String
    public var choices: [ChatCompletionChoice]
    public var created: Int?
    public var model: String?
    public var object: String?
    public var usage: CompletionUsage?
    public var systemFingerprint: String?
    public var serviceTier: String?

    public init(
        id: String,
        choices: [ChatCompletionChoice],
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

/// One generated assistant message and its termination reason.
public struct ChatCompletionChoice: Codable, Sendable, Equatable {
    public var index: Int
    public var message: ChatMessage
    public var finishReason: String?
    public var logprobs: ChatLogprobs?

    public init(index: Int, message: ChatMessage, finishReason: String? = nil, logprobs: ChatLogprobs? = nil) {
        self.index = index
        self.message = message
        self.finishReason = finishReason
        self.logprobs = logprobs
    }

    private enum CodingKeys: String, CodingKey {
        case index, message, logprobs
        case finishReason = "finish_reason"
    }
}

/// Token usage shared by chat and legacy completions.
public struct CompletionUsage: Codable, Sendable, Equatable {
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var totalTokens: Int?
    public var promptTokensDetails: PromptTokenDetails?
    public var completionTokensDetails: CompletionTokenDetails?

    public init(
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        totalTokens: Int? = nil,
        promptTokensDetails: PromptTokenDetails? = nil,
        completionTokensDetails: CompletionTokenDetails? = nil
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.promptTokensDetails = promptTokensDetails
        self.completionTokensDetails = completionTokensDetails
    }

    private enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case promptTokensDetails = "prompt_tokens_details"
        case completionTokensDetails = "completion_tokens_details"
    }
}

/// Cached and audio input token accounting.
public struct PromptTokenDetails: Codable, Sendable, Equatable {
    public var cachedTokens: Int?
    public var audioTokens: Int?

    public init(cachedTokens: Int? = nil, audioTokens: Int? = nil) {
        self.cachedTokens = cachedTokens
        self.audioTokens = audioTokens
    }

    private enum CodingKeys: String, CodingKey {
        case cachedTokens = "cached_tokens"
        case audioTokens = "audio_tokens"
    }
}

/// Reasoning, audio, and predicted output token accounting.
public struct CompletionTokenDetails: Codable, Sendable, Equatable {
    public var reasoningTokens: Int?
    public var audioTokens: Int?
    public var acceptedPredictionTokens: Int?
    public var rejectedPredictionTokens: Int?

    public init(
        reasoningTokens: Int? = nil,
        audioTokens: Int? = nil,
        acceptedPredictionTokens: Int? = nil,
        rejectedPredictionTokens: Int? = nil
    ) {
        self.reasoningTokens = reasoningTokens
        self.audioTokens = audioTokens
        self.acceptedPredictionTokens = acceptedPredictionTokens
        self.rejectedPredictionTokens = rejectedPredictionTokens
    }

    private enum CodingKeys: String, CodingKey {
        case reasoningTokens = "reasoning_tokens"
        case audioTokens = "audio_tokens"
        case acceptedPredictionTokens = "accepted_prediction_tokens"
        case rejectedPredictionTokens = "rejected_prediction_tokens"
    }
}

/// Token probabilities for assistant content and refusal text.
public struct ChatLogprobs: Codable, Sendable, Equatable {
    public var content: [ChatTokenLogprob]?
    public var refusal: [ChatTokenLogprob]?

    public init(content: [ChatTokenLogprob]? = nil, refusal: [ChatTokenLogprob]? = nil) {
        self.content = content
        self.refusal = refusal
    }
}

/// A generated token, its UTF-8 bytes, and alternative token probabilities.
public struct ChatTokenLogprob: Codable, Sendable, Equatable {
    public var token: String
    public var logprob: Double
    public var bytes: [Int]?
    public var topLogprobs: [ChatTopLogprob]?

    public init(token: String, logprob: Double, bytes: [Int]? = nil, topLogprobs: [ChatTopLogprob]? = nil) {
        self.token = token
        self.logprob = logprob
        self.bytes = bytes
        self.topLogprobs = topLogprobs
    }

    private enum CodingKeys: String, CodingKey {
        case token, logprob, bytes
        case topLogprobs = "top_logprobs"
    }
}

/// An alternative token considered at a generated position.
public struct ChatTopLogprob: Codable, Sendable, Equatable {
    public var token: String
    public var logprob: Double
    public var bytes: [Int]?

    public init(token: String, logprob: Double, bytes: [Int]? = nil) {
        self.token = token
        self.logprob = logprob
        self.bytes = bytes
    }
}
