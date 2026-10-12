import Foundation

/// Local handlers execute sequentially during iteration, only for explicitly registered functions.
public typealias AgentToolHandler = @Sendable ([String: JSONValue]) async throws -> JSONValue

public struct AgentToolError: Error, Sendable {
    public let sessionID: String
    public let turnID: String
    public let callID: String
    public let toolName: String
    public let stage: String
    public let cause: any Error
}

/// A single-consumer hosted turn observation. Closing it releases local resources without cancelling the remote turn.
public actor AgentSessionStream: AsyncSequence {
    public typealias Element = JSONValue
    public struct AsyncIterator: AsyncIteratorProtocol {
        let stream: AgentSessionStream
        public mutating func next() async throws -> JSONValue? { try await stream.next() }
    }
    public nonisolated func makeAsyncIterator() -> AsyncIterator { AsyncIterator(stream: self) }
    public nonisolated func close() {
        lifetime.close()
        stream.cancel()
    }

    private nonisolated let stream: OpenAIStream<JSONValue>
    private nonisolated let lifetime = AgentObservationLifetime()
    private let iterator: AgentEventIterator
    private let service: AgentsService
    private var sessionID: String
    private let options: RequestOptions
    private let handlers: [String: AgentToolHandler]
    private let onToolError: (@Sendable (AgentToolError) -> Void)?
    private let allowEOF: Bool
    private var collector = AgentTurnCollector()
    private var cachedResult: Result<AgentTurnResult, any Error>?
    private var pending: JSONValue?
    private var handled: Set<String> = []
    private var recent: [String] = []
    private var eventIDs: Set<String> = []
    private var turnID = ""
    private var turnEnded = false
    private var ended = false
    private var advancing = false
    private var failure: (any Error)?

    init(
        stream: OpenAIStream<JSONValue>, service: AgentsService, sessionID: String = "", options: RequestOptions,
        handlers: [String: AgentToolHandler], onToolError: (@Sendable (AgentToolError) -> Void)? = nil,
        allowEOF: Bool = false
    ) {
        self.stream = stream
        iterator = AgentEventIterator(stream.makeAsyncIterator())
        self.service = service
        self.sessionID = sessionID
        self.options = options
        self.handlers = handlers
        self.onToolError = onToolError
        self.allowEOF = allowEOF
    }

    /// Enable before progress iteration to retain a final answer. Fresh `finalResult()` calls enable automatically.
    @discardableResult
    public func withResultCollection() throws -> AgentSessionStream {
        guard !collector.started || collector.enabled else { throw collectionNotEnabled() }
        collector.enabled = true
        return self
    }

    public func finalResult() async throws -> AgentTurnResult {
        if let cachedResult { return try cachedResult.get() }
        guard !advancing else { throw OpenAIClientError.invalidConfiguration("Concurrent agent stream iteration") }
        if collector.started && !collector.enabled { throw collectionNotEnabled() }
        collector.enabled = true
        do {
            while !collector.stopped(handlers: handlers), try await next() != nil {}
            let value = try collector.result(cause: failure)
            cachedResult = .success(value)
            close()
            return value
        } catch {
            let final: any Error
            if error is AgentTurnResultError {
                final = error
            } else {
                do {
                    let value = try collector.result(cause: error)
                    cachedResult = .success(value)
                    close()
                    return value
                } catch { final = error }
            }
            cachedResult = .failure(final)
            close()
            throw final
        }
    }

    private func collectionNotEnabled() -> AgentTurnResultError {
        AgentTurnResultError(
            reason: "collection_not_enabled", sessionID: sessionID, turn: nil,
            messages: [], requiredActions: [], cause: nil)
    }

    public func next() async throws -> JSONValue? {
        guard !advancing else { throw OpenAIClientError.invalidConfiguration("Concurrent agent stream iteration") }
        guard !ended else {
            if let failure { throw failure }
            return nil
        }
        guard !lifetime.isClosed else { return nil }
        advancing = true
        defer {
            advancing = false
            lifetime.clear()
        }
        let deadline = options.deadline
        let task = Task { try await RequestDeadline.run(until: deadline) { try await self.advance() } }
        lifetime.attach(task)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
            self.close()
        }
    }

    private func advance() async throws -> JSONValue? {
        do {
            try Task.checkCancellation()
            if let call = pending {
                pending = nil
                try await handle(call)
            }
            while true {
                let event = try await iterator.next()
                try Task.checkCancellation()
                guard let event else {
                    ended = true
                    stream.cancel()
                    if !allowEOF { throw OpenAIClientError.invalidResponse }
                    return nil
                }
                let id = event["event_id"]?.stringValue ?? ""
                if !id.isEmpty {
                    guard eventIDs.insert(id).inserted else { continue }
                    recent.append(id)
                    if recent.count > 1024 { eventIDs.remove(recent.removeFirst()) }
                }
                let type = event["type"]?.stringValue ?? ""
                if sessionID.isEmpty { sessionID = event["session"]?["id"]?.stringValue ?? "" }
                if type == "agent.session.turn.created", turnID.isEmpty,
                    event["turn"]?["subagent_id"]?.stringValue?.isEmpty ?? true
                {
                    turnID = event["turn_id"]?.stringValue ?? ""
                }
                if ["agent.session.turn.completed", "agent.session.turn.failed", "agent.session.turn.cancelled"]
                    .contains(type),
                    !turnID.isEmpty, event["turn_id"]?.stringValue == turnID
                {
                    turnEnded = true
                }
                collector.accumulate(event)
                if type == "agent.session.failed" || (type == "agent.session.idle" && turnEnded) {
                    ended = true
                    stream.cancel()
                } else if type == "agent.session.turn.item.added", let item = event["item"],
                    item["type"] == "function_call"
                {
                    let key = (item["turn_id"]?.stringValue ?? "") + "\0" + (item["call_id"]?.stringValue ?? "")
                    if handled.insert(key).inserted, handlers[item["name"]?.stringValue ?? ""] != nil { pending = item }
                }
                return event
            }
        } catch {
            failure = error
            ended = true
            close()
            throw error
        }
    }

    private func handle(_ call: JSONValue) async throws {
        guard !sessionID.isEmpty else { throw OpenAIClientError.invalidResponse }
        let name = call["name"]?.stringValue ?? ""
        let turn = call["turn_id"]?.stringValue ?? ""
        let id = call["call_id"]?.stringValue ?? ""
        var result: JSONValue = [
            "type": "agent.session.input.tool_result", "call_id": .string(id), "turn_id": .string(turn),
        ]
        var fields = result.objectValue!
        var stage = "arguments"
        do {
            var arguments = call["arguments"] ?? .null
            if let text = arguments.stringValue {
                arguments = try OpenAIJSON.decode(JSONValue.self, from: Data(text.utf8))
            }
            guard let object = arguments.objectValue else { throw OpenAIClientError.invalidResponse }
            stage = "execution"
            let output = try await handlers[name]!(object)
            stage = "output"
            switch output {
            case .null, .string, .array: fields["output"] = output
            case .object: fields["output"] = .string(String(decoding: try output.encodedData(), as: UTF8.self))
            default: throw OpenAIClientError.invalidResponse
            }
            if let output = fields["output"] { _ = try output.encodedData() }
            fields["success"] = true
        } catch {
            try Task.checkCancellation()
            fields.removeValue(forKey: "output")
            fields["success"] = false
            fields["error"] = "Tool handler failed."
            onToolError?(
                AgentToolError(
                    sessionID: sessionID, turnID: turn, callID: id, toolName: name, stage: stage, cause: error))
        }
        try Task.checkCancellation()
        result = .object(fields)
        var scoped = options
        scoped.headerMutations.append(.set("Idempotency-Key", UUID().uuidString))
        let delays: [TimeInterval] = [0.1, 0.3, 0.6]
        for attempt in 0...delays.count {
            do {
                try await service.submitEvent(sessionID, body: ["events": .array([result])], options: scoped)
                return
            } catch let error as APIError {
                guard attempt < delays.count, error.statusCode == 400,
                    error.code == "invalid_request_error", error.message == "Unknown pending tool call: " + id
                else { throw error }
                try await Task.sleep(for: .seconds(delays[attempt]))
            }
        }
    }
}

/// Access is serialized by AgentSessionStream's advancing guard, including across suspension points.
private final class AgentEventIterator: @unchecked Sendable {
    private var iterator: OpenAIStream<JSONValue>.AsyncIterator
    init(_ iterator: OpenAIStream<JSONValue>.AsyncIterator) { self.iterator = iterator }
    func next() async throws -> JSONValue? { try await iterator.next() }
}

private final class AgentObservationLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var task: Task<JSONValue?, any Error>?
    var isClosed: Bool { lock.withLock { closed } }
    func attach(_ task: Task<JSONValue?, any Error>) {
        let stopped = lock.withLock {
            self.task = task
            return closed
        }
        if stopped { task.cancel() }
    }
    func clear() { lock.withLock { task = nil } }
    func close() {
        let task = lock.withLock {
            closed = true
            return self.task
        }
        task?.cancel()
    }
}
