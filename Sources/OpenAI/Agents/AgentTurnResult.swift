import Foundation

/// The selected coordinator turn and its authoritative completed assistant messages.
public struct AgentTurnResult: Sendable, Equatable {
    public let turn: JSONValue
    public let messages: [JSONValue]
    public var sessionID: String { turn["session_id"]?.stringValue ?? "" }
    public var turnID: String { turn["id"]?.stringValue ?? "" }
    public var outputText: String {
        messages.flatMap { $0["content"]?.arrayValue ?? [] }.compactMap {
            $0["type"]?.stringValue == "output_text" ? $0["text"]?.stringValue : nil
        }.joined()
    }

    public init(turn: JSONValue, messages: [JSONValue]) {
        self.turn = turn
        self.messages = messages
    }
}

/// Retains partial results and the original cause without exposing output in its description.
public struct AgentTurnResultError: Error, Sendable, CustomStringConvertible {
    public let reason: String
    public let sessionID: String
    public let turn: JSONValue?
    public let messages: [JSONValue]
    public let requiredActions: [JSONValue]
    public let cause: (any Error)?
    public var description: String { "Cannot collect beta agent result: \(reason)" }
}

struct AgentTurnCollector: Sendable {
    var enabled = false
    var started = false
    var sessionID = ""
    var turn: JSONValue?
    var messages: [Int64: JSONValue] = [:]
    var required: [JSONValue] = []
    var terminal = false
    var boundary = false
    var sessionFailed = false
    var collectionError: (any Error)?

    mutating func accumulate(_ event: JSONValue) {
        started = true
        guard enabled, !boundary, collectionError == nil else { return }
        let type = event["type"]?.stringValue ?? ""
        if sessionID.isEmpty { sessionID = event["session_id"]?.stringValue ?? "" }
        switch type {
        case "agent.session.created": sessionID = event["session"]?["id"]?.stringValue ?? sessionID
        case "agent.session.requires_action": required = event["session"]?["required_actions"]?.arrayValue ?? []
        case "agent.session.in_progress": required = []
        case "agent.session.failed": sessionFailed = true
        case "agent.session.idle":
            if terminal {
                boundary = true
                required = []
            }
        case "agent.session.turn.created":
            if turn == nil, event["turn"]?["subagent_id"]?.stringValue?.isEmpty ?? true {
                guard event["turn_id"] == event["turn"]?["id"], let value = event["turn"] else {
                    collectionError = OpenAIClientError.invalidResponse
                    return
                }
                turn = value
                sessionID = value["session_id"]?.stringValue ?? sessionID
            }
        default: break
        }
        let eventTurn = type == "agent.session.turn.item.done" ? event["item"]?["turn_id"] : event["turn_id"]
        guard let turn, eventTurn == turn["id"] else { return }
        switch type {
        case "agent.session.turn.in_progress": self.turn = event["turn"]
        case "agent.session.turn.completed", "agent.session.turn.failed", "agent.session.turn.cancelled":
            self.turn = event["turn"]
            terminal = true
            required = []
        case "agent.session.turn.item.done":
            guard let item = event["item"], item["type"] == "message", item["role"] == "assistant",
                item["status"] == "completed", item["phase"] != "commentary"
            else { return }
            messages[event["output_index"]?.intValue ?? 0] = item
        default: break
        }
    }

    func stopped(handlers: [String: AgentToolHandler]) -> Bool {
        collectionError != nil || boundary || sessionFailed || (terminal && turn?["status"] != "completed")
            || required.contains { $0["type"] != "function_call" || handlers[$0["name"]?.stringValue ?? ""] == nil }
    }

    func result(cause: (any Error)? = nil) throws -> AgentTurnResult {
        let cause = collectionError ?? (boundary ? nil : cause)
        let ordered = messages.keys.sorted().compactMap { messages[$0] }
        let reason: String?
        if sessionFailed {
            reason = "session_failed"
        } else if turn?["status"] == "failed" {
            reason = "turn_failed"
        } else if turn?["status"] == "cancelled" {
            reason = "turn_cancelled"
        } else if cause != nil {
            reason = "observation_failed"
        } else if !required.isEmpty {
            reason = "requires_action"
        } else if turn == nil || !terminal || turn?["status"] != "completed" || !boundary {
            reason = "observation_incomplete"
        } else {
            reason = nil
        }
        if let reason {
            throw AgentTurnResultError(
                reason: reason, sessionID: sessionID, turn: turn, messages: ordered, requiredActions: required,
                cause: cause)
        }
        return AgentTurnResult(turn: turn!, messages: ordered)
    }
}
