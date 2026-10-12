import Foundation

/// A local view of streamed output. Only `response` contains a final server response.
public struct ResponseSnapshot: Sendable {
    public let streamID: String?
    public let id: String?
    public let output: [ResponseOutputItem]
    public let outputText: String
    public let terminalEvent: String?
    public let response: Response?
    /// Latest lifecycle metadata and accumulated output, including unknown fields.
    public let rawValue: JSONValue
}

/// Accumulates one Responses stream without inventing a completed server response.
/// Keep this value in the task consuming the stream; unknown event kinds are ignored.
public struct ResponseAccumulator: Sendable {
    private static let supportedEvents: Set<String> = [
        "response.created", "response.in_progress", "response.completed", "response.failed", "response.incomplete",
        "response.output_item.added", "response.output_item.done",
        "response.content_part.added", "response.content_part.done",
        "response.output_text.delta", "response.output_text.done", "response.refusal.delta", "response.refusal.done",
        "response.function_call_arguments.delta", "response.function_call_arguments.done",
        "response.custom_tool_call_input.delta", "response.custom_tool_call_input.done",
        "response.output_text.annotation.added",
    ]
    private var id: String?
    private var items: [Int: AccumulatedResponseItem] = [:]
    private var terminalEvent: String?
    private var response: Response?
    private var metadata: [String: JSONValue] = [:]

    public init() {}

    public var detailedSnapshot: ResponseAccumulatorDetails {
        var response = metadata
        response.removeValue(forKey: "output")
        return ResponseAccumulatorDetails(
            streamID: nil, responseID: id, terminalEvent: terminalEvent, response: response,
            output: items.keys.sorted().compactMap { index in items[index]?.details(index: index) })
    }

    /// Output and content parts are sorted by their original, possibly sparse indices.
    public var snapshot: ResponseSnapshot {
        let output = items.keys.sorted().compactMap { items[$0]?.value }
        let text = output.flatMap(\.content).compactMap { $0.type == "output_text" ? $0.text : nil }.joined()
        var raw = metadata
        raw["output"] = .array(output.map(\.rawValue))
        return ResponseSnapshot(
            streamID: nil, id: id, output: output, outputText: text, terminalEvent: terminalEvent, response: response,
            rawValue: .object(raw))
    }

    /// Appends fragments and applies authoritative done payloads. Mixed response IDs are rejected.
    /// Text and function arguments may remain incomplete until the corresponding done event.
    public mutating func add(_ event: ResponseEvent) throws {
        var updated = self
        try updated.consume(event)
        self = updated
    }

    /// Discards all output, identifiers, and terminal state before consuming another stream.
    public mutating func reset() {
        id = nil
        items.removeAll(keepingCapacity: true)
        terminalEvent = nil
        response = nil
        metadata.removeAll(keepingCapacity: true)
    }

