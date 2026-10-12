import Foundation

/// Accumulates a single stream into ordered choices and tool calls without assuming contiguous indices.
/// This value has no shared state; keep it in the task consuming the stream.
public struct ChatCompletionAccumulator: Sendable {
    private var response: ChatCompletion?
    private var choices: [Int: AccumulatedChoice] = [:]

    private var states: [Int: FinishedPart] = [:]
    private var legacyStates: [Int: FinishedPart] = [:]
    private var legacyFinished: FinishedPart?
    private var finished: [Int: Set<FinishedPart>] = [:]
    private var finishedTools: [Int: Int] = [:]
    private var firstChoice: Int?

    private enum FinishedPart: Hashable, Sendable {
        case content, refusal
        case tool(Int)
        case empty
    }

    public init() {}

    /// Completion boundaries are available until the next `add`, including a rejected chunk.
    public func justFinishedContent(forChoice index: Int? = nil) -> String? {
        guard let choice = index ?? firstChoice,
            index == nil ? legacyFinished == .content : finished[choice]?.contains(.content) == true
        else { return nil }
        return choices[choice]?.content ?? ""
    }

    public func justFinishedRefusal(forChoice index: Int? = nil) -> String? {
        guard let choice = index ?? firstChoice,
            index == nil ? legacyFinished == .refusal : finished[choice]?.contains(.refusal) == true
        else { return nil }
        return choices[choice]?.refusal ?? ""
    }

    /// Tool boundaries cannot reliably identify completion when parallel tool calls interleave.
    public func justFinishedToolCall(forChoice index: Int? = nil) -> FinishedChatCompletionToolCall? {
        if index == nil {
            guard let choice = firstChoice, case .tool(let tool) = legacyFinished,
                let call = choices[choice]?.tools[tool]?.call
            else { return nil }
            return FinishedChatCompletionToolCall(index: tool, call: call)
        }
        guard let index, let tool = finishedTools[index], let call = choices[index]?.tools[tool]?.call
        else { return nil }
        return FinishedChatCompletionToolCall(index: tool, call: call)
    }

    private func accepts(_ chunk: ChatCompletionChunk) -> Bool {
        var counts = choices.mapValues { ($0.tools.keys.max() ?? -1) + 1 }
        var extra = 0
        for part in chunk.choices {
            guard (0...127).contains(part.index) else { return false }
            for tool in part.delta.toolCalls ?? [] {
                let index = tool.index == -1 ? 0 : tool.index
                let count = counts[part.index] ?? 0
                guard index >= 0, index < Int.max, index < count || index - count < 128 else { return false }
                let growth = max(0, index + 1 - count)
                extra += growth - 1
                counts[part.index] = max(count, index + 1)
            }
        }
        return extra <= 127
    }

    /// The current response snapshot, or `nil` until the first chunk arrives.
    /// Function arguments can remain incomplete until the corresponding choice finishes.
    public var completion: ChatCompletion? {
        guard var response else { return nil }
        response.choices = choices.keys.sorted().compactMap { choices[$0]?.choice }
        return response
    }

    /// Appends an event. Returns `false` without mutation if it belongs to a different response ID.
    @discardableResult
    public mutating func add(_ chunk: ChatCompletionChunk) -> Bool {
        finished.removeAll(keepingCapacity: true)
        finishedTools.removeAll(keepingCapacity: true)
        legacyFinished = nil
        firstChoice = chunk.choices.first?.index
        guard accepts(chunk) else { return false }
        if let response, response.id != chunk.id { return false }
        if response == nil {
            response = ChatCompletion(id: chunk.id, choices: [], object: "chat.completion")
        }
        if let value = chunk.created { response?.created = value }
        if let value = chunk.model { response?.model = value }
        if let value = chunk.usage { response?.usage = value }
        if let value = chunk.systemFingerprint { response?.systemFingerprint = value }
        if let value = chunk.serviceTier { response?.serviceTier = value }

        for (position, part) in chunk.choices.enumerated() {
            var choice = choices[part.index] ?? AccumulatedChoice(index: part.index)
            choice.append(part)
            choices[part.index] = choice
            let delta = part.delta
            let state: FinishedPart
            if let tool = delta.toolCalls?.first, delta.content == nil || delta.content == "" {
                state = .tool(max(0, tool.index))
            } else if delta.content != nil {
                state = .content
            } else if delta.refusal != nil {
                state = .refusal
            } else if let tool = delta.toolCalls?.first {
                state = .tool(max(0, tool.index))
            } else {
                state = .empty
            }
            if position == 0 {
                if let previous = legacyStates[part.index], previous != state, previous != .empty {
                    legacyFinished = previous
                }
                legacyStates[part.index] = state
            }
            if let previous = states[part.index], previous != state, previous != .empty {
                finished[part.index, default: []].insert(previous)
                if case .tool(let tool) = previous, finishedTools[part.index] == nil {
                    finishedTools[part.index] = tool
                }
            }
            states[part.index] = state
        }
        return true
    }

