import Foundation

/// Collects one WebSocket lane and turn. It never owns the connection or executes tools.
/// Reset before a subsequent turn; unknown events and unbound/mismatched annotations are ignored.
public struct ResponseWebSocketAccumulator: Sendable {
    private var accumulator = ResponseAccumulator()
    private var bound = false
    private var streamID = ""
    public init() {}
    public var snapshot: ResponseSnapshot {
        let value = accumulator.snapshot
        return ResponseSnapshot(
            streamID: bound ? streamID : nil, id: value.id, output: value.output, outputText: value.outputText,
            terminalEvent: value.terminalEvent, response: value.response, rawValue: value.rawValue)
    }
    public var detailedSnapshot: ResponseAccumulatorDetails {
        let details = accumulator.detailedSnapshot
        return ResponseAccumulatorDetails(
            streamID: bound ? streamID : nil, responseID: details.responseID, terminalEvent: details.terminalEvent,
            response: details.response, output: details.output)
    }
    public mutating func reset() { self = Self() }

    public mutating func add(_ event: ResponseEvent) throws {
        let supported: Set<String> = [
            "response.created", "response.in_progress", "response.completed", "response.failed", "response.incomplete",
            "response.output_item.added", "response.output_item.done", "response.content_part.added",
            "response.content_part.done",
            "response.output_text.delta", "response.output_text.done", "response.function_call_arguments.delta",
            "response.function_call_arguments.done", "response.custom_tool_call_input.delta",
            "response.custom_tool_call_input.done",
            "response.output_text.annotation.added", "error",
        ]
        guard supported.contains(event.type) else { return }
        let lane = event.rawValue["stream_id"]?.stringValue ?? ""
        if event.type == "response.output_text.annotation.added" {
            guard bound, accumulator.snapshot.terminalEvent == nil, lane == streamID,
                (try? validateIndices(event, ["output_index", "content_index", "annotation_index"])) != nil,
                let id = event.itemID, let index = event.outputIndex,
                accumulator.detailedSnapshot.output.contains(where: {
                    $0.outputIndex == index && $0.item["id"]?.stringValue == id
                }),
                event.rawValue["annotation"] != nil
            else { return }
            try accumulator.add(event)
            return
        }
        guard !bound || lane == streamID else { throw invalid("Event belongs to another lane") }
        guard accumulator.snapshot.terminalEvent == nil else { throw invalid("Turn ended; reset before another event") }
        if event.type == "error" { throw OpenAIWebSocketError.responseTerminated(event) }
        switch event.type {
        case "response.created", "response.in_progress", "response.completed", "response.failed", "response.incomplete":
            guard let response = event.response, response.rawValue["id"]?.stringValue != nil else {
                throw invalid("Lifecycle event is missing a valid response")
            }
            if let output = response.rawValue["output"], output != .null {
                guard let items = output.arrayValue else { throw invalid("Invalid response output") }
                for item in items { try validateItem(item) }
            }
        case "response.output_item.added", "response.output_item.done":
            try validateIndices(event, ["output_index"])
            guard let item = event.rawValue["item"] else { throw invalid("Missing output item") }
            try validateItem(item)
        default:
            var indices = ["output_index"]
            if event.type.hasPrefix("response.content_part.") || event.type.hasPrefix("response.output_text.") {
                indices.append("content_index")
            }
            try validateIndices(event, indices)
            guard event.rawValue["item_id"]?.stringValue != nil else { throw invalid("Missing item identity") }
            if event.type.hasPrefix("response.content_part.") {
                guard let part = event.rawValue["part"], part["type"]?.stringValue != nil,
                    part["type"] != "output_text" || part["text"]?.stringValue != nil
                else { throw invalid("Invalid content part") }
            } else {
                let key: String
                if event.type.hasSuffix(".delta") {
                    key = "delta"
                } else if event.type.hasPrefix("response.function_call_arguments.") {
                    key = "arguments"
                } else if event.type.hasPrefix("response.custom_tool_call_input.") {
                    key = "input"
                } else {
                    key = "text"
                }
                guard event.rawValue[key]?.stringValue != nil else { throw invalid("Missing selected event text") }
            }
        }
        try accumulator.add(event)
        bound = true
        streamID = lane
    }

    private func validateIndices(_ event: ResponseEvent, _ names: [String]) throws {
        let document = try event.rawJSON.document
        for name in names {
            guard let raw = document.field(at: [.key(name)]).rawString, !raw.isEmpty,
                raw.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int64(raw), value >= 0
            else {
                throw invalid("Invalid selected event index")
            }
        }
    }

    private func validateItem(_ item: JSONValue) throws {
        guard let type = item["type"]?.stringValue,
            item["id"] == nil || item["id"]?.stringValue != nil
        else { throw invalid("Invalid item identity") }
        switch type {
        case "message":
            guard let content = item["content"]?.arrayValue else { throw invalid("Invalid message content") }
            for part in content {
                guard part["type"]?.stringValue != nil,
                    part["type"] != "output_text" || part["text"]?.stringValue != nil
                else { throw invalid("Invalid message part") }
            }
        case "function_call", "custom_tool_call":
            for name in ["call_id", "name", type == "function_call" ? "arguments" : "input"] {
                guard item[name]?.stringValue != nil else { throw invalid("Invalid tool fields") }
            }
        default: break
        }
    }
    private func invalid(_ message: String) -> OpenAIClientError { .invalidStream("Responses accumulator: " + message) }
}
