import Foundation

/// Legacy text Completions, supported by many OpenAI-compatible inference servers.
public struct CompletionsService: Sendable {
    public let client: OpenAIClient

    public init(client: OpenAIClient) { self.client = client }

    /// Creates a completed text response, forcing `stream: false`.
    public func create(_ request: CompletionRequest, options: RequestOptions = .init()) async throws -> Completion {
        var options = options
        options.extraBody["stream"] = .bool(false)
        return try await client.send(.post, path: "completions", body: request, options: options)
    }

    /// Streams text completion events, forcing `stream: true`.
    public func stream(
        _ request: CompletionRequest,
        options: RequestOptions = .init()
    ) async throws -> OpenAIStream<Completion> {
        var options = options
        options.extraBody["stream"] = .bool(true)
        return try await client.stream(path: "completions", body: request, options: options)
    }
}

/// A legacy prompt accepts text, multiple texts, token IDs, or batches of token IDs.
public enum CompletionPrompt: Codable, Sendable, Equatable, ExpressibleByStringLiteral {
    case text(String)
    case texts([String])
    case tokens([Int])
    case tokenBatches([[Int]])

    public init(stringLiteral value: String) { self = .text(value) }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else if let texts = try? container.decode([String].self) {
            self = .texts(texts)
        } else if let tokens = try? container.decode([Int].self) {
            self = .tokens(tokens)
        } else {
            self = .tokenBatches(try container.decode([[Int]].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value): try container.encode(value)
        case .texts(let values): try container.encode(values)
        case .tokens(let values): try container.encode(values)
        case .tokenBatches(let values): try container.encode(values)
        }
    }
}

/// Parameters for the legacy text Completions endpoint.
public struct CompletionRequest: Codable, Sendable, Equatable {
    public var model: String
    public var prompt: CompletionPrompt
    public var maxTokens: Int?
    public var temperature: Double?
    public var topP: Double?
    public var n: Int?
    public var stop: CompletionStop?
    public var seed: Int?
    public var suffix: String?
    public var echo: Bool?
    public var bestOf: Int?
    public var frequencyPenalty: Double?
    public var presencePenalty: Double?
    public var logitBias: [String: Double]?
    public var logprobs: Int?
    public var user: String?
    public var streamOptions: ChatStreamOptions?

    public init(
        model: String,
        prompt: CompletionPrompt,
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        n: Int? = nil,
        stop: CompletionStop? = nil,
        seed: Int? = nil,
        suffix: String? = nil,
        echo: Bool? = nil,
        bestOf: Int? = nil,
        frequencyPenalty: Double? = nil,
        presencePenalty: Double? = nil,
        logitBias: [String: Double]? = nil,
        logprobs: Int? = nil,
        user: String? = nil,
        streamOptions: ChatStreamOptions? = nil
    ) {
        self.model = model
        self.prompt = prompt
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.n = n
        self.stop = stop
        self.seed = seed
        self.suffix = suffix
        self.echo = echo
        self.bestOf = bestOf
        self.frequencyPenalty = frequencyPenalty
        self.presencePenalty = presencePenalty
        self.logitBias = logitBias
        self.logprobs = logprobs
        self.user = user
        self.streamOptions = streamOptions
    }

    private enum CodingKeys: String, CodingKey {
        case model, prompt, temperature, n, stop, seed, suffix, echo, logprobs, user
        case maxTokens = "max_tokens"
        case topP = "top_p"
        case bestOf = "best_of"
        case frequencyPenalty = "frequency_penalty"
        case presencePenalty = "presence_penalty"
        case logitBias = "logit_bias"
        case streamOptions = "stream_options"
    }
}

/// A legacy completion response; streaming events use the same shape with partial choice text.
public struct Completion: Codable, Sendable, Equatable {
    public var id: String
    public var choices: [CompletionChoice]
    public var created: Int?
    public var model: String?
    public var object: String?
    public var usage: CompletionUsage?
    public var systemFingerprint: String?

    public init(
        id: String,
        choices: [CompletionChoice],
        created: Int? = nil,
        model: String? = nil,
        object: String? = nil,
        usage: CompletionUsage? = nil,
        systemFingerprint: String? = nil
    ) {
        self.id = id
        self.choices = choices
        self.created = created
        self.model = model
        self.object = object
        self.usage = usage
        self.systemFingerprint = systemFingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case id, choices, created, model, object, usage
        case systemFingerprint = "system_fingerprint"
    }
}

/// A legacy completion choice, including optional token probability data.
public struct CompletionChoice: Codable, Sendable, Equatable {
    public var index: Int
    public var text: String
    public var finishReason: String?
    public var logprobs: CompletionLogprobs?

    public init(index: Int, text: String, finishReason: String? = nil, logprobs: CompletionLogprobs? = nil) {
        self.index = index
        self.text = text
        self.finishReason = finishReason
        self.logprobs = logprobs
    }

    private enum CodingKeys: String, CodingKey {
        case index, text, logprobs
        case finishReason = "finish_reason"
    }
}

/// Legacy token probability arrays. Individual probabilities and alternatives can be null.
public struct CompletionLogprobs: Codable, Sendable, Equatable {
    public var textOffset: [Int]?
    public var tokenLogprobs: [Double?]?
    public var tokens: [String]?
    public var topLogprobs: [[String: Double]?]?

    public init(
        textOffset: [Int]? = nil,
        tokenLogprobs: [Double?]? = nil,
        tokens: [String]? = nil,
        topLogprobs: [[String: Double]?]? = nil
    ) {
        self.textOffset = textOffset
        self.tokenLogprobs = tokenLogprobs
        self.tokens = tokens
        self.topLogprobs = topLogprobs
    }

    private enum CodingKeys: String, CodingKey {
        case tokens
        case textOffset = "text_offset"
        case tokenLogprobs = "token_logprobs"
        case topLogprobs = "top_logprobs"
    }
}