    /// Discards the accumulated response so this value can consume another stream.
    public mutating func reset() {
        response = nil
        choices.removeAll(keepingCapacity: true)
        states.removeAll(keepingCapacity: true)
        legacyStates.removeAll(keepingCapacity: true)
        legacyFinished = nil
        finished.removeAll(keepingCapacity: true)
        finishedTools.removeAll(keepingCapacity: true)
        firstChoice = nil
    }
}

private struct AccumulatedChoice: Sendable {
    var index: Int
    var role = "assistant"
    var content: String?
    var refusal: String?
    var reasoningContent: String?
    var reasoning: String?
    var finishReason: String?
    var logprobs: ChatLogprobs?
    var tools: [Int: AccumulatedTool] = [:]
    var functionCall: ChatFunctionCall?
    var audio: JSONValue?
    var annotations: [JSONValue]?

    var choice: ChatCompletionChoice {
        let calls = tools.keys.sorted().compactMap { tools[$0]?.call }
        return ChatCompletionChoice(
            index: index,
            message: ChatMessage(
                role: role,
                content: content.map(ChatContent.text),
                toolCalls: calls.isEmpty ? nil : calls,
                functionCall: functionCall,
                refusal: refusal,
                reasoningContent: reasoningContent,
                audio: audio,
                annotations: annotations,
                reasoning: reasoning
            ),
            finishReason: finishReason,
            logprobs: logprobs
        )
    }

    mutating func append(_ part: ChatCompletionChunkChoice) {
        let delta = part.delta
        if let value = delta.role { role = value }
        if let value = delta.content { content = (content ?? "") + value }
        if let value = delta.refusal { refusal = (refusal ?? "") + value }
        if let value = delta.reasoningContent { reasoningContent = (reasoningContent ?? "") + value }
        if let value = delta.reasoning { reasoning = (reasoning ?? "") + value }
        if let value = delta.audio { appendAudio(value) }
        if let value = delta.annotations { annotations = (annotations ?? []) + value }
        if let value = part.finishReason { finishReason = value }
        if let value = part.logprobs {
            var accumulated = logprobs ?? ChatLogprobs()
            if let content = value.content { accumulated.content = (accumulated.content ?? []) + content }
            if let refusal = value.refusal { accumulated.refusal = (accumulated.refusal ?? []) + refusal }
            logprobs = accumulated
        }
        if let value = delta.functionCall {
            if functionCall == nil { functionCall = ChatFunctionCall(name: "", arguments: "") }
            if let name = value.name { functionCall?.name += name }
            if let arguments = value.arguments { functionCall?.arguments += arguments }
        }
        for tool in delta.toolCalls ?? [] {
            var accumulated = tools[max(0, tool.index)] ?? AccumulatedTool()
            accumulated.append(tool)
            tools[max(0, tool.index)] = accumulated
        }
    }

    private mutating func appendAudio(_ value: JSONValue) {
        guard let fields = value.objectValue else {
            audio = value
            return
        }
        var accumulated = audio?.objectValue ?? [:]
        for (key, value) in fields {
            if ["data", "text", "transcript"].contains(key), let text = value.stringValue {
                accumulated[key] = .string((accumulated[key]?.stringValue ?? "") + text)
            } else {
                accumulated[key] = value
            }
        }
        audio = .object(accumulated)
    }
}

private struct AccumulatedTool: Sendable {
    var id = ""
    var type = "function"
    var name = ""
    var arguments = ""

    var call: ChatToolCall {
        ChatToolCall(id: id, type: type, function: ChatFunctionCall(name: name, arguments: arguments))
    }

    mutating func append(_ delta: ChatToolCallDelta) {
        if let value = delta.id { id += value }
        if let value = delta.type { type = value }
        if let value = delta.function?.name { name += value }
        if let value = delta.function?.arguments { arguments += value }
    }
}

/// A completed function call together with its protocol index.
public struct FinishedChatCompletionToolCall: Sendable, Equatable {
    public let index: Int
    public let call: ChatToolCall
    public var id: String { call.id }
    public var name: String { call.function.name }
    public var arguments: String { call.function.arguments }
}