    private mutating func consume(_ event: ResponseEvent) throws {
        guard Self.supportedEvents.contains(event.type) else { return }
        for incomingID in [event.response?.id, event.rawValue["response_id"]?.stringValue].compactMap({ $0 }) {
            if let id, id != incomingID {
                throw OpenAIClientError.invalidStream("Cannot accumulate events from different response IDs")
            }
            id = incomingID
        }

        switch event.type {
        case "response.created", "response.in_progress":
            applyResponseOutput(event.response)
        case "response.completed", "response.failed", "response.incomplete":
            applyResponseOutput(event.response)
            terminalEvent = event.type
            response = event.response
        case "response.output_item.added", "response.output_item.done":
            let index = try outputIndex(event)
            guard let item = event.item else {
                throw OpenAIClientError.invalidStream("Output item event is missing its item")
            }
            items[index] = AccumulatedResponseItem(item)
        case "response.content_part.added", "response.content_part.done":
            let index = try outputIndex(event)
            let partIndex = try contentIndex(event)
            guard let part = event.part else {
                throw OpenAIClientError.invalidStream("Content part event is missing its part")
            }
            var item = try accumulatedItem(at: index, id: event.itemID, type: "message")
            try item.setPart(part, at: partIndex)
            items[index] = item
        case "response.output_text.delta", "response.output_text.done", "response.refusal.delta",
            "response.refusal.done":
            let index = try outputIndex(event)
            let partIndex = try contentIndex(event)
            let isRefusal = event.type.hasPrefix("response.refusal.")
            let isDone = event.type.hasSuffix(".done")
            let text =
                isDone ? (isRefusal ? event.rawValue["refusal"]?.stringValue : event.text) : event.delta?.stringValue
            guard let text else {
                throw OpenAIClientError.invalidStream("Text event is missing its text or delta")
            }
            var item = try accumulatedItem(at: index, id: event.itemID, type: "message")
            try item.setText(text, at: partIndex, refusal: isRefusal, replace: isDone)
            if let logprobs = event.rawValue["logprobs"]?.arrayValue {
                try item.setLogprobs(logprobs, at: partIndex, replace: isDone)
            }
            items[index] = item
        case "response.function_call_arguments.delta", "response.function_call_arguments.done":
            let index = try outputIndex(event)
            let isDone = event.type.hasSuffix(".done")
            guard let arguments = isDone ? event.arguments : event.delta?.stringValue else {
                throw OpenAIClientError.invalidStream("Function argument event is missing its arguments or delta")
            }
            var item = try accumulatedItem(at: index, id: event.itemID, type: "function_call")
            try item.setArguments(arguments, replace: isDone)
            items[index] = item
        case "response.custom_tool_call_input.delta", "response.custom_tool_call_input.done":
            let index = try outputIndex(event)
            let done = event.type.hasSuffix(".done")
            guard let input = done ? event.rawValue["input"]?.stringValue : event.delta?.stringValue else {
                throw OpenAIClientError.invalidStream("Custom tool event is missing input or delta")
            }
            var item = try accumulatedItem(at: index, id: event.itemID, type: "custom_tool_call")
            try item.setInput(input, replace: done)
            items[index] = item
        case "response.output_text.annotation.added":
            let index = try outputIndex(event)
            let partIndex = try contentIndex(event)
            guard let annotation = event.rawValue["annotation"],
                let annotationIndex = event.rawValue["annotation_index"]?.intValue,
                annotationIndex >= 0, annotationIndex <= Int64(Int.max)
            else {
                throw OpenAIClientError.invalidStream("Annotation event is missing its annotation or index")
            }
            var item = try accumulatedItem(at: index, id: event.itemID, type: "message")
            try item.setAnnotation(annotation, at: Int(annotationIndex), partIndex: partIndex)
            items[index] = item
        default:
            break
        }
    }

    private mutating func applyResponseOutput(_ response: Response?) {
        guard let response else { return }
        metadata.merge(response.rawValue.objectValue ?? [:], uniquingKeysWith: { _, latest in latest })
        guard response.rawValue["output"]?.arrayValue != nil else { return }
        items = Dictionary(
            uniqueKeysWithValues: response.output.enumerated().map {
                ($0.offset, AccumulatedResponseItem($0.element))
            })
    }

    private func accumulatedItem(at index: Int, id: String?, type: String) throws -> AccumulatedResponseItem {
        if var item = items[index], item.value.type == type {
            if let id {
                if let previousID = item.value.id, previousID != id {
                    return try AccumulatedResponseItem(type: type, id: id)
                }
                try item.setID(id)
            }
            return item
        }
        return try AccumulatedResponseItem(type: type, id: id)
    }

    private func outputIndex(_ event: ResponseEvent) throws -> Int {
        guard let index = event.outputIndex, index >= 0 else {
            throw OpenAIClientError.invalidStream("Output event requires a nonnegative output_index")
        }
        return index
    }

    private func contentIndex(_ event: ResponseEvent) throws -> Int {
        guard let index = event.contentIndex, index >= 0 else {
            throw OpenAIClientError.invalidStream("Content event requires a nonnegative content_index")
        }
        return index
    }
}

private struct AccumulatedResponseItem: Sendable {
    private(set) var value: ResponseOutputItem
    private var parts: [Int: ResponseContentPart]
    private var annotations: [Int: [Int: JSONValue]] = [:]

    func details(index: Int) -> ResponseAccumulatedDetails {
        var item = value.rawValue.objectValue ?? [:]
        if value.type == "message" { item.removeValue(forKey: "content") }
        var content: [Int: [String: JSONValue]] = [:]
        var indexedAnnotations: [Int: [Int: JSONValue]] = [:]
        for (index, part) in parts {
            var fields = part.rawValue.objectValue ?? [:]
            if let list = fields["annotations"]?.arrayValue {
                fields.removeValue(forKey: "annotations")
                indexedAnnotations[index] =
                    annotations[index]
                    ?? Dictionary(uniqueKeysWithValues: list.enumerated().map { ($0.offset, $0.element) })
            }
            content[index] = fields
        }
        return ResponseAccumulatedDetails(
            outputIndex: index, item: item, content: content, annotations: indexedAnnotations)
    }

    init(_ value: ResponseOutputItem) {
        self.value = value
        parts = Dictionary(uniqueKeysWithValues: value.content.enumerated().map { ($0.offset, $0.element) })
    }

    init(type: String, id: String?) throws {
        var raw: [String: JSONValue] = ["type": .string(type)]
        if let id { raw["id"] = .string(id) }
        self.init(try JSONValue.object(raw).decode())
    }

    mutating func setID(_ id: String) throws {
        try update(["id": .string(id)])
    }

    mutating func setPart(_ part: ResponseContentPart, at index: Int) throws {
        parts[index] = part
        annotations[index] = nil
        try update([:])
    }

    mutating func setText(_ text: String, at index: Int, refusal: Bool, replace: Bool) throws {
        let type = refusal ? "refusal" : "output_text"
        let key = refusal ? "refusal" : "text"
        var raw = parts[index]?.type == type ? (parts[index]?.rawValue.objectValue ?? [:]) : [:]
        raw["type"] = .string(type)
        raw[key] = .string(replace ? text : (raw[key]?.stringValue ?? "") + text)
        parts[index] = try JSONValue.object(raw).decode()
        try update([:])
    }

    mutating func setArguments(_ arguments: String, replace: Bool) throws {
        let accumulated = replace ? arguments : (value.arguments ?? "") + arguments
        try update(["arguments": .string(accumulated)])
    }

    mutating func setInput(_ input: String, replace: Bool) throws {
        try update(["input": .string(replace ? input : (value.rawValue["input"]?.stringValue ?? "") + input)])
    }

    mutating func setLogprobs(_ logprobs: [JSONValue], at index: Int, replace: Bool) throws {
        var raw = parts[index]?.rawValue.objectValue ?? ["type": "output_text", "text": ""]
        raw["logprobs"] = .array(replace ? logprobs : (raw["logprobs"]?.arrayValue ?? []) + logprobs)
        parts[index] = try JSONValue.object(raw).decode()
        try update([:])
    }

    mutating func setAnnotation(_ annotation: JSONValue, at index: Int, partIndex: Int) throws {
        var raw = parts[partIndex]?.rawValue.objectValue ?? ["type": "output_text", "text": ""]
        if annotations[partIndex] == nil {
            annotations[partIndex] = Dictionary(
                uniqueKeysWithValues: (raw["annotations"]?.arrayValue ?? []).enumerated().map {
                    ($0.offset, $0.element)
                })
        }
        annotations[partIndex]?[index] = annotation
        let stored = annotations[partIndex] ?? [:]
        raw["annotations"] = .array(stored.keys.sorted().compactMap { stored[$0] })
        parts[partIndex] = try JSONValue.object(raw).decode()
        try update([:])
    }

    private mutating func update(_ fields: [String: JSONValue]) throws {
        var raw = value.rawValue.objectValue ?? [:]
        raw.merge(fields, uniquingKeysWith: { _, replacement in replacement })
        if value.type == "message" || !parts.isEmpty || raw["content"] != nil {
            raw["content"] = .array(parts.keys.sorted().compactMap { parts[$0]?.rawValue })
        }
        value = try JSONValue.object(raw).decode()
    }
}
